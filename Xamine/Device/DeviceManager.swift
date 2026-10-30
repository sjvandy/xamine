import Foundation
import Observation
import Security

struct IOSDevice: Identifiable, Hashable, Sendable {
    /// CoreDevice identifier, used with `devicectl`.
    let id: String
    /// Hardware UDID, used as the `xcodebuild` destination.
    let udid: String
    let name: String
    let osVersion: String
    let isSimulator: Bool
    /// Wired or network connection to a physical device is up (always true for a booted simulator).
    let isConnected: Bool
    let developerModeEnabled: Bool?

    var summary: String {
        let kind = isSimulator ? "Simulator" : (isConnected ? "Connected" : "Not connected")
        return "iOS \(osVersion) · \(kind)"
    }
}

struct DeviceApp: Identifiable, Hashable, Sendable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let isApple: Bool
}

/// Lists devices, builds and launches the agent on one, and hands back an `AgentClient` once it answers.
@Observable @MainActor
final class DeviceManager {
    enum AgentState: Equatable {
        case idle
        case starting(String)
        case running
        case failed(String)
    }

    private(set) var devices: [IOSDevice] = []
    private(set) var apps: [DeviceApp] = []
    private(set) var state: AgentState = .idle
    private(set) var log: [String] = []
    private(set) var client: AgentClient?
    private(set) var isRefreshing = false
    var selectedDeviceID: String? {
        didSet { if selectedDeviceID != oldValue { apps = [] } }
    }
    var teamID: String = UserDefaults.standard.string(forKey: "agentTeamID") ?? DeviceManager.detectTeamID() ?? "" {
        didSet { UserDefaults.standard.set(teamID, forKey: "agentTeamID") }
    }

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var runningDeviceID: String?

    var selectedDevice: IOSDevice? { devices.first { $0.id == selectedDeviceID } }
    var isAgentRunning: Bool { state == .running && runningDeviceID == selectedDeviceID }

    /// Apple apps worth checking first when detecting the foreground app, ahead of the full installed list.
    static let commonApps = [
        "com.apple.Preferences", "com.apple.mobilesafari", "com.apple.MobileSMS", "com.apple.mobilemail",
        "com.apple.Maps", "com.apple.mobileslideshow", "com.apple.camera", "com.apple.Music", "com.apple.mobilenotes",
        "com.apple.mobilecal", "com.apple.reminders", "com.apple.AppStore", "com.apple.DocumentsApp",
        "com.apple.mobilephone", "com.apple.facetime", "com.apple.weather", "com.apple.mobiletimer", "com.apple.Health",
    ]

    // MARK: - Devices

