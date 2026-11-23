import Foundation
import Darwin

public struct AutomationPadSummary: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    public var isSelected: Bool
    public var isHibernated: Bool
    public var isMuted: Bool
    public var badge: String?

    public init(
        id: String,
        title: String,
        url: String,
        isSelected: Bool,
        isHibernated: Bool,
        isMuted: Bool,
        badge: String?
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.isSelected = isSelected
        self.isHibernated = isHibernated
        self.isMuted = isMuted
        self.badge = badge
    }
}

public struct AutomationPageSnapshot: Codable, Equatable, Sendable {
    public var padID: String
    public var title: String
    public var url: String
    public var text: String

    public init(padID: String, title: String, url: String, text: String) {
        self.padID = padID
        self.title = title
        self.url = url
        self.text = text
    }
}

public enum AutomationBridgeError: Error, LocalizedError, Equatable, Sendable {
    case padNotFound(String)
    case extensionNotFound(String)
    case extensionCommandNotFound(String)
    case pageLoadTimedOut(title: String, url: String, timeoutSeconds: Double)
    case jsExecutionDisabled
    case scriptTooLong(maxCharacters: Int)
    case evaluationFailed(String)
    case invalidArguments(String)

    public var errorDescription: String? {
        switch self {
        case .padNotFound(let q): "Pad not found: \(q)"
        case .extensionNotFound(let q): "Extension not found or not loaded: \(q)"
        case .extensionCommandNotFound(let cmd): "Extension command not found: \(cmd)"
        case .pageLoadTimedOut(let title, let url, let sec):
            "Timed out after \(Int(sec))s waiting for '\(title)' (\(url)) to finish loading."
        case .jsExecutionDisabled: "JavaScript execution is disabled in \(AppBrandIdentity.productName) Automation settings."
        case .scriptTooLong(let max): "Script exceeds maximum allowed length of \(max) characters."
        case .evaluationFailed(let msg): "JavaScript evaluation failed: \(msg)"
        case .invalidArguments(let msg): "Invalid arguments: \(msg)"
        }
    }
}

public protocol AutomationRuntimeBridge: Sendable {
    func listPads() async -> [AutomationPadSummary]
    func getPageSnapshot(padQuery: String?) async throws -> AutomationPageSnapshot
    func navigate(padQuery: String?, to url: URL) async throws -> AutomationPadSummary
    func evaluateLimitedJS(padQuery: String?, script: String) async throws -> String
    func togglePanel(visible: Bool?) async -> Bool
    func listExtensions() async -> [AutomationExtensionSummary]
    func performExtensionCommand(
        extensionQuery: String,
        commandID: String,
        padQuery: String?
    ) async throws -> AutomationExtensionCommandResult
}

extension AutomationRuntimeBridge {
    public func listExtensions() async -> [AutomationExtensionSummary] {
        []
    }

    public func performExtensionCommand(
        extensionQuery: String,
        commandID: String,
        padQuery: String?
    ) async throws -> AutomationExtensionCommandResult {
        throw AutomationBridgeError.extensionNotFound(extensionQuery)
    }
}

public enum LocalAutomationServerError: Error, LocalizedError, Sendable {
    case serverDisabled
    case emptyAuthToken
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .serverDisabled: "Automation server is disabled."
        case .emptyAuthToken: "Automation server requires a non-empty authentication token."
        case .socketCreationFailed(let code): "Failed to create loopback socket (errno \(code))."
        case .bindFailed(let code): "Failed to bind 127.0.0.1 socket (errno \(code))."
        case .listenFailed(let code): "Failed to listen on 127.0.0.1 socket (errno \(code))."
        }
    }
}

