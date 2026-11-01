import Foundation

// `xamine mcp` serves the Model Context Protocol over stdio; anything else is a one-shot command.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "mcp" {
    exit(MCPServer.run())
} else {
    exit(CommandLineTool.run(arguments))
}
