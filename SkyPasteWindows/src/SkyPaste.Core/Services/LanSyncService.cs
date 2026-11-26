using System.IO;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Globalization;
using SkyPaste.Core.Core;
using SkyPaste.Core.Models;

namespace SkyPaste.Core.Services;

public enum LanSyncStatus
{
    Disabled,
    Unavailable,
    Syncing,
    Synced,
    Error,
}

/// <summary>
/// LAN clipboard sync (replaces macOS iCloud CloudKit sync):
/// - POST /paste    phone or other PC pushes {"text": "..."} or {"imageBase64": "...", "name": "..."}
///                  (header X-SkyPaste-Token required)
/// - GET  /pull     paired PCs pull local text items newer than ?since= (token required)
/// - UDP  beacon    port 26178 broadcasts {"id","name","port"} for peer discovery
/// Conflicts resolve exactly like macOS sync: fingerprint dedupe + createdAt last-write-wins.
/// </summary>
public sealed class LanSyncService : IDisposable
{
    public const int DiscoveryPort = 26178;
    private static readonly JsonSerializerOptions ProtocolJson = new(JsonSerializerDefaults.Web);

    private readonly AppSettingsService _settings;
    private readonly ClipboardStore _store;
    private readonly SynchronizationContext? _storeContext;
    private readonly string _deviceId = Guid.NewGuid().ToString("N")[..8];

    private SimpleHttpServer? _httpServer;
    private UdpClient? _beaconListener;
    private UdpClient? _beaconSender;
    private Timer? _beaconTimer;
    private Timer? _pullTimer;
    private System.Threading.Timer? _ipMonitorTimer;
    private string? _advertisedIP;

    /// <summary>Fired (any thread) when the machine's LAN IPv4 changes.</summary>
    public event Action<string>? IpChanged;
    private CancellationTokenSource? _listenerCts;
    private int _pullInProgress;

    private readonly Dictionary<string, (string Name, string Host, int Port)> _peers = new();
    private readonly ConcurrentDictionary<string, DateTime> _pullCursors = new();

    public LanSyncStatus Status { get; private set; } = LanSyncStatus.Disabled;
    public string? StatusError { get; private set; }
    public string DeviceId => _deviceId;

    public event Action? StatusChanged;
    public event Action<string>? ReceivedFromDevice; // device display name

    public LanSyncService(AppSettingsService settings, ClipboardStore store, SynchronizationContext? storeContext = null)
    {
        _settings = settings;
        _store = store;
        _storeContext = storeContext;
    }

    /// <summary>First IPv4 address this machine would use for outbound LAN traffic.</summary>
    public static string? LocalIPv4
    {
        get
        {
            try
            {
                using var socket = new UdpClient();
                socket.Connect("192.168.255.255", 65530); // no packet is actually sent
                return (socket.Client.LocalEndPoint as IPEndPoint)?.Address.ToString();
            }
            catch (Exception)
            {
                return null;
            }
        }
    }

    /// <summary>URL encoded into the pairing QR code shown in Preferences.</summary>
    public string PairingUrl
    {
        get
        {
            var ip = LocalIPv4 ?? "<your-pc-ip>";
            return $"http://{ip}:{_settings.LanSyncPort}/?t={_settings.LanSyncToken}";
        }
    }

    // ---- lifecycle ---------------------------------------------------------

    private void CheckIPChange()
    {
            var ip = LocalIPv4;
            if (ip == _advertisedIP) return;
            _advertisedIP = ip;
            try { IpChanged?.Invoke(ip ?? string.Empty); } catch { }
    }

    public void ApplyCurrentSetting()
    {
        if (_settings.LanSyncEnabled)
        {
            Start();
        }
        else
        {
            Stop();
        }
    }

    public void Start()
    {
        Stop();
        Status = LanSyncStatus.Syncing;
        StatusError = null;
        StatusChanged?.Invoke();

        try
        {
            _listenerCts = new CancellationTokenSource();
            var listenerToken = _listenerCts.Token;
            _httpServer = new SimpleHttpServer(_settings.LanSyncPort, HandleRequest);
            _httpServer.Start(listenerToken);

            _beaconListener = new UdpClient(DiscoveryPort);
            _beaconListener.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            _ = ListenForBeacons(listenerToken);

            _beaconSender = new UdpClient();
            _beaconTimer = new Timer(_ => SendBeacon(), null, TimeSpan.Zero, TimeSpan.FromSeconds(5));
            _pullTimer = new Timer(_ => _ = PullPeersAsync(listenerToken), null, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(10));
            _advertisedIP = LocalIPv4;
            _ipMonitorTimer = new System.Threading.Timer(_ => CheckIPChange(), null, TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(15));

            Status = LanSyncStatus.Synced;
        }
        catch (Exception exception)
        {
            Status = LanSyncStatus.Unavailable;
            StatusError = exception.Message;
        }
        StatusChanged?.Invoke();
    }

