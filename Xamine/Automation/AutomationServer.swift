import Foundation
import Network

/// Serves the automation API over a Unix socket (see `Automation`), for the `xamine` CLI and MCP server.
@MainActor
final class AutomationServer {
    private let service: AutomationService
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var lingerTask: Task<Void, Never>?
    /// Called with `true` while an agent is connected (plus a few seconds after), for the menu bar's AI pill.
    var onActivityChange: ((Bool) -> Void)?

    init(service: AutomationService) {
        self.service = service
    }

    func start() {
        let path = Automation.socketPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path) // a socket left behind by an earlier run

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    chmod(path, 0o600)
                    Log.automation.notice("automation socket ready at \(path, privacy: .public)")
                case .failed(let error):
                    Log.automation.error("automation socket failed: \(error.localizedDescription, privacy: .public)")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] nwConnection in
                Task { @MainActor in self?.accept(nwConnection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            Log.automation.error("couldn't create automation socket: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = Connection(nwConnection) { [weak self] request, reply in
            guard let self else { return }
            Task { @MainActor in reply(await self.respond(to: request)) }
        } onClose: { [weak self] connection in
            Task { @MainActor in self?.closed(connection) }
        }
        connections[ObjectIdentifier(connection)] = connection
        lingerTask?.cancel()
        onActivityChange?(true)
        connection.start()
    }

    private func closed(_ connection: Connection) {
        connections[ObjectIdentifier(connection)] = nil
        guard connections.isEmpty else { return }
        // CLI commands connect once per call, so stay "active" briefly between them.
        lingerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, connections.isEmpty else { return }
            onActivityChange?(false)
        }
    }

    private func respond(to request: JSONValue) async -> JSONValue {
        let id = request["id"] ?? .null
        guard let method = request["method"]?.string else {
            return ["id": id, "error": ["code": "invalidRequest", "message": "Missing method."]]
        }
        do {
            let result = try await service.handle(method, params: request["params"]?.object ?? [:])
            return ["id": id, "result": result]
        } catch let failure as AutomationService.Failure {
            Log.automation.notice("\(method, privacy: .public) failed: \(failure.message, privacy: .public)")
            return ["id": id, "error": ["code": .string(failure.code), "message": .string(failure.message)]]
        } catch {
            return ["id": id, "error": ["code": "internal", "message": .string(error.localizedDescription)]]
        }
    }
}

/// One client: reads newline-delimited JSON requests and writes replies. Confined to the main queue.
private final class Connection: @unchecked Sendable {
    private let connection: NWConnection
    private let onRequest: @Sendable (JSONValue, @escaping @Sendable (JSONValue) -> Void) -> Void
    private let onClose: @Sendable (Connection) -> Void
    private var buffer = Data()
    private var isClosed = false

    init(_ connection: NWConnection,
         onRequest: @escaping @Sendable (JSONValue, @escaping @Sendable (JSONValue) -> Void) -> Void,
         onClose: @escaping @Sendable (Connection) -> Void) {
        self.connection = connection
        self.onRequest = onRequest
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: .main)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { buffer.append(data) }
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[(newline + 1)...])
                guard !line.isEmpty else { continue }
                guard let request = try? JSONValue.decode(line) else {
                    send(["id": .null, "error": ["code": "invalidRequest", "message": "Couldn't parse the request as JSON."]])
                    continue
                }
                onRequest(request) { [weak self] reply in
                    DispatchQueue.main.async { self?.send(reply) }
                }
            }
            if isComplete || error != nil {
                close()
            } else {
                receive()
            }
        }
    }

    private func send(_ reply: JSONValue) {
        guard !isClosed else { return }
        connection.send(content: reply.encoded() + Data("\n".utf8), completion: .contentProcessed { _ in })
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onClose(self)
    }
}