    func refreshDevices() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let json = try await Self.devicectl(["list", "devices"])
            devices = Self.parseDevices(json)
            if selectedDevice == nil {
                selectedDeviceID = (devices.first { !$0.isSimulator && $0.isConnected } ?? devices.first { !$0.isSimulator } ?? devices.first)?.id
            }
        } catch {
            append("Couldn't list devices: \(error.localizedDescription)")
        }
    }

    func loadApps() async {
        guard let device = selectedDevice else { return }
        do {
            let json = try await Self.devicectl(["device", "info", "apps", "--device", device.id, "--include-default-apps"])
            apps = Self.parseApps(json)
        } catch {
            append("Couldn't list apps: \(error.localizedDescription)")
        }
    }

    /// Bundle IDs to check, in order, when detecting which app is in front.
    var foregroundCandidates: [String] {
        let installed = apps.map(\.bundleID).filter { !$0.contains("xctrunner") && !$0.hasPrefix("com.xamine.agent") }
        var seen = Set<String>()
        return (Self.commonApps + installed).filter { seen.insert($0).inserted }
    }

    func appName(for bundleID: String) -> String {
        if bundleID == "com.apple.springboard" { return "Home Screen" }
        return apps.first { $0.bundleID == bundleID }?.name ?? bundleID
    }

    // MARK: - Agent

    func startAgent() async {
        guard let device = selectedDevice else { return }
        stopAgent()
        log = []
        runningDeviceID = device.id

        if !device.isSimulator {
            guard device.isConnected else {
                state = .failed("\(device.name) isn't connected. Plug it in with a cable and unlock it.")
                return
            }
            guard !teamID.trimmingCharacters(in: .whitespaces).isEmpty else {
                state = .failed("Enter your Apple Development Team ID so Xamine can sign the agent for your device.")
                return
            }
        }

        // An agent left over from a previous session may still be answering.
        if let host = await host(for: device), (try? await AgentClient(host: host).status()) != nil {
            append("Reusing the agent that's already running on \(device.name).")
            client = AgentClient(host: host)
            state = .running
            await loadApps()
            return
        }

        do {
            state = .starting("Preparing the agent project…")
            let project = try Self.prepareAgentProject()
            state = .starting("Building and installing the agent… (the first build takes a minute)")
            try launchXcodebuild(project: project, device: device)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        // Wait for the agent to come up, then connect.
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline, process?.isRunning == true {
            if log.contains(where: { $0.contains("XAMINE_AGENT_READY") }) {
                state = .starting("Connecting to the agent…")
                if let host = await host(for: device), (try? await AgentClient(host: host).status()) != nil {
                    client = AgentClient(host: host)
                    state = .running
                    append("Connected to the agent at \(host).")
                    await loadApps()
                    return
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        if case .starting = state {
            state = .failed(failureSummary())
        }
    }

    func stopAgent() {
        if let client { Task { await client.shutdown() } }
        process?.terminate()
        process = nil
        client = nil
        if state != .idle { state = .idle }
    }

    /// The address the agent can be reached at: localhost for a simulator, the CoreDevice tunnel for a device.
    private func host(for device: IOSDevice) async -> String? {
        if device.isSimulator { return "127.0.0.1" }
        guard let json = try? await Self.devicectl(["device", "info", "details", "--device", device.id]),
              let result = json["result"] as? [String: Any],
              let connection = result["connectionProperties"] as? [String: Any] else { return nil }
        return connection["tunnelIPAddress"] as? String
    }

    private func launchXcodebuild(project: URL, device: IOSDevice) throws {
        var arguments = [
            "test",
            "-project", project.appending(path: "XamineAgent.xcodeproj").path,
            "-scheme", "XamineAgent",
            "-destination", "id=\(device.udid)",
            "-derivedDataPath", Self.supportDirectory.appending(path: "AgentDerivedData").path,
        ]
        if !device.isSimulator {
            let team = teamID.trimmingCharacters(in: .whitespaces)
            arguments += [
                "-allowProvisioningUpdates",
                "DEVELOPMENT_TEAM=\(team)",
                // Bundle IDs must be unique to the signing team.
                "AGENT_BUNDLE_PREFIX=com.xamine.agent.\(team.lowercased())",
            ]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcodebuild"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in self?.appendOutput(text) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.agentExited(status: status) }
        }
        append("$ xcodebuild \(arguments.joined(separator: " "))")
        try process.run()
        self.process = process
    }

    private func agentExited(status: Int32) {
        append("xcodebuild exited with status \(status).")
        process = nil
        switch state {
        case .running:
            client = nil
            state = .failed("The agent stopped. Start it again to keep inspecting.")
        case .starting:
            state = .failed(failureSummary())
        default:
            break
        }
    }

    /// The most useful lines of a failed build or launch.
    private func failureSummary() -> String {
        let hints: [(String, String)] = [
            ("Developer Mode", "Turn on Developer Mode on the device: Settings ▸ Privacy & Security ▸ Developer Mode."),
            ("UI Automation", "Turn on UI Automation on the device: Settings ▸ Developer ▸ Enable UI Automation."),
            ("not been explicitly trusted", "Trust your developer certificate on the device: Settings ▸ General ▸ VPN & Device Management."),
            ("No Account for Team", "Sign in to Xcode with the account for this team (Xcode ▸ Settings ▸ Accounts)."),
            ("No profiles for", "Xcode couldn't create a provisioning profile. Check the Team ID and that you're signed in to Xcode."),
            ("is locked", "Unlock the device and try again."),
            ("Unable to find a destination", "xcodebuild can't see this device. Check it's unlocked, trusted, and that this Xcode supports its iOS version."),
        ]
        let text = log.joined(separator: "\n")
        if let hint = hints.first(where: { text.contains($0.0) }) { return hint.1 }
        let errors = log.filter { $0.localizedCaseInsensitiveContains("error") }.suffix(3)
        return errors.isEmpty ? "The agent didn't start. See the log for details." : errors.joined(separator: "\n")
    }

    // MARK: - Log

    @ObservationIgnored private var partialLine = ""

    private func appendOutput(_ text: String) {
        let lines = (partialLine + text).components(separatedBy: "\n")
        partialLine = lines.last ?? ""
        for line in lines.dropLast() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            append(line)
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 800 { log.removeFirst(log.count - 800) }
    }

    // MARK: - Agent project

    static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "xamine", directoryHint: .isDirectory)
    }

    /// Copies the bundled agent project somewhere writable, so xcodebuild can build it.
    private static func prepareAgentProject() throws -> URL {
        guard let bundled = Bundle.main.url(forResource: "Agent", withExtension: nil) else {
            throw AgentError.agent("The agent project is missing from Xamine's bundle.")
        }
        let destination = supportDirectory.appending(path: "Agent", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.copyItem(at: bundled, to: destination)
        return destination
    }

    // MARK: - devicectl

    private static func devicectl(_ arguments: [String]) async throws -> [String: Any] {
        let output = FileManager.default.temporaryDirectory.appending(path: "xamine-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        try await run("/usr/bin/xcrun", ["devicectl"] + arguments + ["--json-output", output.path, "--quiet"])
        let data = try Data(contentsOf: output)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private static func parseDevices(_ json: [String: Any]) -> [IOSDevice] {
        guard let result = json["result"] as? [String: Any], let list = result["devices"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            let hardware = entry["hardwareProperties"] as? [String: Any] ?? [:]
            let properties = entry["deviceProperties"] as? [String: Any] ?? [:]
            let connection = entry["connectionProperties"] as? [String: Any] ?? [:]
            guard (hardware["platform"] as? String)?.hasPrefix("iOS") == true, let id = entry["identifier"] as? String else { return nil }
            let isSimulator = (hardware["reality"] as? String) == "virtual" || (connection["transportType"] as? String) == "sameMachine"
            let tunnel = connection["tunnelState"] as? String
            return IOSDevice(
                id: id,
                udid: hardware["udid"] as? String ?? id,
                name: properties["name"] as? String ?? "iOS Device",
                osVersion: properties["osVersionNumber"] as? String ?? "?",
                isSimulator: isSimulator,
                isConnected: isSimulator || tunnel == "connected" || (connection["transportType"] as? String) == "wired",
                developerModeEnabled: (properties["developerModeStatus"] as? String).map { $0 == "enabled" }
            )
        }
        .sorted { ($0.isSimulator ? 1 : 0, $0.name) < ($1.isSimulator ? 1 : 0, $1.name) }
    }

    private static func parseApps(_ json: [String: Any]) -> [DeviceApp] {
        guard let result = json["result"] as? [String: Any], let list = result["apps"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let bundleID = entry["bundleIdentifier"] as? String, entry["hidden"] as? Bool != true,
                  entry["appClip"] as? Bool != true, !bundleID.contains("xctrunner") else { return nil }
            return DeviceApp(bundleID: bundleID, name: entry["name"] as? String ?? bundleID, isApple: bundleID.hasPrefix("com.apple."))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Team ID

    /// The team (certificate OU) of the first Apple Development signing certificate in the keychain.
    nonisolated static func detectTeamID() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let certificates = items as? [SecCertificate] else { return nil }
        for certificate in certificates {
            guard let summary = SecCertificateCopySubjectSummary(certificate) as String?,
                  summary.hasPrefix("Apple Development") || summary.hasPrefix("iPhone Developer"),
                  let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1SubjectName] as CFArray, nil) as? [String: Any],
                  let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
                  let fields = subject[kSecPropertyKeyValue as String] as? [[String: Any]] else { continue }
            for field in fields where (field[kSecPropertyKeyLabel as String] as? String) == (kSecOIDOrganizationalUnitName as String) {
                if let team = field[kSecPropertyKeyValue as String] as? String { return team }
            }
        }
        return nil
    }
}
