import Foundation

/// Collects the steps an agent performs and writes them out as an XCTestCase.
struct TestComposer: Sendable {
    enum Action: Sendable, Equatable {
        case click
        case typeText(String)
        /// An `XCUIKeyboardKey` member (e.g. `.return`) or a character literal, plus modifier flags.
        case typeKey(key: String, modifiers: [String])
        case assertExists(timeout: Double)
        case assertGone(timeout: Double)
    }

    struct Step: Sendable, Equatable {
        /// The element's XCUITest query, without `app` declaration; `nil` for keys sent to the app.
        var query: String?
        var action: Action
    }

    var name: String
    var bundleID: String
    var steps: [Step] = []

    init(name: String, bundleID: String) {
        self.name = Self.typeName(from: name)
        self.bundleID = bundleID
    }

    /// The single line of XCUITest code for one step, as returned to the agent after each action.
    static func line(for step: Step) -> String {
        let target = (step.query ?? "app").replacingOccurrences(of: "\n    ", with: "")
        switch step.action {
        case .click: return "\(target).click()"
        case .typeText(let text): return "\(target).typeText(\(QueryBuilder.literal(text)))"
        case .typeKey(let key, let modifiers): return "\(target).typeKey(\(key), modifierFlags: \(modifierFlags(modifiers)))"
        case .assertExists(let timeout): return "XCTAssertTrue(\(target).waitForExistence(timeout: \(format(timeout))))"
        case .assertGone(let timeout):
            return "XCTAssertTrue(\(target).waitForNonExistence(timeout: \(format(timeout))))"
        }
    }

    /// The whole test file. Elements that are clicked or typed into are named and waited for first, so the test
    /// tolerates the animations and navigation between steps.
    func source() -> String {
        var body: [String] = [
            "let app = XCUIApplication(bundleIdentifier: \(QueryBuilder.literal(bundleID)))",
            "app.launch()",
        ]
        var names: [String: String] = [:] // query → variable
        var used = Set(["app"])

        for step in steps {
            guard let query = step.query else {
                body.append(Self.line(for: step))
                continue
            }
            switch step.action {
            case .click, .typeText:
                let variable: String
                if let existing = names[query] {
                    variable = existing
                } else {
                    variable = Self.uniqueName(Self.variableName(for: query), used: &used)
                    names[query] = variable
                    body.append("")
                    body.append("let \(variable) = \(query)")
                }
                body.append("XCTAssertTrue(\(variable).waitForExistence(timeout: 5))")
                body.append(Self.line(for: Step(query: variable, action: step.action)))
            case .typeKey, .assertExists, .assertGone:
                body.append(Self.line(for: Step(query: names[query] ?? query, action: step.action)))
            }
        }

        let indented = body.map { $0.isEmpty ? "" : "        " + $0.replacingOccurrences(of: "\n", with: "\n        ") }
        return """
        import XCTest

        /// Recorded with Xamine.
        final class \(name)Tests: XCTestCase {
            override func setUpWithError() throws {
                continueAfterFailure = false
            }

            @MainActor
            func test\(name)() throws {
        \(indented.joined(separator: "\n"))
            }
        }

        """
    }

    // MARK: - Naming

    /// `OrderColdBrew` from "order cold brew", "order-cold-brew" or "OrderColdBrewTests".
    static func typeName(from name: String) -> String {
        var words = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.count == 1, let only = words.first { words = [only.first!.uppercased() + only.dropFirst()] }
        var result = words.map { $0.first!.uppercased() + $0.dropFirst() }.joined()
        for suffix in ["Tests", "Test"] where result.hasSuffix(suffix) && result.count > suffix.count {
            result.removeLast(suffix.count)
            break
        }
        if result.isEmpty { return "Recorded" }
        return result.first!.isNumber ? "Test" + result : result
    }

    /// A variable name from the query's key and element type, e.g. `app.buttons["add-to-cart-button"]` → `addToCartButton`.
    static func variableName(for query: String) -> String {
        let steps = (try? QueryResolver.parse(query)) ?? []
        let key = steps.compactMap(\.operation.key).last
        let type = steps.reversed().compactMap { step -> String? in
            if case .descendants(let type?) = step.operation { return type }
            if case .children(let type?) = step.operation { return type }
            if case .typedKey(let type, _) = step.operation { return type }
            return nil
        }.first ?? "element"
        let typeWords = (ElementKind.knownTypeName(type)?.displayName ?? "Element")
            .split { !$0.isLetter }.map { $0.lowercased() }

        var words: [String] = Array((key ?? "").split { !$0.isLetter && !$0.isNumber }.map { $0.lowercased() }.prefix(5))
        // Don't repeat the type when the key already says it: "add-to-cart-button" + Button, "Search" + Search Field.
        let overlap = (0...min(words.count, typeWords.count)).last { words.suffix($0).elementsEqual(typeWords.prefix($0)) } ?? 0
        words.append(contentsOf: typeWords.dropFirst(overlap))
        var name = words.enumerated().map { $0.offset == 0 ? $0.element : $0.element.prefix(1).uppercased() + $0.element.dropFirst() }.joined()
        if let first = name.first, first.isNumber { name = "element" + name }
        return name.isEmpty ? "element" : name
    }

    private static func uniqueName(_ base: String, used: inout Set<String>) -> String {
        var name = base
        var counter = 2
        while used.contains(name) {
            name = "\(base)\(counter)"
            counter += 1
        }
        used.insert(name)
        return name
    }

    private static func modifierFlags(_ modifiers: [String]) -> String {
        switch modifiers.count {
        case 0: "[]"
        case 1: "." + modifiers[0]
        default: "[" + modifiers.map { "." + $0 }.joined(separator: ", ") + "]"
        }
    }

    private static func format(_ timeout: Double) -> String {
        timeout.rounded() == timeout ? String(Int(timeout)) : String(timeout)
    }
}
