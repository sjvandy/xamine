import AppKit

/// Connects Claude agents on this Mac to Xamine: registers the `xamine mcp` server with each agent's configuration and
/// installs a skill that tells the agent when and how to use it.
enum AgentIntegration {
    /// One Claude configuration: Claude Code's default (`~/.claude`) or another `CLAUDE_CONFIG_DIR`, such as Xcode's.
    struct Target: Sendable {
        let name: String
        /// `nil` for the default configuration.
        let configDirectory: URL?

        var skillsDirectory: URL {
            (configDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")).appending(path: "skills")
        }

        /// Where `claude mcp add --scope user` records servers.
        var settingsFile: URL {
            configDirectory?.appending(path: ".claude.json") ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
        }

        var skillFile: URL { skillsDirectory.appending(path: "xamine/SKILL.md") }
    }

    struct Outcome: Sendable {
        let target: Target
        let error: String?
    }

    static let serverName = "xamine"

    /// Claude Code, plus Xcode's coding assistant if it has been used on this Mac.
    static var targets: [Target] {
        var targets = [Target(name: "Claude Code", configDirectory: nil)]
        let xcode = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig")
        if FileManager.default.fileExists(atPath: xcode.path) {
            targets.append(Target(name: "Claude in Xcode", configDirectory: xcode))
        }
        return targets
    }

    static var helperPath: String { Bundle.main.bundleURL.appending(path: "Contents/Helpers/xamine").path }

    /// Whether the target has the skill and an `xamine` server pointing at this copy of Xamine.
    static func isConfigured(_ target: Target) -> Bool {
        guard FileManager.default.fileExists(atPath: target.skillFile.path),
              let data = try? Data(contentsOf: target.settingsFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any],
              let server = servers[serverName] as? [String: Any] else { return false }
        return server["command"] as? String == helperPath
    }

    // MARK: - Setup

    /// Sets up every target and reports what happened in an alert.
    @MainActor
    static func setUpAll() async {
        let claude = findClaude()
        var outcomes: [Outcome] = []
        for target in targets {
            outcomes.append(await setUp(target, claude: claude))
        }
        showResult(outcomes, claudeFound: claude != nil)
    }

    static func setUp(_ target: Target, claude: URL?) async -> Outcome {
        do {
            try FileManager.default.createDirectory(at: target.skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try skill.write(to: target.skillFile, atomically: true, encoding: .utf8)
        } catch {
            return Outcome(target: target, error: "Couldn't write the skill: \(error.localizedDescription)")
        }
        guard let claude else {
            return Outcome(target: target, error: "The claude command wasn't found, so the MCP server wasn't registered.")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        if let directory = target.configDirectory { environment["CLAUDE_CONFIG_DIR"] = directory.path }
        // Remove first so a moved or rebuilt Xamine gets its current path; it's fine if there was nothing to remove.
        _ = await run(claude, ["mcp", "remove", "--scope", "user", serverName], environment: environment)
        let result = await run(claude, ["mcp", "add", "--scope", "user", serverName, "--", helperPath, "mcp"], environment: environment)
        guard result.status == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return Outcome(target: target, error: "claude mcp add failed\(message.isEmpty ? "" : ": \(message)")")
        }
        return Outcome(target: target, error: nil)
    }

    // MARK: - Claude CLI

    private static var searchPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
    }

    /// The `claude` executable. Apps launched from Finder don't get the shell's PATH, so look in the usual install folders.
    static func findClaude() -> URL? {
        searchPath.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "claude") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func run(_ executable: URL, _ arguments: [String], environment: [String: String]) async -> (status: Int32, output: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return (-1, error.localizedDescription)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }

    // MARK: - Result

