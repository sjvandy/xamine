import Foundation

struct AutomationError: Error {
    let code: String
    let message: String
}

/// A blocking connection to the automation socket of the running Xamine app.
final class SocketClient {
    private var fd: Int32 = -1
    private var buffer = Data()
    private var nextID = 1

    deinit { disconnect() }

    /// Sends one request and waits for its reply. Starts Xamine (in the background) if it isn't running.
    func call(_ method: String, params: [String: JSONValue] = [:]) throws(AutomationError) -> JSONValue {
        if fd < 0 { try connectLaunchingIfNeeded() }
        do {
            return try exchange(method, params: params)
        } catch let error where error.code == "disconnected" {
            // Xamine may have restarted since the last call; reconnect once.
            disconnect()
            try connectLaunchingIfNeeded()
            return try exchange(method, params: params)
        }
    }

    private func exchange(_ method: String, params: [String: JSONValue]) throws(AutomationError) -> JSONValue {
        let id = nextID
        nextID += 1
        let request: JSONValue = ["id": .number(Double(id)), "method": .string(method), "params": .object(params)]
        try send(request.encoded() + Data("\n".utf8))
        while true {
            let line = try readLine()
            guard let reply = try? JSONValue.decode(line), reply["id"]?.int == id else { continue }
            if let error = reply["error"] {
                throw AutomationError(code: error["code"]?.string ?? "error", message: error["message"]?.string ?? "Unknown error")
            }
            return reply["result"] ?? .null
        }
    }

    // MARK: - Connection

    private func connectLaunchingIfNeeded() throws(AutomationError) {
        if connect() { return }
        launchXamine()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            if connect() { return }
        }
        throw AutomationError(code: "notRunning", message: "Couldn't reach Xamine at \(Automation.socketPath). Open Xamine.app and try again.")
    }

    private func connect() -> Bool {
        let path = Automation.socketPath
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, path, capacity - 1) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            close(socketFD)
            return false
        }
        var noSigPipe: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        fd = socketFD
        buffer = Data()
        return true
    }

    private func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    /// Opens the Xamine.app this helper is inside of (Xamine.app/Contents/Helpers/xamine), or the installed one.
    private func launchXamine() {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = bundle.pathExtension == "app" ? ["-g", "-a", bundle.path] : ["-g", "-b", Automation.appBundleID]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - I/O

    private func send(_ data: Data) throws(AutomationError) {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { write(fd, $0.baseAddress! + offset, data.count - offset) }
            guard written > 0 else { throw AutomationError(code: "disconnected", message: "Lost the connection to Xamine.") }
            offset += written
        }
    }

    private func readLine() throws(AutomationError) -> Data {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[(newline + 1)...])
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { throw AutomationError(code: "disconnected", message: "Lost the connection to Xamine.") }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
