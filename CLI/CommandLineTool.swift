import Foundation

/// `xamine <tool> [values] [--param value]…`: calls one automation tool and prints its result.
enum CommandLineTool {
    static func run(_ arguments: [String]) -> Int32 {
        guard let name = arguments.first, !["help", "-h", "--help"].contains(name) else {
            printUsage(tool: arguments.dropFirst().first)
            return 0
        }
        guard let tool = Automation.tool(named: name) else {
            FileHandle.standardError.write(Data("Unknown command \(name). Run `xamine help` for the list.\n".utf8))
            return 2
        }

        var params: [String: JSONValue] = [:]
        var json = false
        var output: String?
        var rest = Array(arguments.dropFirst())
        while !rest.isEmpty {
            let argument = rest.removeFirst()
            if argument == "--json" { json = true; continue }
            if argument.hasPrefix("--") {
                let key = String(argument.dropFirst(2)).replacingOccurrences(of: "-", with: "_")
                if key == "output" { output = rest.isEmpty ? nil : rest.removeFirst(); continue }
                let param = tool.params.first { $0.name == key }
                // A boolean flag may be given without a value.
                if param?.kind == .boolean, rest.first.map({ $0.hasPrefix("--") || !["true", "false", "yes", "no"].contains($0) }) ?? true {
                    params[key] = true
                    continue
                }
                guard !rest.isEmpty else { return fail("--\(key) needs a value") }
                params[key] = value(rest.removeFirst(), kind: param?.kind ?? .string)
                continue
            }
            guard let key = positionalKey(for: argument, tool: tool, filled: params) else { return fail("Unexpected argument \(argument)") }
            params[key] = value(argument, kind: tool.params.first { $0.name == key }?.kind ?? .string)
        }

        let client = SocketClient()
        let result: JSONValue
        do {
            result = try client.call(tool.name, params: params)
        } catch {
            return fail("\(error.message) [\(error.code)]")
        }

        var printable = result
        if case .object(var object) = result, let png = object["png"]?.string, let data = Data(base64Encoded: png) {
            let path = output ?? NSTemporaryDirectory() + "xamine-\(Int(Date().timeIntervalSince1970 * 1000)).png"
            do {
                try data.write(to: URL(fileURLWithPath: path))
            } catch {
                return fail("Couldn't write \(path): \(error.localizedDescription)")
            }
            object["png"] = nil
            object["path"] = .string(path)
            object["text"] = .string([object["text"]?.string, "Saved screenshot to \(path)"].compactMap { $0 }.joined(separator: "\n"))
            printable = .object(object)
        }

        if json {
            print(String(decoding: printable.encoded(pretty: true), as: UTF8.self))
        } else if let text = printable["text"]?.string {
            print(text)
        } else {
            print(String(decoding: printable.encoded(pretty: true), as: UTF8.self))
        }
        return 0
    }

    /// Which parameter a bare value fills: refs go to `element`, `app…` expressions to `query`, anything else to the
    /// first required parameter still empty, then `app`.
    private static func positionalKey(for argument: String, tool: Automation.Tool, filled: [String: JSONValue]) -> String? {
        let names = Set(tool.params.map(\.name))
        if names.contains("element"), filled["element"] == nil, argument.range(of: #"^e\d+$"#, options: .regularExpression) != nil { return "element" }
        if names.contains("query"), filled["query"] == nil, argument.hasPrefix("app") && argument.count > 3 { return "query" }
        if let required = tool.params.first(where: { $0.required && filled[$0.name] == nil }) { return required.name }
        if names.contains("app"), filled["app"] == nil { return "app" }
        return nil
    }

    private static func value(_ string: String, kind: Automation.Param.Kind) -> JSONValue {
        switch kind {
        case .string: .string(string)
        case .integer, .number: Double(string).map(JSONValue.number) ?? .string(string)
        case .boolean: .bool(["true", "yes", "1"].contains(string.lowercased()))
        }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("xamine: \(message)\n".utf8))
        return 1
    }

    private static func printUsage(tool name: String?) {
        if let name, let tool = Automation.tool(named: name) {
            print("xamine \(tool.cliName) — \(tool.description)\n")
            for param in tool.params {
                print("  --\(param.name.replacingOccurrences(of: "_", with: "-"))\(param.required ? " (required)" : "")  \(param.description)")
            }
            return
        }
        print("""
        Drives Xamine from scripts and AI agents. Xamine.app must have Accessibility and Screen Recording permission.

        Usage:
          xamine <command> [value…] [--param value…] [--json] [--output file.png]
          xamine mcp                 Run as an MCP server over stdio
          xamine help <command>      Show a command's parameters

        Bare values fill the obvious parameter: e12 → --element, app.buttons["OK"] → --query, otherwise the first
        required parameter, then --app.

        Commands:
        """)
        for tool in Automation.tools {
            print("  \(tool.cliName.padding(toLength: 16, withPad: " ", startingAt: 0))\(tool.description.prefix(while: { $0 != "." }))")
        }
        print("""

        Examples:
          xamine launch-app com.apple.tips
          xamine find-elements --text "User Guide"
          xamine click e42
          xamine type-text e7 "reminders" && xamine press-key return
          xamine resolve-query 'app.windows["Shopping Cart"]'
        """)
    }
}