    public void Stop()
    {
        try
        {
            _beaconTimer?.Dispose();
            _pullTimer?.Dispose();
            _ipMonitorTimer?.Dispose();
            _ipMonitorTimer = null;
            _listenerCts?.Cancel();
            _beaconListener?.Dispose();
            _beaconSender?.Dispose();
            _httpServer?.Dispose();
        }
        catch (Exception)
        {
        }
        _beaconTimer = null;
        _pullTimer = null;
        _beaconListener = null;
        _beaconSender = null;
        _httpServer = null;
        lock (_peers)
        {
            _peers.Clear();
        }
        Status = LanSyncStatus.Disabled;
        StatusChanged?.Invoke();
    }

    public void Dispose() => Stop();

    // ---- HTTP endpoints ------------------------------------------------------

    internal (int StatusCode, string Body) HandleRequest(SimpleHttpRequest request)
    {
        if (request.Path == "/" && request.Method == "GET")
        {
            return (200, WebClipboardPageBuilder.Build(_settings.DeviceName));
        }

        var token = request.Header("X-SkyPaste-Token");
        if (!string.Equals(token, _settings.LanSyncToken, StringComparison.Ordinal))
        {
            return (401, "{\"error\":\"unauthorized\"}");
        }

        switch (request.Path.TrimEnd('/'))
        {
            case "/paste":
                if (request.Method != "POST")
                {
                    return (405, "{\"error\":\"method not allowed\"}");
                }
                if (!_settings.LanSyncReceiveEnabled)
                {
                    return (403, "{\"error\":\"receive disabled\"}");
                }
                return HandlePaste(request);

            case "/pull":
                if (request.Method != "GET")
                {
                    return (405, "{\"error\":\"method not allowed\"}");
                }
                if (!_settings.LanSyncUploadEnabled)
                {
                    return (403, "{\"error\":\"upload disabled\"}");
                }
                return HandlePull(request);

            default:
                return (404, "{\"error\":\"not found\"}");
        }
    }

    private (int StatusCode, string Body) HandlePaste(SimpleHttpRequest request)
    {
        try
        {
            var payload = JsonSerializer.Deserialize<PastePayload>(request.Body, ProtocolJson);
            if (payload is null)
            {
                return (400, "{\"error\":\"bad payload\"}");
            }

            var senderName = string.IsNullOrWhiteSpace(payload.Device)
                ? request.RemoteEndPoint
                : payload.Device.Trim();

            if (!string.IsNullOrWhiteSpace(payload.Text))
            {
                var text = payload.Text;
                var item = new ClipboardItem(
                    Guid.NewGuid(), payload.CreatedAt?.ToUniversalTime() ?? DateTime.UtcNow,
                    ClipboardContent.FromText(text), Fingerprint.ForText(text),
                    ClipboardSource.LanDevice, new ClipboardSourceApp("device:" + senderName, senderName));
                OnStoreThread(() => _store.AddDeviceSyncedItem(item));
                ReceivedFromDevice?.Invoke(senderName);
                return (200, "{\"ok\":true}");
            }

            if (!string.IsNullOrWhiteSpace(payload.ImageBase64))
            {
                byte[] data;
                try
                {
                    data = Convert.FromBase64String(payload.ImageBase64);
                }
                catch (FormatException)
                {
                    return (400, "{\"error\":\"bad base64\"}");
                }
                if (data.Length == 0)
                {
                    return (400, "{\"error\":\"empty image\"}");
                }
                var name = string.IsNullOrWhiteSpace(payload.Name) ? "phone-image.png" : payload.Name!.Trim();
                if (!Path.HasExtension(name))
                {
                    name += ".png";
                }
                var item = new ClipboardItem(
                    Guid.NewGuid(), payload.CreatedAt?.ToUniversalTime() ?? DateTime.UtcNow,
                    ClipboardContent.FromImage(data, name, data.LongLength, previewOnly: false),
                    Fingerprint.ForImage(data),
                    ClipboardSource.LanDevice, new ClipboardSourceApp("device:" + senderName, senderName));
                OnStoreThread(() => _store.AddDeviceSyncedItem(item));
                ReceivedFromDevice?.Invoke(senderName);
                return (200, "{\"ok\":true}");
            }

            return (400, "{\"error\":\"empty payload\"}");
        }
        catch (JsonException)
        {
            return (400, "{\"error\":\"bad json\"}");
        }
    }

