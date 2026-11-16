import Foundation
import Network

// MARK: - Prism endpoint: a small HTTP/1.1 server
//
// One request per connection (responses close the connection), bodies by
// Content-Length or chunked, streaming responses written as they arrive.

struct GatewayHTTPRequest: Sendable {
    let method: String
    let path: String
    let query: String
    /// Lower-cased names.
    let headers: [String: String]
    let body: Data
    let remote: String
}

final class GatewayResponseWriter: @unchecked Sendable {
    private let connection: NWConnection
    private var started = false
    private(set) var failed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    static let corsHeaders: [(String, String)] = [
        ("Access-Control-Allow-Origin", "*"),
        ("Access-Control-Allow-Headers", "*"),
        ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
        ("Access-Control-Expose-Headers", "X-Prism-Identity, X-Prism-Upstream"),
    ]

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 529: return "Overloaded"
        default: return "Status"
        }
    }

    private func head(_ status: Int, _ headers: [(String, String)]) -> Data {
        var s = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (k, v) in headers + Self.corsHeaders + [("Connection", "close")] {
            s += "\(k): \(v)\r\n"
        }
        return Data((s + "\r\n").utf8)
    }

    private func raw(_ data: Data, last: Bool = false) async -> Bool {
        guard !failed else { return false }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            // TCP is a byte stream: .defaultStream sends at once;
            // isComplete closes our side after the last bytes.
            connection.send(content: data, contentContext: .defaultStream,
                            isComplete: last, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.failed = true }
                c.resume(returning: error == nil)
            })
        }
    }

    /// A complete response.
    func send(status: Int, headers: [(String, String)] = [], body: Data) async {
        guard !started else { return }
        started = true
        var h = headers
        h.append(("Content-Length", "\(body.count)"))
        _ = await raw(head(status, h) + body, last: true)
        connection.cancel()
    }

    func sendJSON(status: Int, _ object: Any, headers: [(String, String)] = []) async {
        await send(status: status, headers: [("Content-Type", "application/json")] + headers, body: GatewayJSON.data(object))
    }

    private var chunked = false

    /// Start a streamed response (chunked transfer encoding).
    func startStream(status: Int, headers: [(String, String)]) async {
        guard !started else { return }
        started = true
        chunked = true
        _ = await raw(head(status, headers + [("Cache-Control", "no-cache"), ("X-Accel-Buffering", "no"),
                                              ("Transfer-Encoding", "chunked")]))
    }

    /// False once the client has gone away.
    func write(_ data: Data) async -> Bool {
        guard !data.isEmpty else { return !failed }
        guard chunked else { return await raw(data) }
        var framed = Data(String(data.count, radix: 16).utf8)
        framed.append(contentsOf: [0x0D, 0x0A])
        framed.append(data)
        framed.append(contentsOf: [0x0D, 0x0A])
        return await raw(framed)
    }

    func write(_ text: String) async -> Bool {
        await write(Data(text.utf8))
    }

    func finish() async {
        _ = await raw(chunked ? Data("0\r\n\r\n".utf8) : Data(), last: true)
        connection.cancel()
    }
}

final class GatewayServer: @unchecked Sendable {
    typealias Handler = @Sendable (GatewayHTTPRequest, GatewayResponseWriter) async -> Void

    static let maxBody = 64 * 1024 * 1024

    private let queue = DispatchQueue(label: "com.mojolayers.prism.endpoint")
    private var listener: NWListener?
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// `onState` reports .ready, or the failure (e.g. port in use).
    func start(port: Int, allowLAN: Bool, onState: @escaping @Sendable (NWListener.State) -> Void) throws {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            throw NSError(domain: "Prism", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        if allowLAN {
            listener = try NWListener(using: params, on: nwPort)
        } else {
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
            listener = try NWListener(using: params)
        }
        listener.stateUpdateHandler = onState
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        let handler = self.handler
        Task {
            guard let req = await Self.read(conn) else {
                conn.cancel()
                return
            }
            let writer = GatewayResponseWriter(connection: conn)
            if req.method == "__TOO_LARGE__" {
                await writer.sendJSON(status: 413, ["error": ["message": "Request body too large"]])
                return
            }
            await handler(req, writer)
        }
    }

    // MARK: Reading

    private static func receive(_ conn: NWConnection) async -> (Data?, Bool) {
        await withCheckedContinuation { c in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                c.resume(returning: (data, isComplete || error != nil))
            }
        }
    }

    private static let headerEnd = Data("\r\n\r\n".utf8)

    static func read(_ conn: NWConnection) async -> GatewayHTTPRequest? {
        var buffer = Data()
        var headerRange: Range<Data.Index>?
        while headerRange == nil {
            let (data, done) = await receive(conn)
            if let data { buffer.append(data) }
            headerRange = buffer.range(of: headerEnd)
            if headerRange == nil && (done || buffer.count > 256 * 1024) { return nil }
        }
        guard let hr = headerRange,
              let head = String(data: buffer[buffer.startIndex..<hr.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        var body = Data(buffer[hr.upperBound...])

        if headers["expect"]?.lowercased() == "100-continue" {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                conn.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in c.resume() })
            }
        }

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            while true {
                if let decoded = dechunk(body) {
                    body = decoded
                    break
                }
                if body.count > maxBody { return tooLarge(requestLine) }
                let (data, done) = await receive(conn)
                if let data { body.append(data) }
                if done && dechunk(body) == nil { return nil }
            }
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? 0
            if length > maxBody { return tooLarge(requestLine) }
            while body.count < length {
                let (data, done) = await receive(conn)
                if let data { body.append(data) }
                if done && body.count < length { return nil }
            }
            if body.count > length { body = body.prefix(length) }
        }

        let target = requestLine[1]
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        let remote: String
        if case .hostPort(let host, _) = conn.endpoint { remote = "\(host)" } else { remote = "" }
        return GatewayHTTPRequest(method: requestLine[0].uppercased(),
                                  path: parts.first ?? "/",
                                  query: parts.count > 1 ? parts[1] : "",
                                  headers: headers, body: body, remote: remote)
    }

    private static func tooLarge(_ line: [String]) -> GatewayHTTPRequest {
        GatewayHTTPRequest(method: "__TOO_LARGE__", path: line.count > 1 ? line[1] : "/", query: "",
                           headers: [:], body: Data(), remote: "")
    }

    /// Decoded body once the final zero-length chunk has arrived, else nil.
    static func dechunk(_ data: Data) -> Data? {
        var out = Data()
        var i = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: i..<data.endIndex) else { return nil }
            let sizeText = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeText, radix: 16) else { return nil }
            let start = lineEnd.upperBound
            if size == 0 { return out }
            guard data.distance(from: start, to: data.endIndex) >= size + 2 else { return nil }
            let end = data.index(start, offsetBy: size)
            out.append(data[start..<end])
            i = data.index(end, offsetBy: 2)
        }
    }
}