    @MainActor
    private static func showResult(_ outcomes: [Outcome], claudeFound: Bool) {
        let alert = NSAlert()
        let failures = outcomes.filter { $0.error != nil }
        if failures.isEmpty {
            alert.messageText = "AI agents are set up"
            alert.informativeText = """
            Added the Xamine MCP server and the “xamine” skill to \(outcomes.map(\.target.name).formatted(.list(type: .and))).

            Start a new conversation for the agent to pick them up, then ask it to automate or test a Mac app.

            The server runs \(helperPath). If you move Xamine, choose Set Up AI Agents again.
            """
        } else {
            alert.alertStyle = .warning
            alert.messageText = failures.count == outcomes.count ? "Couldn't set up AI agents" : "Some AI agents weren't set up"
            var lines = outcomes.map { "\($0.target.name): \($0.error ?? "set up")" }
            if !claudeFound {
                lines.append("\nInstall Claude Code (claude.com/claude-code), or run this yourself — it's been copied to the clipboard:\nclaude mcp add --scope user \(serverName) -- \(helperPath) mcp")
                Clipboard.copy("claude mcp add --scope user \(serverName) -- \(helperPath.replacingOccurrences(of: " ", with: "\\ ")) mcp")
            }
            alert.informativeText = lines.joined(separator: "\n")
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Skill

    /// Installed as `skills/xamine/SKILL.md` in each agent's configuration.
    static let skill = #"""
    ---
    name: xamine
    description: Inspect and drive macOS, iOS and iPadOS apps (on a Mac, a connected iPhone or iPad, or a Simulator) through Xamine to write, record, or repair XCUITest UI tests. Use when the user wants a UI automation or XCUITest for an Apple-platform app, wants to reproduce or verify steps in an app's UI, needs accessibility identifiers or element queries, or has a UI test that fails because an element can't be found or a title or label changed.
    ---

    # Xamine: UI automation for Apple platforms

    Xamine reads an app's UI hierarchy, operates it (clicks or taps, typing, keys), and turns what you do into XCUITest code. It works with Mac apps directly, and with apps on a connected iPhone or iPad or a Simulator through a small XCUITest agent it runs there. Use its MCP tools (`mcp__xamine__*`). If they aren't available, run the same commands with the CLI shown by `status` (`xamine <command> --help`).

    ## When to use it
    - "Create a UI test / XCUI automation that does X in <app>": explore, record, save the generated test, run it.
    - "This UI test fails, find out why": reproduce the steps live and use `resolve_query` on the failing query.
    - Finding the right XCUITest query or accessibility identifier for an element.
    - Checking what a Mac app's UI currently shows (`snapshot`, `screenshot`).

    ## iPhone, iPad and Simulator
    - Call `list_devices` first, then pass `device` (the name or UDID it shows) on **every** call for that device. Without `device`, calls go to the Mac.
    - The first device call builds and starts Xamine's agent there, which takes a minute or two the first time. A physical device must be unlocked, trusted, with Developer Mode and UI Automation (Settings › Developer) on.
    - `launch_app` takes a bundle ID or the app's name (`list_apps` with `device` lists installed apps). Pass `relaunch: true` for a fresh start.
    - Actions run as real XCUITest calls on the device: `click` taps, `scroll` swipes (scrolling down swipes up), `press_key` handles `home`, `return`, `delete` and characters. `resolve_query` counts matches with XCUITest itself.
    - Recordings produce iOS code (`.tap()`, a tap before `typeText`, `swipeUp()`, `XCUIDevice.shared.press(.home)`). If tapping a switch's row doesn't toggle it, Xamine taps the switch inside and records `….switches.firstMatch.tap()`; keep that.
    - Spotlight (swipe down on the Home Screen) is its own app, `com.apple.campo`; pass `app: "com.apple.campo"` to read its results and keyboard. SpringBoard's tree doesn't contain them, only the Home Screen beneath.
    - Lists load lazily: rows below the fold aren't in a snapshot until you `scroll`. If `find_elements` finds nothing, scroll and look again.
    - iPhone and iPad layouts differ. On iPad (iOS 18+) tabs sit in a floating bar at the top that isn't a `tabBar`, so `app.tabBars.buttons["Cart"]` fails there; `app.buttons["Cart"].firstMatch` works on both. Check tests on each device family they must run on.
    - Snapshots show `[selected]` for the chosen segment or tab, and screenshots are in pixels (2× or 3× the snapshot's points).
    - You can run `xcodebuild test` on the device while Xamine's agent is running. If a test run can't start the app or hangs at launch, call `release_device` first; the next call with `device` starts the agent again.

    ## Ground rules
    - Xamine moves the real mouse and keyboard. Tell the user not to touch them while you drive, and never drive the UI while `xcodebuild test` is running.
    - Element refs (`e12`) belong to the latest `snapshot` or `find_elements` of that app. After anything changes the UI (navigation, alerts), take a new snapshot before using refs, or pass `query` (an XCUITest query) instead.
    - Don't guess identifiers: get them from `snapshot`, `find_elements` or `get_queries`. Prefer the query Xamine suggests; it has been checked against the live tree.
    - If `status` reports a missing permission, ask the user to grant it to Xamine in System Settings › Privacy & Security.

    ## Creating a UI test
    1. `launch_app` with the bundle ID, name, or a path to the .app. Check the `App:` path in its output: when several builds are installed it opens the newest, and lists the others. Pass a path if it picked the wrong one.
    2. Explore: `snapshot` with `interactive_only: true` for an overview, `find_elements` with `text` or `kind` to locate things, and `screenshot` when the layout matters.
    3. Get the app back to the starting screen the test will begin from (the test relaunches the app, so state such as a cart starts empty).
    4. `recording_start` with a test name, then perform the flow with `click`, `type_text`, `press_key`. After each step, snapshot again before using refs.
    5. Add assertions with `wait_for` (a query, or `text`). It records `XCTAssertTrue(….waitForExistence(timeout:))`.
    6. `recording_stop` returns the complete XCTestCase file **once**. Save it right away into the project's UI-test target folder (e.g. `<Project>/UITests/NameTests.swift`).
    7. Run it, e.g. `xcodebuild test -project P.xcodeproj -scheme S -destination 'platform=macOS' -only-testing:<UITestTarget>/<NameTests>`. If it fails, use `resolve_query` on the failing line's query, fix, rerun.

    ## Investigating a failing UI test
    1. Run the test and read the failing line and its query.
    2. Reproduce the test's steps up to that line with Xamine (`launch_app`, `click` the same queries).
    3. `resolve_query` with the failing query. It shows each step's match count, the step that stops matching, what that step could choose from in the live UI (often the same element with new text), similar text elsewhere, and a text-free alternative.
    4. Fix the test: update the expected text, or make it independent of copy (by identifier or position), but keep it able to fail. For example, a "title isn't empty" check passes even if navigation didn't happen; prefer asserting something unique to the destination screen.
    5. Rerun the test until it passes.

    ## Tools
    | Tool | Use |
    |---|---|
    | `status` | Permissions, frontmost app, CLI path |
    | `list_apps` | Running apps and window titles |
    | `launch_app` | Launch/activate by bundle ID, name or .app path |
    | `snapshot` | Outline of the front window with refs |
    | `find_elements` | Search by text/kind/identifier, with best query |
    | `screenshot` | PNG of the window or one element |
    | `get_queries` | All query variants for an element |
    | `click` / `type_text` / `press_key` / `scroll` | Act; each returns the XCUITest line |
    | `wait_for` | Wait for a query/text (or `gone`); records an assertion |
    | `resolve_query` | Why a query does or doesn't match the live UI |
    | `recording_start` / `recording_stop` | Turn actions into an XCTestCase file |

    ## Running UI tests the first time
    macOS asks to enable Automation Mode for UI tests. If `xcodebuild test` fails with "Timed out while enabling automation mode", ask the user to run `sudo automationmodetool enable-automationmode-without-authentication` or approve the prompt by running the tests once in Xcode.
    """#
}