    private (int StatusCode, string Body) HandlePull(SimpleHttpRequest request)
    {
        long sinceSeconds = 0;
        var sinceRaw = request.Query("since");
        if (long.TryParse(sinceRaw, out var parsed)
            && parsed >= DateTimeOffset.MinValue.ToUnixTimeSeconds()
            && parsed <= DateTimeOffset.MaxValue.ToUnixTimeSeconds())
        {
            sinceSeconds = parsed;
        }
        var since = DateTimeOffset.FromUnixTimeSeconds(sinceSeconds).UtcDateTime;
        string body = "[]";
        OnStoreThread(() =>
        {
            var eligible = _store.ItemsEligibleForDeviceSync()
                .Where(i => i.CreatedAt > since)
                .OrderByDescending(i => i.CreatedAt)
                .Take(100)
                .Select(i => new
                {
                    Text = i.TextValue,
                    CreatedAt = i.CreatedAt.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture),
                    Device = _settings.DeviceName,
                });
            body = JsonSerializer.Serialize(eligible, ProtocolJson);
        });
        return (200, body);
    }

    private void OnStoreThread(Action action)
    {
        if (_storeContext is null || SynchronizationContext.Current == _storeContext)
        {
            action();
            return;
        }
        _storeContext.Send(_ => action(), null);
    }

    // ---- discovery -----------------------------------------------------------

    private void SendBeacon()
    {
        try
        {
            if (_beaconSender is null)
            {
                return;
            }
            var beacon = JsonSerializer.Serialize(new Beacon
            {
                Id = _deviceId,
                Name = _settings.DeviceName,
                Port = _settings.LanSyncPort,
            }, ProtocolJson);
            var bytes = Encoding.UTF8.GetBytes(beacon);
            var broadcastEndpoint = new IPEndPoint(IPAddress.Broadcast, DiscoveryPort);
            _beaconSender.Send(bytes, bytes.Length, broadcastEndpoint);
        }
        catch (Exception)
        {
            // Broadcast failures (no network, firewall) are non-fatal.
        }
    }

    private async Task ListenForBeacons(CancellationToken token)
    {
        var buffer = new byte[4096];
        while (!token.IsCancellationRequested && _beaconListener is not null)
        {
            try
            {
                var result = await _beaconListener.ReceiveAsync(token).ConfigureAwait(false);
                var json = Encoding.UTF8.GetString(result.Buffer);
                var beacon = JsonSerializer.Deserialize<Beacon>(json, ProtocolJson);
                if (beacon is null || string.IsNullOrEmpty(beacon.Id) || beacon.Id == _deviceId
                    || beacon.Port is < 1 or > 65535)
                {
                    continue;
                }
                var host = result.RemoteEndPoint.Address.ToString();
                lock (_peers)
                {
                    _peers[beacon.Id] = (string.IsNullOrWhiteSpace(beacon.Name) ? host : beacon.Name, host, beacon.Port);
                }
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception)
            {
                await Task.Delay(1000, CancellationToken.None).ConfigureAwait(false);
            }
        }
    }

    // ---- peer pull ------------------------------------------------------------

    private async Task PullPeersAsync(CancellationToken token)
    {
        if (token.IsCancellationRequested || !_settings.LanSyncEnabled || !_settings.LanSyncReceiveEnabled
            || Interlocked.Exchange(ref _pullInProgress, 1) != 0)
        {
            return;
        }
        try
        {
            await PullDiscoveredPeersAsync(token).ConfigureAwait(false);
        }
        finally
        {
            Volatile.Write(ref _pullInProgress, 0);
        }
    }

    private async Task PullDiscoveredPeersAsync(CancellationToken token)
    {
        List<(string Id, string Name, string Host, int Port)> peers;
        lock (_peers)
        {
            peers = _peers.Select(kv => (kv.Key, kv.Value.Name, kv.Value.Host, kv.Value.Port)).ToList();
        }

        foreach (var (id, name, host, port) in peers)
        {
            if (token.IsCancellationRequested)
            {
                return;
            }
            try
            {
                var since = _pullCursors.TryGetValue(id, out var cursor)
                    ? ((DateTimeOffset)cursor).ToUnixTimeSeconds()
                    : 0;
                using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
                using var httpRequest = new HttpRequestMessage(HttpMethod.Get, $"http://{host}:{port}/pull?since={since}");
                httpRequest.Headers.Add("X-SkyPaste-Token", _settings.LanSyncToken);
                using var response = await http.SendAsync(httpRequest, token).ConfigureAwait(false);
                if (!response.IsSuccessStatusCode)
                {
                    continue;
                }
                var body = await response.Content.ReadAsStringAsync(token).ConfigureAwait(false);
                var items = JsonSerializer.Deserialize<List<PullItem>>(body, ProtocolJson);
                if (items is null)
                {
                    continue;
                }
                foreach (var pullItem in items)
                {
                    if (string.IsNullOrWhiteSpace(pullItem.Text))
                    {
                        continue;
                    }
                    var createdAt = pullItem.CreatedAt?.ToUniversalTime() ?? DateTime.UtcNow;
                    var item = new ClipboardItem(
                        Guid.NewGuid(), createdAt,
                        ClipboardContent.FromText(pullItem.Text), Fingerprint.ForText(pullItem.Text),
                        ClipboardSource.LanDevice, new ClipboardSourceApp("device:" + name, name));
                    OnStoreThread(() =>
                    {
                        if (!token.IsCancellationRequested && _settings.LanSyncReceiveEnabled)
                        {
                            _store.AddDeviceSyncedItem(item);
                        }
                    });
                }
                var maxCreated = items.Select(i => i.CreatedAt?.ToUniversalTime()).Max();
                if (maxCreated is DateTime newest)
                {
                    _pullCursors.AddOrUpdate(id, newest, (_, previous) => previous >= newest ? previous : newest);
                }
            }
            catch (Exception)
            {
                // Peer unreachable; retry on the next tick.
            }
        }
    }

    // ---- protocol DTOs ---------------------------------------------------------

    private sealed class PastePayload
    {
        public string? Text { get; set; }
        public string? ImageBase64 { get; set; }
        public string? Name { get; set; }
        public string? Device { get; set; }
        public DateTime? CreatedAt { get; set; }
    }

    private sealed class PullItem
    {
        public string? Text { get; set; }
        public DateTime? CreatedAt { get; set; }
        public string? Device { get; set; }
    }

    private sealed class Beacon
    {
        public string? Id { get; set; }
        public string? Name { get; set; }
        public int Port { get; set; }
    }
}

