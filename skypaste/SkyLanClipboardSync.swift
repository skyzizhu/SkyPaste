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

    static func send(response: (code: Int, body: Data), on connection: NWConnection) {
        let statusText: String
        switch response.code {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 403: statusText = "Forbidden"
        default: statusText = "Not Found"
        }
        let head = "HTTP/1.1 \(response.code) \(statusText)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func route(_ request: HTTPRequest) -> (code: Int, body: Data) {
        guard request.headers["x-skypaste-token"] == token else {
            return (401, Data("{\"error\":\"unauthorized\"}".utf8))
        }
        switch request.path {
        case "/paste":
            return handlePaste(request)
        case "/pull":
            return handlePull(request)
        default:
            return (404, Data("{\"error\":\"not found\"}".utf8))
        }
    }

    struct PastePayload: Codable {
        var text: String?
        var imageBase64: String?
        var name: String?
        var device: String?
        var createdAt: Date?
    }

    static func handlePaste(_ request: HTTPRequest) -> (code: Int, body: Data) {
        guard attachedStore != nil else {
            return (500, Data("{\"error\":\"no store\"}".utf8))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(PastePayload.self, from: request.body) else {
            return (400, Data("{\"error\":\"bad payload\"}".utf8))
        }
        let sender = payload.device?.isEmpty == false ? payload.device! : "unknown"
        guard let store = attachedStore else {
            return (500, Data("{\"error\":\"no store\"}".utf8))
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
        return (200, Data("{\"ok\":true}".utf8))
    }

    struct PullItem: Codable {
        var text: String
        var createdAt: Date
        var device: String
    }

    static func handlePull(_ request: HTTPRequest) -> (code: Int, body: Data) {
        guard let store = attachedStore else {
            return (500, Data("[]".utf8))
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
        return (200, body)
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
}
