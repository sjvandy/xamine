import Foundation
import ImageIO

/// Talks to the Xamine agent running on an iOS device or simulator (see `Agent/UITests/XamineAgentTests.swift`).
struct AgentClient: Sendable {
    static let port = 8765

    let baseURL: URL

    /// `host` is an IPv4/IPv6 address or hostname; IPv6 addresses are bracketed automatically.
    init(host: String) {
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        baseURL = URL(string: "http://\(bracketed):\(Self.port)")!
    }

    struct Status: Decodable, Sendable {
        let ok: Bool
        let device: String
        let system: String
    }

    func status() async throws -> Status {
        try await get("status", timeout: 3)
    }

    /// The bundle ID of the first candidate running in the foreground, or SpringBoard.
    func foregroundApp(candidates: [String]) async throws -> String {
        struct Reply: Decodable { let bundleId: String }
        let reply: Reply = try await get("foreground", query: ["candidates": candidates.joined(separator: ",")], timeout: 30)
        return reply.bundleId
    }

    func tree(bundleID: String) async throws -> AgentNode {
        struct Reply: Decodable {
            let root: AgentNode?
            let error: String?
        }
        let reply: Reply = try await get("tree", query: ["bundleId": bundleID], timeout: 60)
        guard let root = reply.root else { throw AgentError.agent(reply.error ?? "The agent returned no tree.") }
        return root
    }

    func screenshot() async throws -> CGImage {
        let data = try await data("screenshot", timeout: 20)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AgentError.agent("The screenshot couldn't be decoded.") }
        return image
    }

    func shutdown() async {
        _ = try? await data("shutdown", timeout: 3)
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], timeout: TimeInterval) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await data(path, query: query, timeout: timeout))
    }

    private func data(_ path: String, query: [String: String] = [:], timeout: TimeInterval) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            struct Failure: Decodable { let error: String }
            throw AgentError.agent((try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "HTTP \(http.statusCode)")
        }
        return data
    }
}

/// An inspector session against an agent.
struct DeviceInspection: Sendable {
    let client: AgentClient
    let deviceName: String
    /// The app to inspect, or `nil` to follow whichever app is in the foreground on each scan.
    let bundleID: String?
    /// Bundle IDs checked, in order, when following the foreground app.
    let candidates: [String]
    let appNames: [String: String]
}

enum AgentError: LocalizedError {
    case agent(String)

    var errorDescription: String? {
        switch self {
        case .agent(let message): message
        }
    }
}

/// One element of an XCUITest snapshot, as sent by the agent.
struct AgentNode: Decodable, Sendable {
    let type: String
    let frame: [Double]
    let enabled: Bool?
    let identifier: String?
    let label: String?
    let title: String?
    let value: String?
    let placeholder: String?
    let children: [AgentNode]

    /// Flattens the snapshot into a `UITree`. Element types come straight from XCUITest, so queries map 1:1.
    func makeTree(appName: String, bundleID: String) -> UITree {
        var nodes: [UINode] = []
        func visit(_ node: AgentNode, parentID: Int?, depth: Int) {
            let id = nodes.count
            let frame = node.frame.count == 4 ? CGRect(x: node.frame[0], y: node.frame[1], width: node.frame[2], height: node.frame[3]) : nil
            nodes.append(UINode(
                id: id,
                parentID: parentID,
                depth: depth,
                kind: .forTypeName(node.type),
                role: node.type,
                identifier: node.identifier,
                title: node.title,
                label: node.label,
                value: node.value,
                placeholder: node.placeholder,
                frame: frame,
                isEnabled: node.enabled
            ))
            if let parentID { nodes[parentID].childIDs.append(id) }
            for child in node.children { visit(child, parentID: id, depth: depth + 1) }
        }
        visit(self, parentID: nil, depth: 0)
        let screen = nodes.first?.frame ?? .zero
        return UITree(nodes: nodes, appName: appName, bundleID: bundleID, platform: .iOSDevice, windowFrame: screen)
    }
}
