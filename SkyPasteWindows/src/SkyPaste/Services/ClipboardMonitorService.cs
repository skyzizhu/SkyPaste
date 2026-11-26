using System.ComponentModel;
using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Interop;
using System.Windows.Threading;
using SkyPaste.Core.Models;
using SkyPaste.Core.Services;
using SkyPaste.Interop;

namespace SkyPaste.Services;

/// <summary>
/// Port of macOS ClipboardMonitor: event-driven via WM_CLIPBOARDUPDATE with a
/// 1s sequence-number poll as a safety net (delayed-render apps). Captures the
/// clipboard owner process so local items carry a source app badge.
/// </summary>
public sealed class ClipboardMonitorService : IDisposable
{
    private const int FallbackPollIntervalMs = 1000;

    private readonly AppSettingsService _settings;
    private readonly SynchronizationContext? _ui;
    private HwndSource? _hwndSource;
    private DispatcherTimer? _pollTimer;
    private uint _lastSequenceNumber;
    private int _writeDepth;
    private bool _started;
    private int _decodeRetries;
    private DispatcherTimer? _decodeRetryTimer;

    // Delayed-render apps (Excel, Photoshop...) place content lazily; retry reads.
    private const int MaxDecodeRetries = 2;
    private static readonly TimeSpan DecodeRetryDelay = TimeSpan.FromMilliseconds(300);

    public void WriteWithoutCapture(Action write)
    {
        var before = NativeMethods.GetClipboardSequenceNumber();
        _writeDepth++;
        try
        {
            write();
            var after = NativeMethods.GetClipboardSequenceNumber();
            if (after != before)
            {
                _lastSequenceNumber = after;
                _decodeRetries = 0;
                _decodeRetryTimer?.Stop();
            }
        }
        finally
        {
            _writeDepth--;
        }
    }

    public event Action<ClipboardItem>? ClipboardCaptured;

    public ClipboardMonitorService(AppSettingsService settings)
    {
        _settings = settings;
        _ui = SynchronizationContext.Current;
    }

    public void Start()
    {
        if (_started)
        {
            return;
        }
        _started = true;

        var parameters = new HwndSourceParameters("SkyPasteClipboardMonitor")
        {
            Width = 0,
            Height = 0,
            PositionX = 0,
            PositionY = 0,
            WindowStyle = 0,
            ParentWindow = IntPtr.Zero,
        };
        _hwndSource = new HwndSource(parameters);
        _hwndSource.AddHook(WndProc);

        if (!NativeMethods.AddClipboardFormatListener(_hwndSource.Handle))
        {
            Debug.WriteLine("AddClipboardFormatListener failed; falling back to polling");
        }

        _lastSequenceNumber = NativeMethods.GetClipboardSequenceNumber();
        _pollTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(FallbackPollIntervalMs) };
        _pollTimer.Tick += (_, _) => CheckSequence();
        _pollTimer.Start();

        CaptureStartupClipboard();
    }

    public void Dispose()
    {
        if (!_started)
        {
            return;
        }
        _started = false;
        if (_hwndSource is not null)
        {
            NativeMethods.RemoveClipboardFormatListener(_hwndSource.Handle);
            _hwndSource.RemoveHook(WndProc);
            _hwndSource.Dispose();
            _hwndSource = null;
        }
        _pollTimer?.Stop();
        _pollTimer = null;
        _decodeRetryTimer?.Stop();
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == NativeMethods.WM_CLIPBOARDUPDATE)
        {
            CheckSequence();
            handled = true;
        }
        return IntPtr.Zero;
    }

    private void CheckSequence()
    {
        var sequence = NativeMethods.GetClipboardSequenceNumber();
        if (_writeDepth > 0 || sequence == _lastSequenceNumber)
        {
            return;
        }
        _lastSequenceNumber = sequence;
        _decodeRetryTimer?.Stop();
        _decodeRetries = 0;
        CaptureClipboard();
    }

    /// <summary>Immediately records whatever is on the clipboard (mirrors macOS startup capture).</summary>
    public void CaptureStartupClipboard() => CaptureClipboard();

    private void CaptureClipboard()
    {
        if (_writeDepth > 0)
        {
            return;
        }

        ClipboardItem? item;
        try
        {
            item = ClipboardDecoder.Decode();
        }
        catch (COMException)
        {
            item = null; // clipboard momentarily locked by another app
        }
        if (item is null)
        {
            ScheduleDecodeRetry();
            return;
        }
        _decodeRetries = 0;

        var owner = GetClipboardOwnerApp();
        if (owner is not null)
        {
            if (IsIgnored(owner))
            {
                return;
            }
            item = new ClipboardItem(
                item.Id, item.CreatedAt, item.Content, item.Fingerprint,
                ClipboardSource.Local, owner, item.IsFavorite);
        }

        if (_ui is not null)
        {
            _ui.Post(_ => ClipboardCaptured?.Invoke(item!), null);
        }
        else
        {
            ClipboardCaptured?.Invoke(item);
        }
    }

    private void ScheduleDecodeRetry()
    {
        if (_decodeRetries >= MaxDecodeRetries)
        {
            _decodeRetries = 0;
            return;
        }
        _decodeRetries += 1;
        _decodeRetryTimer?.Stop();
        _decodeRetryTimer = new DispatcherTimer { Interval = DecodeRetryDelay };
        _decodeRetryTimer.Tick += (_, _) =>
        {
            _decodeRetryTimer?.Stop();
            CaptureClipboard();
        };
        _decodeRetryTimer.Start();
    }

    private ClipboardSourceApp? GetClipboardOwnerApp()
    {
        try
        {
            var ownerWindow = NativeMethods.GetClipboardOwner();
            if (ownerWindow == IntPtr.Zero)
            {
                return null;
            }
            NativeMethods.GetWindowThreadProcessId(ownerWindow, out var processId);
            if (processId == 0)
            {
                return null;
            }
            var processName = QueryProcessName(processId);
            if (string.IsNullOrEmpty(processName))
            {
                return null;
            }
            var exeName = Path.GetFileName(processName);
            var friendlyName = GetFileDescription(processName) ?? Path.GetFileNameWithoutExtension(exeName);
            if (string.Equals(friendlyName, "skypaste", StringComparison.OrdinalIgnoreCase))
            {
                return null; // our own writes
            }
            return new ClipboardSourceApp(exeName.ToLowerInvariant(), friendlyName);
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static string? QueryProcessName(uint processId)
    {
        const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        var handle = NativeMethods.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
        if (handle == IntPtr.Zero)
        {
            return null;
        }
        try
        {
            var buffer = new System.Text.StringBuilder(1024);
            var size = (uint)buffer.Capacity;
            return NativeMethods.QueryFullProcessImageName(handle, 0, buffer, ref size)
                ? buffer.ToString(0, (int)size)
                : null;
        }
        finally
        {
            NativeMethods.CloseHandle(handle);
        }
    }

    private static string? GetFileDescription(string exePath)
    {
        try
        {
            return FileVersionInfo.GetVersionInfo(exePath).FileDescription;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private bool IsIgnored(ClipboardSourceApp app)
    {
        foreach (var ignored in _settings.IgnoredApps)
        {
            if (app.ProcessId.Contains(ignored) || Fold(app.Name).Contains(ignored))
            {
                return true;
            }
        }
        return false;
    }

    private static string Fold(string value) => value.Trim().ToLowerInvariant();
}