/// Opt-in localhost-only (`127.0.0.1`) HTTP & MCP JSON-RPC 2.0 server protected by bearer token authentication.
public actor LocalAutomationServer {
    public static let maxScriptLength = 4096
    public static let maxRequestBytes = 65_536

    private let bridge: any AutomationRuntimeBridge
    private var settings: AutomationSettings
    private var serverFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    public private(set) var boundPort: UInt16?

    public var isRunning: Bool {
        serverFD >= 0 && boundPort != nil
    }

    public init(settings: AutomationSettings, bridge: any AutomationRuntimeBridge) {
        self.settings = settings
        self.bridge = bridge
    }

    public func updateSettings(_ newSettings: AutomationSettings) async throws {
        let needsRestart = isRunning && (newSettings.port != settings.port || !newSettings.isEnabled)
        self.settings = newSettings
        if !newSettings.isEnabled {
            stop()
        } else if needsRestart {
            stop()
            try start()
        } else if !isRunning && newSettings.isEnabled {
            try start()
        }
    }

    public func start() throws {
        guard settings.isEnabled else {
            throw LocalAutomationServerError.serverDisabled
        }
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw LocalAutomationServerError.emptyAuthToken
        }
        if isRunning { return }

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw LocalAutomationServerError.socketCreationFailed(errno)
        }

        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Bind strictly to 127.0.0.1 (INADDR_LOOPBACK = 0x7f000001)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = settings.port.bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw LocalAutomationServerError.bindFailed(err)
        }

        guard Darwin.listen(fd, 16) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw LocalAutomationServerError.listenFailed(err)
        }

        var actualAddr = sockaddr_in()
        var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actualAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.getsockname(fd, sockPtr, &actualLen)
            }
        }

        self.serverFD = fd
        self.boundPort = UInt16(bigEndian: actualAddr.sin_port)

        let capturedFD = fd
        self.acceptTask = Task.detached(priority: .utility) { [weak self] in
            await Self.acceptLoop(listenFD: capturedFD, server: self)
        }
    }

    public func stop() {
        acceptTask?.cancel()
        acceptTask = nil
        if serverFD >= 0 {
            Darwin.shutdown(serverFD, SHUT_RDWR)
            Darwin.close(serverFD)
            serverFD = -1
        }
        boundPort = nil
    }

    private static func acceptLoop(listenFD: Int32, server: LocalAutomationServer?) async {
        while !Task.isCancelled {
            let clientFD = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    var clientAddr = sockaddr_in()
                    var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let accepted = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            Darwin.accept(listenFD, sockPtr, &clientLen)
                        }
                    }
                    continuation.resume(returning: accepted)
                }
            }

            if clientFD < 0 {
                break
            }

            Task.detached(priority: .utility) {
                await Self.handleClientConnection(clientFD: clientFD, server: server)
            }
        }
    }

    private static func handleClientConnection(clientFD: Int32, server: LocalAutomationServer?) async {
        defer {
            Darwin.shutdown(clientFD, SHUT_RDWR)
            Darwin.close(clientFD)
        }

        var noSigPipe: Int32 = 1
        _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let request = readHTTPRequest(from: clientFD),
              let server else {
            return
        }

        let response = await server.route(request: request)
        writeHTTPResponse(response, to: clientFD)
    }

    // MARK: - HTTP Parsing & Routing

    private struct HTTPRequest: Sendable {
        var method: String
        var rawTarget: String
        var headers: [String: String]
        var body: Data
    }

    private struct HTTPResponse: Sendable {
        var statusCode: Int
        var statusText: String
        var body: Data

        static func json(_ statusCode: Int, statusText: String = "OK", object: Any) -> HTTPResponse {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            return HTTPResponse(statusCode: statusCode, statusText: statusText, body: data)
        }

        static func encodable<T: Encodable>(_ statusCode: Int, statusText: String = "OK", value: T) -> HTTPResponse {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
            return HTTPResponse(statusCode: statusCode, statusText: statusText, body: data)
        }
    }

    private func route(request: HTTPRequest) async -> HTTPResponse {
        // Constant-time token verification
        guard isAuthorized(headers: request.headers) else {
            return .json(401, statusText: "Unauthorized", object: ["error": "Invalid or missing bearer token"])
        }

        let urlComponents = URLComponents(string: "http://127.0.0.1\(request.rawTarget)")
        let path = urlComponents?.path ?? request.rawTarget
        let queryParams = Dictionary(
            (urlComponents?.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            },
            uniquingKeysWith: { _, last in last }
        )

        do {
            switch (request.method.uppercased(), path) {
            case ("GET", "/v1/health"):
                return .json(200, object: ["status": "ok", "bind": "127.0.0.1"])

            case ("GET", "/v1/pads"):
                let pads = await bridge.listPads()
                return .encodable(200, value: ["pads": pads])

            case ("GET", "/v1/pads/content"):
                let snapshot = try await bridge.getPageSnapshot(padQuery: queryParams["pad"])
                return .encodable(200, value: snapshot)

            case ("POST", "/v1/pads/navigate"):
                let payload = try parseJSONBody(request.body)
                guard let urlStr = payload["url"] as? String,
                      let targetURL = URL(string: urlStr),
                      targetURL.scheme != nil else {
                    return .json(400, statusText: "Bad Request", object: ["error": "Valid url field required"])
                }
                let updated = try await bridge.navigate(padQuery: payload["pad"] as? String, to: targetURL)
                return .encodable(200, value: updated)

            case ("POST", "/v1/pads/eval"):
                guard settings.allowLimitedJS else {
                    return .json(403, statusText: "Forbidden", object: ["error": AutomationBridgeError.jsExecutionDisabled.localizedDescription])
                }
                let payload = try parseJSONBody(request.body)
                guard let script = payload["script"] as? String else {
                    return .json(400, statusText: "Bad Request", object: ["error": "script field required"])
                }
                guard script.count <= Self.maxScriptLength else {
                    return .json(400, statusText: "Bad Request", object: ["error": "Script exceeds \(Self.maxScriptLength) characters"])
                }
                let result = try await bridge.evaluateLimitedJS(padQuery: payload["pad"] as? String, script: script)
                return .json(200, object: ["result": result])

            case ("POST", "/v1/panel/toggle"):
                let payload = (try? parseJSONBody(request.body)) ?? [:]
                let visible = payload["visible"] as? Bool
                let isNowVisible = await bridge.togglePanel(visible: visible)
                return .json(200, object: ["visible": isNowVisible])

            case ("GET", "/v1/extensions"):
                let extensions = await bridge.listExtensions()
                return .encodable(200, value: ["extensions": extensions])

            case ("POST", "/v1/extensions/command"):
                let payload = try parseJSONBody(request.body)
                guard let extQuery = (payload["extension"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !extQuery.isEmpty else {
                    return .json(400, statusText: "Bad Request", object: ["error": "extension field required"])
                }
                guard let commandID = (payload["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !commandID.isEmpty else {
                    return .json(400, statusText: "Bad Request", object: ["error": "command field required"])
                }
                let result = try await bridge.performExtensionCommand(
                    extensionQuery: extQuery,
                    commandID: commandID,
                    padQuery: payload["pad"] as? String
                )
                return .encodable(200, value: result)

            case ("POST", "/mcp"):
                return await handleMCPJSONRPC(body: request.body)

            default:
                return .json(404, statusText: "Not Found", object: ["error": "Unknown endpoint \(request.method) \(path)"])
            }
        } catch let bridgeError as AutomationBridgeError {
            switch bridgeError {
            case .pageLoadTimedOut(let title, let url, _):
                return .json(504, statusText: "Gateway Timeout", object: [
                    "error": bridgeError.localizedDescription,
                    "title": title,
                    "url": url
                ])
            case .padNotFound, .extensionNotFound, .extensionCommandNotFound:
                return .json(404, statusText: "Not Found", object: ["error": bridgeError.localizedDescription])
            default:
                return .json(400, statusText: "Bad Request", object: ["error": bridgeError.localizedDescription])
            }
        } catch {
            return .json(400, statusText: "Bad Request", object: ["error": error.localizedDescription])
        }
    }

    // MARK: - MCP JSON-RPC 2.0 Handler

    private func handleMCPJSONRPC(body: Data) async -> HTTPResponse {
        guard let rpc = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .json(400, statusText: "Bad Request", object: [
                "jsonrpc": "2.0",
                "id": NSNull(),
                "error": ["code": -32700, "message": "Parse error"]
            ])
        }

        let rpcID: Any = rpc["id"] ?? NSNull()
        guard let method = rpc["method"] as? String else {
            return .json(400, statusText: "Bad Request", object: [
                "jsonrpc": "2.0",
                "id": rpcID,
                "error": ["code": -32600, "message": "Invalid Request"]
            ])
        }

        let params = (rpc["params"] as? [String: Any]) ?? [:]

        switch method {
        case "initialize":
            return .json(200, object: [
                "jsonrpc": "2.0",
                "id": rpcID,
                "result": [
                    "protocolVersion": "2024-11-05",
                    "serverInfo": ["name": AppBrandIdentity.productName, "version": AppBrandIdentity.marketingVersion],
                    "capabilities": ["tools": [:]]
                ]
            ])

        case "tools/list":
            let tools: [[String: Any]] = [
                [
                    "name": "list_pads",
                    "description": "List all pads in \(AppBrandIdentity.productName) with titles, URLs, and unread badges.",
                    "inputSchema": ["type": "object", "properties": [:]]
                ],
                [
                    "name": "get_page_content",
                    "description": "Get the current URL, title, and visible text of a pad.",
                    "inputSchema": [
                        "type": "object",
                        "properties": ["pad": ["type": "string", "description": "Optional pad ID or title"]]
                    ]
                ],
                [
                    "name": "navigate_pad",
                    "description": "Navigate a pad to a URL.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "url": ["type": "string"],
                            "pad": ["type": "string"]
                        ],
                        "required": ["url"]
                    ]
                ],
                [
                    "name": "run_limited_js",
                    "description": "Evaluate a bounded JavaScript snippet in a pad (when explicitly enabled).",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "script": ["type": "string"],
                            "pad": ["type": "string"]
                        ],
                        "required": ["script"]
                    ]
                ],
                [
                    "name": "toggle_panel",
                    "description": "Show, hide, or toggle the \(AppBrandIdentity.productName) slide-over panel.",
                    "inputSchema": [
                        "type": "object",
                        "properties": ["visible": ["type": "boolean"]]
                    ]
                ],
                [
                    "name": "list_extensions",
                    "description": "List installed browser extensions with enabled/loaded status, errors, and commands.",
                    "inputSchema": ["type": "object", "properties": [:]]
                ]
            ]
            return .json(200, object: [
                "jsonrpc": "2.0",
                "id": rpcID,
                "result": ["tools": tools]
            ])

        case "tools/call":
            guard let toolName = params["name"] as? String else {
                return mcpError(id: rpcID, code: -32602, message: "Missing tool name")
            }
            let args = (params["arguments"] as? [String: Any]) ?? [:]
            do {
                let textOutput: String
                switch toolName {
                case "list_pads":
                    let pads = await bridge.listPads()
                    let data = try JSONEncoder().encode(pads)
                    textOutput = String(decoding: data, as: UTF8.self)
                case "get_page_content":
                    let snap = try await bridge.getPageSnapshot(padQuery: args["pad"] as? String)
                    let data = try JSONEncoder().encode(snap)
                    textOutput = String(decoding: data, as: UTF8.self)
                case "navigate_pad":
                    guard let rawURL = args["url"] as? String,
                          let url = URL(string: rawURL),
                          url.scheme != nil else {
                        throw AutomationBridgeError.invalidArguments("Valid url required")
                    }
                    let summary = try await bridge.navigate(padQuery: args["pad"] as? String, to: url)
                    let data = try JSONEncoder().encode(summary)
                    textOutput = String(decoding: data, as: UTF8.self)
                case "run_limited_js":
                    guard settings.allowLimitedJS else {
                        throw AutomationBridgeError.jsExecutionDisabled
                    }
                    guard let script = args["script"] as? String else {
                        throw AutomationBridgeError.invalidArguments("script required")
                    }
                    guard script.count <= Self.maxScriptLength else {
                        throw AutomationBridgeError.scriptTooLong(maxCharacters: Self.maxScriptLength)
                    }
                    textOutput = try await bridge.evaluateLimitedJS(padQuery: args["pad"] as? String, script: script)
                case "toggle_panel":
                    let visible = await bridge.togglePanel(visible: args["visible"] as? Bool)
                    textOutput = "{\"visible\":\(visible)}"
                case "list_extensions":
                    let extensions = await bridge.listExtensions()
                    let data = try JSONEncoder().encode(extensions)
                    textOutput = String(decoding: data, as: UTF8.self)
                default:
                    return mcpError(id: rpcID, code: -32601, message: "Unknown tool \(toolName)")
                }

                return .json(200, object: [
                    "jsonrpc": "2.0",
                    "id": rpcID,
                    "result": [
                        "content": [["type": "text", "text": textOutput]],
                        "isError": false
                    ]
                ])
            } catch {
                return .json(200, object: [
                    "jsonrpc": "2.0",
                    "id": rpcID,
                    "result": [
                        "content": [["type": "text", "text": error.localizedDescription]],
                        "isError": true
                    ]
                ])
            }

        default:
            return mcpError(id: rpcID, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func mcpError(id: Any, code: Int, message: String) -> HTTPResponse {
        .json(200, object: [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message]
        ])
    }

    private func isAuthorized(headers: [String: String]) -> Bool {
        let expected = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else { return false }

        let candidate: String?
        if let auth = headers["authorization"], auth.lowercased().hasPrefix("bearer ") {
            candidate = String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        } else if let veypaneTok = headers["x-veypane-token"] {
            candidate = veypaneTok.trimmingCharacters(in: .whitespaces)
        } else if let sidelarkTok = headers["x-sidelark-token"] {
            candidate = sidelarkTok.trimmingCharacters(in: .whitespaces)
        } else {
            candidate = headers["x-slidecraft-token"]?.trimmingCharacters(in: .whitespaces)
        }

        guard let provided = candidate else { return false }
        let lhs = Array(expected.utf8)
        let rhs = Array(provided.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for index in lhs.indices {
            diff |= (lhs[index] ^ rhs[index])
        }
        return diff == 0
    }

    private func parseJSONBody(_ data: Data) throws -> [String: Any] {
        if data.isEmpty { return [:] }
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AutomationBridgeError.invalidArguments("Expected JSON object body")
        }
        return dict
    }

    // MARK: - Socket I/O Helpers

    private static func readHTTPRequest(from fd: Int32) -> HTTPRequest? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        var headerEndIndex: Int?
        var expectedContentLength = 0

        while buffer.count < maxRequestBytes {
            let bytesRead = Darwin.recv(fd, &chunk, chunk.count, 0)
            if bytesRead <= 0 { break }
            buffer.append(contentsOf: chunk[0..<bytesRead])

            if headerEndIndex == nil, let range = buffer.range(of: separator) {
                headerEndIndex = range.upperBound
                let headerText = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                for line in headerText.components(separatedBy: "\r\n").dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2,
                       parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length",
                       let length = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                        expectedContentLength = max(0, min(length, maxRequestBytes))
                    }
                }
            }

            if let headerEnd = headerEndIndex, buffer.count >= headerEnd + expectedContentLength {
                break
            }
        }

        guard let headerEnd = headerEndIndex,
              let range = buffer.range(of: separator) else {
            return nil
        }

        let headerLines = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else { return nil }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = kv[1].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let bodyEnd = min(buffer.count, headerEnd + expectedContentLength)
        let body = Data(buffer[headerEnd..<bodyEnd])
        return HTTPRequest(
            method: String(requestParts[0]),
            rawTarget: String(requestParts[1]),
            headers: headers,
            body: body
        )
    }

    private static func writeHTTPResponse(_ response: HTTPResponse, to fd: Int32) {
        let header = """
        HTTP/1.1 \(response.statusCode) \(response.statusText)\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(response.body.count)\r
        Connection: close\r
        Cache-Control: no-store\r
        \r

        """
        var packet = Data(header.utf8)
        packet.append(response.body)
        packet.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var totalSent = 0
            while totalSent < packet.count {
                let sent = Darwin.send(fd, base.advanced(by: totalSent), packet.count - totalSent, 0)
                if sent <= 0 { break }
                totalSent += sent
            }
        }
    }
}
