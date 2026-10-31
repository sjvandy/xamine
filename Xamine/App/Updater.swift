import AppKit
import Security

@Observable @MainActor
final class Updater {
    static let shared = Updater()
    nonisolated static let repository = "sjvandy/xamine"
    nonisolated static let teamIdentifier = "2R8MRUP265"

    private(set) var isChecking = false

    struct Release: Decodable, Sendable {
        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        struct Asset: Decodable, Sendable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }

        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
        var dmg: Asset? { assets.first { $0.name.hasSuffix(".dmg") } }
    }

    enum UpdateError: LocalizedError {
        case badResponse(Int)
        case noApp
        case invalidSignature
        case notWritable(String)
        case command(String, Int32)

        var errorDescription: String? {
            switch self {
            case .badResponse(let status): "GitHub answered with status \(status)."
            case .noApp: "The downloaded disk image doesn't contain Xamine."
            case .invalidSignature: "The downloaded Xamine isn't signed by the expected team, so it wasn't installed."
            case .notWritable(let path): "Xamine can't replace itself in \(path)."
            case .command(let name, let status): "\(name) failed with status \(status)."
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                let release = try await Self.fetchLatest()
                guard Self.isNewer(release.version, than: Self.currentVersion), let dmg = release.dmg else {
                    alert("You're up to date", "Xamine \(Self.currentVersion) is the latest version.")
                    return
                }
                guard confirm(release) else { return }
                try await install(from: dmg.browserDownloadURL)
            } catch {
                alert("Couldn't update Xamine", error.localizedDescription)
            }
        }
    }

    private nonisolated static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.badResponse(status) }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    private func install(from url: URL) async throws {
        let destination = Bundle.main.bundleURL
        let parent = destination.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else { throw UpdateError.notWritable(parent) }

        let staged = try await Self.download(url)
        try Self.verify(staged.app)

        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        if mv "$3" "$4"; then
          if ditto "$2" "$3"; then xattr -dr com.apple.quarantine "$3"; else rm -rf "$3"; mv "$4" "$3"; fi
        fi
        open "$3"
        """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = [
            "-c", script, "xamine-update",
            String(ProcessInfo.processInfo.processIdentifier),
            staged.app.path,
            destination.path,
            staged.folder.appending(path: "Previous.app").path,
        ]
        swap.standardOutput = FileHandle.nullDevice
        swap.standardError = FileHandle.nullDevice
        try swap.run()
        NSApp.terminate(nil)
    }

    private nonisolated static func download(_ url: URL) async throws -> (folder: URL, app: URL) {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appending(path: "XamineUpdate-\(UUID().uuidString)")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let (downloaded, response) = try await URLSession.shared.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.badResponse(status) }
        let dmg = folder.appending(path: "Xamine.dmg")
        try fileManager.moveItem(at: downloaded, to: dmg)

        let mount = folder.appending(path: "mnt")
        try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path])
        let app = folder.appending(path: "Xamine.app")
        do {
            guard let source = try fileManager.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.noApp }
            try await run("/usr/bin/ditto", [source.path, app.path])
        } catch {
            try? await run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
            throw error
        }
        try await run("/usr/bin/hdiutil", ["detach", mount.path])
        return (folder, app)
    }

    private nonisolated static func verify(_ app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.invalidSignature
        }
        var requirement: SecRequirement?
        var text = "identifier \"com.xamine.Xamine\""
        if runningTeamIdentifier() != nil {
            text = "anchor apple generic and \(text) and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        }
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckNestedCode), requirement) == errSecSuccess
        else { throw UpdateError.invalidSignature }
    }

    private nonisolated static func runningTeamIdentifier() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private nonisolated static func run(_ executable: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError.command(URL(fileURLWithPath: executable).lastPathComponent, process.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func confirm(_ release: Release) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Xamine \(release.version) is available"
        alert.informativeText = "You have \(Self.currentVersion). Xamine will quit, install the new version and reopen."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release Notes")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(release.htmlURL)
            return false
        default:
            return false
        }
    }

    private func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
