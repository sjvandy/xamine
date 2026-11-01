import Foundation

/// A Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0) that relays tool calls to Xamine.
enum MCPServer {
    static let instructions = """
    Xamine inspects and drives macOS apps through the Accessibility API and turns what you do into XCUITest code.
    Typical flow: launch_app → snapshot (or find_elements) to get element refs like e12 → click / type_text / press_key \
    → snapshot again after the UI changes. Each action returns the equivalent XCUITest line. To build a test, call \
    recording_start first and recording_stop at the end to get a complete XCTestCase file. When a UI test can't find \
    an element, pass its query to resolve_query to see what the live UI has instead.
    """

    static func run() -> Int32 {
        let client = SocketClient()
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let message = try? JSONValue.decode(Data(line.utf8)) else { continue }
            guard let id = message["id"], let method = message["method"]?.string else { continue } // notifications
            let reply: JSONValue
            do {
                reply = ["jsonrpc": "2.0", "id": id, "result": try handle(method, params: message["params"], client: client)]
            } catch {
                reply = ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(error.code)), "message": .string(error.message)]]
            }
            FileHandle.standardOutput.write(reply.encoded() + Data("\n".utf8))
        }
        return 0
    }

    private struct RPCError: Error {
        let code: Int
        let message: String
    }

    private static func handle(_ method: String, params: JSONValue?, client: SocketClient) throws(RPCError) -> JSONValue {
        switch method {
        case "initialize":
            return [
                "protocolVersion": .string(params?["protocolVersion"]?.string ?? "2025-06-18"),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "xamine", "version": "1.0"],
                "instructions": .string(instructions),
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": .array(Automation.tools.map(schema))]
        case "tools/call":
            guard let name = params?["name"]?.string, Automation.tool(named: name) != nil else {
                throw RPCError(code: -32602, message: "Unknown tool \(params?["name"]?.string ?? "")")
            }
            return call(name, arguments: params?["arguments"]?.object ?? [:], client: client)
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    /// Tool failures are returned as results with `isError`, so the agent sees the message and can recover.
    private static func call(_ name: String, arguments: [String: JSONValue], client: SocketClient) -> JSONValue {
        let result: JSONValue
        do {
            result = try client.call(name, params: arguments)
        } catch {
            return ["content": [["type": "text", "text": .string("Error [\(error.code)]: \(error.message)")]], "isError": true]
        }
        var content: [JSONValue] = []
        var rest = result.object ?? [:]
        let text = rest.removeValue(forKey: "text")?.string
        let png = rest.removeValue(forKey: "png")?.string
        if let text { content.append(["type": "text", "text": .string(text)]) }
        if !rest.isEmpty, text == nil {
            content.append(["type": "text", "text": .string(String(decoding: JSONValue.object(rest).encoded(pretty: true), as: UTF8.self))])
        }
        if let png { content.append(["type": "image", "data": .string(png), "mimeType": "image/png"]) }
        if content.isEmpty { content.append(["type": "text", "text": "OK"]) }
        return ["content": .array(content), "isError": false]
    }

    private static func schema(_ tool: Automation.Tool) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for param in tool.params {
            properties[param.name] = ["type": .string(param.kind.rawValue), "description": .string(param.description)]
        }
        return [
            "name": .string(tool.name),
            "description": .string(tool.description),
            "inputSchema": [
                "type": "object",
                "properties": .object(properties),
                "required": .array(tool.params.filter(\.required).map { .string($0.name) }),
            ],
        ]
    }
}