/// <summary>Minimal HTTP request parsed from a raw socket stream.</summary>
public sealed class SimpleHttpRequest
{
    public required string Method { get; init; }
    public required string Path { get; init; }
    public required string RawQuery { get; init; }
    public required Dictionary<string, string> Headers { get; init; }
    public required string Body { get; init; }
    public required string RemoteEndPoint { get; init; }

    public string? Header(string name) =>
        Headers.TryGetValue(name, out var value) ? value
        : Headers.FirstOrDefault(kv => kv.Key.Equals(name, StringComparison.OrdinalIgnoreCase)).Value;

    public string? Query(string name)
    {
        if (string.IsNullOrEmpty(RawQuery))
        {
            return null;
        }
        foreach (var pair in RawQuery.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var kv = pair.Split('=', 2);
            if (kv.Length == 2 && kv[0] == name)
            {
                return Uri.UnescapeDataString(kv[1]);
            }
        }
        return null;
    }
}

/// <summary>
/// A dependency-free HTTP/1.1 server on TcpListener. Unlike HttpListener this
/// needs no admin URLACL reservation — important for a portable clipboard app.
/// </summary>
public sealed class SimpleHttpServer : IDisposable
{
    private const int MaxHeaderBytes = 16 * 1024;
    private const int MaxBodyBytes = 32 * 1024 * 1024;
    private readonly int _port;
    private readonly Func<SimpleHttpRequest, (int StatusCode, string Body)> _handler;
    private TcpListener? _listener;

    public SimpleHttpServer(int port, Func<SimpleHttpRequest, (int, string)> handler)
    {
        _port = port;
        _handler = handler;
    }

    public void Start(CancellationToken token)
    {
        _listener = new TcpListener(IPAddress.Any, _port);
        _listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        _listener.Start();
        _ = AcceptLoop(token);
    }

    internal int LocalPort => ((IPEndPoint)_listener!.LocalEndpoint).Port;

