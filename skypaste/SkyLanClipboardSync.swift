import AppKit
import CoreImage
import Foundation
import Network

/// LAN clipboard sync for SkyPaste (macOS side).
/// Protocol-compatible with the SkyPasteWindows app:
/// - POST /paste  {"text" | "imageBase64", "name", "device", "createdAt"} + X-SkyPaste-Token header
/// - GET  /pull?since=<unixSeconds> -> [{"text", "createdAt", "device"}]
/// - UDP beacon on port 26178 {"id","name","port"}
public enum LanClipboardSync {
    static let discoveryPort: UInt16 = 26178
    static let idKey = "settings.lanSyncId"
    static let tokenKey = "settings.lanSyncToken"
    static let portKey = "settings.lanSyncPort"
    static let deviceNameKey = "settings.lanSyncDeviceName"
    static let peersKey = "settings.lanSyncPeers"

    // MARK: - Pairing helpers

    /// First non-loopback IPv4 address (for the pairing QR/URL shown in Preferences).
    static var localIPv4: String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let sa = item.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if result == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("127.") {
                    address = ip
                    break
                }
            }
        }
        return address
    }

    /// URL the phone opens (carries the pairing token in the query).
    static var pairingURL: URL? {
        guard let ip = localIPv4 else { return nil }
        return URL(string: "http://\(ip):\(listenPort)/?t=\(token)")
    }

    /// Generates a QR code image for the pairing URL (CoreImage, no deps).
    static func qrImage(for string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    // MARK: - Settings surface

    public static var token: String {
        if let saved = UserDefaults.standard.string(forKey: tokenKey), saved.count >= 8 {
            return saved
        }
        let generated = String(UUID().uuidString.prefix(12)).uppercased()
        UserDefaults.standard.set(generated, forKey: tokenKey)
        return generated
    }

    public static var deviceName: String {
        let saved = UserDefaults.standard.string(forKey: deviceNameKey)
        if let saved, !saved.isEmpty {
            return saved
        }
        return Host.current().localizedName ?? "Mac"
    }

    static var deviceId: String {
        if let saved = UserDefaults.standard.string(forKey: idKey) {
            return saved
        }
        let generated = String(UUID().uuidString.prefix(8))
        UserDefaults.standard.set(generated, forKey: idKey)
        return generated
    }

    static var listenPort: UInt16 {
        let value = UserDefaults.standard.integer(forKey: portKey)
        return (1024...65535).contains(value) ? UInt16(value) : 26177
    }

    public struct Peer: Codable, Equatable {
        public var id: String
        public var name: String
        public var host: String
        public var port: Int
    }

    static var peers: [Peer] {
        get {
            guard let data = UserDefaults.standard.data(forKey: peersKey) else { return [] }
            return (try? JSONDecoder().decode([Peer].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: peersKey)
            }
        }
    }

    // MARK: - Server

    static var listener: NWListener?
    static var beaconConnection: NWConnection?
    static var beaconTimer: Timer?
    static var pullTimer: Timer?
    static var lastPullCursors: [String: Date] = [:]
    static weak var attachedStore: ClipboardStore?

    /// Called by the coordinator after settings change; safe to call repeatedly.
    static func applyCurrentSetting(store: ClipboardStore?) {
        stop()
        attachedStore = store
        guard UserDefaults.standard.bool(forKey: "settings.lanSyncEnabled") else { return }
        startServer()
        startBeacon()
        startPullTimer()
    }

    public static func stop() {
        listener?.cancel()
        listener = nil
        beaconConnection?.cancel()
        beaconConnection = nil
        beaconTimer?.invalidate()
        beaconTimer = nil
        pullTimer?.invalidate()
        pullTimer = nil
    }

    static func startServer() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: listenPort) ?? 26177)
            self.listener = listener
            listener.newConnectionHandler = { connection in
                receiveHTTP(connection, accumulated: Data())
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    NSLog("SkyPaste LAN server failed: \(error)")
                    LanClipboardSync.listener?.cancel()
                    LanClipboardSync.listener = nil
                case .ready:
                    NSLog("SkyPaste LAN server ready")
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "com.huaibor.skypaste.lan-server"))
        } catch {
            NSLog("SkyPaste LAN server failed to start: \(error)")
        }
    }

    // MARK: - Minimal HTTP parsing over NWConnection

    struct HTTPRequest {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data
    }

    static func receiveHTTP(_ connection: NWConnection, accumulated: Data) {
        connection.start(queue: DispatchQueue(label: "com.huaibor.skypaste.lan-conn"))
        receiveRequest(connection, accumulated: accumulated)
    }

    static func receiveRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var buffer = accumulated
            if let data {
                buffer.append(data)
            }
            if let request = parseHTTP(buffer) {
                let response = route(request)
                send(response: response, on: connection)
            } else if error == nil, !isComplete, buffer.count < 32 * 1024 * 1024 {
                receiveRequest(connection, accumulated: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    static func parseHTTP(_ data: Data) -> HTTPRequest? {
        guard let text = String(data: data, encoding: .utf8),
              let headerEndRange = text.range(of: "\r\n\r\n") else {
            return nil
        }
        let headerBlock = String(text[..<headerEndRange.lowerBound])
        // The body may contain binary-safe base64 only; utf8 re-encode is safe for this protocol.
        var body = Data()
        if let bodyData = String(text[headerEndRange.upperBound...]).data(using: .utf8) {
            body = bodyData
        }
        let lines = headerBlock.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let tokens = line.components(separatedBy: ":")
            if tokens.count >= 2 {
                headers[tokens[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                    tokens[1...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
        }

        if let lengthText = headers["content-length"], let expected = Int(lengthText), body.count < expected {
            return nil
        }

        var path = parts[1]
        var query: [String: String] = [:]
        if let questionMark = path.firstIndex(of: "?") {
            let queryText = String(path[path.index(after: questionMark)...])
            path = String(path[..<questionMark])
            for pair in queryText.components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 {
                    query[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                }
            }
        }
        return HTTPRequest(method: parts[0], path: path, query: query, headers: headers, body: body)
    }

    static func send(response: (code: Int, body: Data, contentType: String), on connection: NWConnection) {
        let cacheControl = response.contentType.hasPrefix("text/html") ? "Cache-Control: no-store\n" : ""
        let statusText: String
        switch response.code {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 403: statusText = "Forbidden"
        default: statusText = "Not Found"
        }
        let head = "HTTP/1.1 \(response.code) \(statusText)\r\nContent-Type: \(response.contentType); charset=utf-8\r\n\(cacheControl)Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Debug log for pairing issues (tmp file, overwritten by nothing else).
    private static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func lanDebug(_ line: String) {
        let stamped = "\(logFormatter.string(from: Date())) \(line)\n"
        if let handle = FileHandle(forWritingAtPath: "/tmp/skypaste-lan-debug.log") {
            handle.seekToEndOfFile()
            handle.write(stamped.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? stamped.write(to: URL(fileURLWithPath: "/tmp/skypaste-lan-debug.log"), atomically: true, encoding: .utf8)
        }
    }

    static func route(_ request: HTTPRequest) -> (code: Int, body: Data, contentType: String) {
        // The web clipboard shell is public; the API endpoints below enforce the token.
        if request.path == "/" {
            return (200, Data(webClipboardHTML().utf8), "text/html")
        }
        let provided = request.headers["x-skypaste-token"] ?? "(none)"
        lanDebug("REQ \(request.method) \(request.path) provided=\(provided) expectedPrefix=\(token.prefix(4))… len=\(token.count) match=\(provided == token)")
        guard provided == token else {
            return json(401, "{\"error\":\"unauthorized\"}")
        }
        switch request.path {
        case "/paste":
            return handlePaste(request)
        case "/pull":
            return handlePull(request)
        default:
            return json(404, "{\"error\":\"not found\"}")
        }
    }

    private static func json(_ code: Int, _ body: String) -> (code: Int, body: Data, contentType: String) {
        (code, Data(body.utf8), "application/json")
    }

    struct PastePayload: Codable {
        var text: String?
        var imageBase64: String?
        var name: String?
        var device: String?
        var createdAt: Date?
    }

    static func handlePaste(_ request: HTTPRequest) -> (code: Int, body: Data, contentType: String) {
        guard attachedStore != nil else {
            return (500, Data("{\"error\":\"no store\"}".utf8), "application/json")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(PastePayload.self, from: request.body) else {
            return (400, Data("{\"error\":\"bad payload\"}".utf8), "application/json")
        }
        let sender = payload.device?.isEmpty == false ? payload.device! : "unknown"
        guard let store = attachedStore else {
            return (500, Data("{\"error\":\"no store\"}".utf8), "application/json")
        }

        DispatchQueue.main.async {
            if let text = payload.text, !text.isEmpty {
                store.addCloudSyncedItem(
                    ClipboardItem(
                        content: .text(text),
                        fingerprint: "txt:" + text,
                        source: .cloudKit)
                        .withSourceApp(ClipboardSourceApp(bundleID: "lan:\(sender)", name: sender)))
            } else if let imageBase64 = payload.imageBase64,
                      let data = Data(base64Encoded: imageBase64), !data.isEmpty {
                var name = payload.name ?? "phone-image.png"
                if !(name.hasSuffix(".png") || name.hasSuffix(".jpg") || name.hasSuffix(".jpeg")) {
                    name += ".png"
                }
                let fingerprint = "img:" + data.prefix(64).base64EncodedString() + ":\(data.count)"
                store.addCloudSyncedItem(
                    ClipboardItem(
                        content: .image(data: data, name: name, originalByteCount: data.count, previewOnly: false),
                        fingerprint: fingerprint,
                        source: .cloudKit))
            }
        }
        return (200, Data("{\"ok\":true}".utf8), "application/json")
    }

    struct PullItem: Codable {
        var text: String
        var createdAt: Date
        var device: String
    }

    static func handlePull(_ request: HTTPRequest) -> (code: Int, body: Data, contentType: String) {
        guard let store = attachedStore else {
            return (500, Data("[]".utf8), "application/json")
        }
        var since = Date.distantPast
        if let sinceText = request.query["since"], let seconds = Double(sinceText) {
            since = Date(timeIntervalSince1970: seconds)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var body = Data("[]".utf8)
        let readBlock = { Self.encodePullItems(store: store, since: since, encoder: encoder) }
        if Thread.isMainThread {
            // Compile-time MainActor hop is unavailable in this sync context;
            // dispatch onto the main queue and wait (items read is short).
            DispatchQueue.main.sync {
                body = readBlock()
            }
        } else {
            DispatchQueue.main.sync {
                body = readBlock()
            }
        }
        return (200, body, "application/json")
    }

    private static func encodePullItems(store: ClipboardStore, since: Date, encoder: JSONEncoder) -> Data {
        MainActor.assumeIsolated {
            let items = store.itemsEligibleForCloudSync()
                .filter { $0.createdAt > since }
                .prefix(100)
                .compactMap { item -> PullItem? in
                    guard case let .text(text) = item.content else { return nil }
                    return PullItem(text: text, createdAt: item.createdAt, device: deviceName)
                }
            return (try? encoder.encode(items)) ?? Data("[]".utf8)
        }
    }

    // MARK: - Discovery beacon (UDP 26178)

    struct Beacon: Codable {
        var id: String
        var name: String
        var port: Int
    }

    static var beaconListener: NWConnection?

    static func startBeacon() {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(
            host: NWEndpoint.Host("255.255.255.255"),
            port: NWEndpoint.Port(rawValue: discoveryPort)!,
            using: parameters)
        beaconConnection = connection
        connection.start(queue: DispatchQueue(label: "com.huaibor.skypaste.lan-beacon"))

        listenForBeacons()

        beaconTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            sendBeacon()
        }
        sendBeacon()
    }

    static func sendBeacon() {
        guard let connection = beaconConnection else { return }
        let beacon = Beacon(id: deviceId, name: deviceName, port: Int(listenPort))
        guard let data = try? JSONEncoder().encode(beacon) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    static func listenForBeacons() {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let listener = NWConnection(
            host: NWEndpoint.Host("0.0.0.0"),
            port: NWEndpoint.Port(rawValue: discoveryPort)!,
            using: parameters)
        beaconListener = listener
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                receiveBeacon(listener)
            }
        }
        listener.start(queue: DispatchQueue(label: "com.huaibor.skypaste.lan-beacon-listen"))
    }

    static func receiveBeacon(_ connection: NWConnection) {
        connection.receiveMessage { data, _, _, error in
            if let data,
               let beacon = try? JSONDecoder().decode(Beacon.self, from: data),
               beacon.id != deviceId {
                recordPeer(beacon, remoteHost: remoteHost(of: connection))
            }
            if error == nil {
                receiveBeacon(connection)
            }
        }
    }

    static func remoteHost(of connection: NWConnection) -> String? {
        if case let .hostPort(host, _) = connection.endpoint {
            switch host {
            case .ipv4(let address):
                return "\(address)"
            case .ipv6(let address):
                return "\(address)"
            default:
                return nil
            }
        }
        return nil
    }

    static func recordPeer(_ beacon: Beacon, remoteHost: String?) {
        let host = remoteHost ?? beacon.name
        var current = peers
        if let index = current.firstIndex(where: { $0.id == beacon.id }) {
            current[index].name = beacon.name
            current[index].host = host
            current[index].port = beacon.port
        } else {
            current.append(Peer(id: beacon.id, name: beacon.name, host: host, port: beacon.port))
        }
        peers = current
    }

    // MARK: - Pull loop (Windows -> Mac)

    static func startPullTimer() {
        pullTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            pullPeers()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            pullPeers()
        }
    }

    static func pullPeers() {
        guard let store = attachedStore else { return }
        for peer in peers {
            let since = Int(lastPullCursors[peer.id]?.timeIntervalSince1970 ?? 0)
            guard let url = URL(string: "http://\(peer.host):\(peer.port)/pull?since=\(since)") else {
                continue
            }
            var request = URLRequest(url: url)
            request.setValue(token, forHTTPHeaderField: "X-SkyPaste-Token")
            request.timeoutInterval = 5
            URLSession.shared.dataTask(with: request) { data, response, error in
                guard error == nil,
                      let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200,
                      let data else {
                    return
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                guard let items = try? decoder.decode([PullItem].self, from: data) else {
                    return
                }
                DispatchQueue.main.async {
                    var newest = lastPullCursors[peer.id] ?? Date.distantPast
                    for item in items where !item.text.isEmpty {
                        store.addCloudSyncedItem(
                            ClipboardItem(
                                content: .text(item.text),
                                fingerprint: "txt:" + item.text,
                                source: .cloudKit)
                                .withSourceApp(ClipboardSourceApp(bundleID: "lan:\(peer.name)", name: item.device)))
                        newest = max(newest, item.createdAt)
                    }
                    lastPullCursors[peer.id] = newest
                }
            }.resume()
        }
    }

    // MARK: - Outgoing push (Mac -> Windows, used by the Send-to-PC action)

    /// Pushes the current local clipboard text to a specific peer immediately.
    public static func sendText(_ text: String, to peer: Peer) {
        guard !text.isEmpty else { return }
        guard let url = URL(string: "http://\(peer.host):\(peer.port)/paste") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-SkyPaste-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try? encoder.encode(
            PastePayload(text: text, imageBase64: nil, name: nil, device: deviceName, createdAt: Date()))
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - Web clipboard page (zero-install phone access)

    /// Self-contained web clipboard page: token via ?t= (persisted to
    /// localStorage), send-from-phone-clipboard and copy-back UI. No installs.
    static func webClipboardHTML() -> String {
        let title = "\u{2022} \(deviceName)"
        let sendTo = "\u{53d1}\u{9001}\u{5230}\u{8fd9}\u{53f0}\u{7535}\u{8111} Send to this computer"
        let recent = "\u{7535}\u{8111}\u{7aef}\u{6700}\u{8fd1}\u{5185}\u{5bb9} Recent from this computer"
        return """
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SkyPaste \(title)</title>
<style>
* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
body { font-family: -apple-system, "PingFang SC", sans-serif; margin: 0; background: #f5f6fa; color: #141414; }
header { background: linear-gradient(135deg, #146bf0aa, #146bf022); padding: 18px 16px; }
header h1 { margin: 0; font-size: 18px; }
header p { margin: 4px 0 0; font-size: 12px; opacity: .75; }
main { padding: 14px; max-width: 560px; margin: 0 auto; }
section { background: #fff; border-radius: 14px; padding: 14px; margin-bottom: 14px; box-shadow: 0 1px 4px #0001; }
textarea { width: 100%; min-height: 96px; border: 1px solid #d8dbe4; border-radius: 10px; padding: 10px; font-size: 15px; resize: vertical; }
button { background: #146bf0; color: #fff; border: 0; border-radius: 20px; padding: 10px 18px; font-size: 15px; font-weight: 600; }
button.ghost { background: #eef2fb; color: #146bf0; }
.row { display: flex; gap: 10px; margin-top: 10px; }
.row button { flex: 1; }
ul { list-style: none; margin: 0; padding: 0; }
li { display: flex; align-items: center; gap: 8px; padding: 9px 0; border-bottom: 1px solid #f0f1f5; }
li span { flex: 1; font-size: 14px; word-break: break-all; }
li button { padding: 6px 14px; font-size: 13px; }
.empty { color: #8a8a8e; font-size: 13px; text-align: center; padding: 14px 0; }
#msg { text-align: center; font-size: 13px; color: #1f9e8c; min-height: 18px; margin: 0 0 8px; }
</style>
</head>
<body>
<header><h1>SkyPaste \(title)</h1><p>\u{5c40}\u{57df}\u{7f51}\u{76f4}\u{4f20} \u{b7} \u{6570}\u{636e}\u{4e0d}\u{51fa}\u{5185}\u{7f51} \u{b7} LAN direct, no cloud</p></header>
<main>
<p id="msg"></p>
<section id="tokenBox" style="display:none">
<p><b>首次使用 / First visit</b></p>
<p style="font-size:13px;color:#8a8a8e">令牌无效。请重新扫描电脑端设置里的二维码打开本页（推荐，无需输入）；或在下方输入电脑端显示的配对令牌。Token invalid — re-scan the QR in desktop Preferences (recommended), or enter the token below.</p>
<input id="tokenInput" style="width:100%;padding:10px;border:1px solid #d8dbe4;border-radius:10px;font-size:15px" placeholder="Pairing token">
<div class="row"><button onclick="saveToken()">保存 Save</button></div>
</section>

<section>
<p><b>\(sendTo)</b></p>
<textarea id="text" placeholder="\u{7c98}\u{8d34}\u{6216}\u{8f93}\u{5165}\u{5185}\u{5bb9}\u{2026}"></textarea>
<div class="row">
<button class="ghost" onclick="readClip()">\u{8bfb}\u{53d6}\u{624b}\u{673a}\u{526a}\u{8d34}\u{677f}</button>
<button onclick="sendText()">\u{53d1}\u{9001}</button>
</div>
</section>
<section>
<p><b>\(recent)</b> <button class="ghost" style="padding:6px 14px;font-size:13px;float:right" onclick="pull()">\u{5237}\u{65b0}</button></p>
<ul id="list"></ul>
<div class="empty" id="empty">\u{6682}\u{65e0}\u{5185}\u{5bb9}</div>
</section>
<script>
const params = new URLSearchParams(location.search);
let token = params.get('t') || localStorage.getItem('sp_token') || '';
if (params.get('t')) { localStorage.setItem('sp_token', token); history.replaceState(null, '', location.pathname); }
function msg(t) { const m = document.getElementById('msg'); m.textContent = t; setTimeout(() => m.textContent = '', 2500); }
function showTokenBox(prefill) {
  document.getElementById('tokenInput').value = prefill || '';
  document.getElementById('tokenBox').style.display = 'block';
}
function sanitizeToken(v) {
  // Strip whitespace and zero-width chars from copy/pasted tokens.
  return (v || '').replace(/\\s+/g, '').replace(/[\\u200b\\u200c\\u200d\\ufeff]/g, '');
}
async function api(path, opts) {
  const r = await fetch(path, Object.assign({ headers: { 'X-SkyPaste-Token': token } }, opts));
  if (r.status === 401) {
    // Keep the stored token for reference; rescan is the zero-typing path.
    showTokenBox(token);
    throw new Error('unauthorized');
  }
  return r;
}
async function readClip() {
  try { document.getElementById('text').value = await navigator.clipboard.readText(); }
  catch (e) { msg('read blocked, paste manually'); }
}
async function sendText() {
  const boxToken = sanitizeToken(document.getElementById('tokenInput').value);
  if (boxToken && boxToken !== token) { token = boxToken; localStorage.setItem('sp_token', token); }
  const text = document.getElementById('text').value;
  if (!text.trim()) { msg('empty'); return; }
  let r;
  try { r = await api('/paste', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text: text, device: '\u{624b}\u{673a}\u{7f51}\u{9875}' }) }); }
  catch (e) { msg('token required'); return; }
  if (r.ok) { msg('✓ sent'); document.getElementById('text').value = ''; pull(); }
  else msg('failed ' + r.status);
}
async function copyItem(text) {
  try { await navigator.clipboard.writeText(text); msg('✓ copied'); }
  catch (e) { msg('copy blocked'); }
}
async function pull() {
  const boxToken = sanitizeToken(document.getElementById('tokenInput').value);
  if (boxToken && boxToken !== token) { token = boxToken; localStorage.setItem('sp_token', token); }
  let r;
  try { r = await api('/pull?since=0'); }
  catch (e) { return; }
  if (!r.ok) return;
  const items = await r.json();
  const list = document.getElementById('list');
  list.innerHTML = '';
  document.getElementById('empty').style.display = items.length ? 'none' : 'block';
  items.slice(0, 20).forEach(it => {
    const li = document.createElement('li');
    const s = document.createElement('span');
    s.textContent = it.text.length > 120 ? it.text.slice(0, 120) + '…' : it.text;
    const b = document.createElement('button');
    b.className = 'ghost'; b.textContent = '\u{590d}\u{5236}';
    b.onclick = () => copyItem(it.text);
    li.appendChild(s); li.appendChild(b); list.appendChild(li);
  });
}
pull();
</script>
</body>
</html>
"""
    }
}