    private async Task AcceptLoop(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await _listener!.AcceptTcpClientAsync(token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception)
            {
                break;
            }
            _ = HandleClient(client, token);
        }
    }

    private async Task HandleClient(TcpClient client, CancellationToken token)
    {
        try
        {
            using (client)
            {
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
                timeout.CancelAfter(TimeSpan.FromSeconds(10));
                token = timeout.Token;
                var stream = client.GetStream();
                var remote = (client.Client.RemoteEndPoint as IPEndPoint)?.Address.ToString() ?? "unknown";

                var buffer = new byte[MaxHeaderBytes];
                var buffered = 0;
                var headerEnd = -1;
                while (headerEnd < 0 && buffered < buffer.Length)
                {
                    var read = await stream.ReadAsync(buffer.AsMemory(buffered), token).ConfigureAwait(false);
                    if (read == 0)
                    {
                        return;
                    }
                    var scanFrom = Math.Max(0, buffered - 3);
                    buffered += read;
                    var separator = buffer.AsSpan(scanFrom, buffered - scanFrom).IndexOf("\r\n\r\n"u8);
                    if (separator >= 0)
                    {
                        headerEnd = scanFrom + separator;
                    }
                }
                if (headerEnd < 0)
                {
                    return;
                }
                var headerLines = Encoding.ASCII.GetString(buffer, 0, headerEnd).Split("\r\n");
                var parts = headerLines[0].Split(' ');
                if (parts.Length < 2)
                {
                    return;
                }
                var method = parts[0];
                var fullPath = parts[1];
                var path = fullPath;
                var rawQuery = string.Empty;
                var queryIndex = fullPath.IndexOf('?');
                if (queryIndex >= 0)
                {
                    path = fullPath[..queryIndex];
                    rawQuery = fullPath[(queryIndex + 1)..];
                }

                var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (var headerLine in headerLines.Skip(1))
                {
                    var colon = headerLine.IndexOf(':');
                    if (colon > 0)
                    {
                        headers[headerLine[..colon].Trim()] = headerLine[(colon + 1)..].Trim();
                    }
                }

                var body = string.Empty;
                if (headers.TryGetValue("Content-Length", out var lengthRaw))
                {
                    if (!int.TryParse(lengthRaw, out var length) || length < 0 || length > MaxBodyBytes)
                    {
                        return;
                    }
                    var payload = new byte[length];
                    var bodyOffset = headerEnd + 4;
                    var prefixLength = Math.Min(length, buffered - bodyOffset);
                    buffer.AsMemory(bodyOffset, prefixLength).CopyTo(payload);
                    await stream.ReadExactlyAsync(payload.AsMemory(prefixLength), token).ConfigureAwait(false);
                    body = Encoding.UTF8.GetString(payload);
                }

                var request = new SimpleHttpRequest
                {
                    Method = method,
                    Path = path,
                    RawQuery = rawQuery,
                    Headers = headers,
                    Body = body,
                    RemoteEndPoint = remote,
                };

                var (statusCode, responseBody) = TryHandle(request);
                var contentType = request.Path == "/" && statusCode == 200
                    ? "text/html; charset=utf-8"
                    : "application/json; charset=utf-8";
                var statusText = statusCode switch
                {
                    200 => "OK",
                    400 => "Bad Request",
                    401 => "Unauthorized",
                    403 => "Forbidden",
                    404 => "Not Found",
                    405 => "Method Not Allowed",
                    _ => "OK",
                };
                var responseBytes = Encoding.UTF8.GetBytes(responseBody);
                var response = string.Create(CultureInfo.InvariantCulture,
                    $"HTTP/1.1 {statusCode} {statusText}\r\nContent-Type: {contentType}\r\nContent-Length: {responseBytes.Length}\r\nConnection: close\r\n\r\n");
                await stream.WriteAsync(Encoding.ASCII.GetBytes(response), token).ConfigureAwait(false);
                await stream.WriteAsync(responseBytes, token).ConfigureAwait(false);
                await stream.FlushAsync(token).ConfigureAwait(false);
            }
        }
        catch (Exception)
        {
            // Malformed requests are dropped silently.
        }
    }

    private (int StatusCode, string Body) TryHandle(SimpleHttpRequest request)
    {
        try
        {
            return _handler(request);
        }
        catch (Exception)
        {
            return (500, "{\"error\":\"internal\"}");
        }
    }

    public void Dispose()
    {
        try
        {
            _listener?.Stop();
        }
        catch (Exception)
        {
        }
    }
}
