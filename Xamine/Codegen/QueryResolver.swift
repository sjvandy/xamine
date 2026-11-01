import Foundation

/// Evaluates an XCUITest query expression, such as `app.windows["Cart"].buttons.element(boundBy: 0)`, against a
/// scanned `UITree`, step by step. Supports what Xamine generates plus the common hand-written forms: element type
/// queries, subscripts, `matching(identifier:)`, `matching(_:identifier:)`, `matching(NSPredicate(format:))` with a
/// single comparison, `children(matching:)`, `descendants(matching:)`, `containing(_:identifier:)`,
/// `element(boundBy:)`, `element` and `firstMatch`. Anything else stops parsing with an error rather than a guess.
struct QueryResolver {
    struct Predicate: Equatable, Sendable {
        enum Operator: String, Sendable { case equals = "==", contains = "CONTAINS", beginsWith = "BEGINSWITH", endsWith = "ENDSWITH", like = "LIKE" }
        let key: String
        let op: Operator
        let value: String
        let caseInsensitive: Bool
    }

    enum Operation: Equatable, Sendable {
        /// `nil` type means `.any`.
        case descendants(String?)
        case children(String?)
        case key(String)
        case typedKey(String, String)
        case predicate(Predicate)
        case containing(String?, String)
        case boundBy(Int)
        case firstMatch
        case element

        /// Whether this step filters by text, which is what usually breaks when an app's copy changes.
        var key: String? {
            switch self {
            case .key(let key), .typedKey(_, let key), .containing(_, let key): key
            case .predicate(let predicate): predicate.value
            default: nil
            }
        }
    }

    struct Step: Equatable, Sendable {
        /// The step as written, e.g. `.buttons` or `["Save"]`.
        let source: String
        let operation: Operation
    }

    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Resolution: Sendable {
        /// Matching node ids in document order.
        let matches: [Int]
        /// Matches after each step.
        let counts: [Int]
        /// The first step that left nothing, if any.
        let failedStep: Int?
    }

    let tree: UITree

    // MARK: - Evaluation

    func resolve(_ steps: [Step]) -> Resolution {
        // -1 is the application, above the scanned window.
        var current = [-1]
        var counts: [Int] = []
        var failedStep: Int?
        for (index, step) in steps.enumerated() {
            current = apply(step.operation, to: current)
            counts.append(current.count)
            if current.isEmpty, failedStep == nil { failedStep = index }
        }
        return Resolution(matches: current.filter { $0 >= 0 }, counts: counts, failedStep: failedStep)
    }

    /// The candidates a step chose from: the matches just before it, widened to every element of the step's type.
    func candidates(before index: Int, in steps: [Step]) -> [Int] {
        let previous = index == 0 ? [-1] : resolve(Array(steps.prefix(index))).matches
        switch steps[index].operation {
        case .descendants, .children:
            return previous.flatMap { descendants(of: $0) }
        default:
            return previous
        }
    }

    func apply(_ operation: Operation, to current: [Int]) -> [Int] {
        switch operation {
        case .descendants(let type):
            return union(current.flatMap { descendants(of: $0) }.filter { isType(type, $0) })
        case .children(let type):
            return union(current.flatMap { $0 < 0 ? [0] : tree.node($0).childIDs }.filter { isType(type, $0) })
        case .key(let key):
            return current.filter { $0 >= 0 && tree.node($0).matchesIdentifier(key) }
        case .typedKey(let type, let key):
            return current.filter { $0 >= 0 && isType(type, $0) && tree.node($0).matchesIdentifier(key) }
        case .predicate(let predicate):
            return current.filter { $0 >= 0 && Self.matches(predicate, tree.node($0)) }
        case .containing(let type, let key):
            return current.filter { id in descendants(of: id).contains { isType(type, $0) && tree.node($0).matchesIdentifier(key) } }
        case .boundBy(let index):
            return current.indices.contains(index) ? [current[index]] : []
        case .firstMatch:
            return Array(current.prefix(1))
        case .element:
            return current
        }
    }

    private func isType(_ type: String?, _ id: Int) -> Bool {
        guard let type, type != "any" else { return true }
        return id >= 0 && tree.node(id).kind.typeName == type
    }

    /// Every element below `id`, in document order. Node ids are assigned depth-first, so this is the id order.
    private func descendants(of id: Int) -> [Int] {
        guard id >= 0 else { return tree.nodes.map(\.id) }
        var result: [Int] = []
        var stack = tree.node(id).childIDs.reversed() as [Int]
        while let next = stack.popLast() {
            result.append(next)
            stack.append(contentsOf: tree.node(next).childIDs.reversed())
        }
        return result
    }

    private func union(_ ids: [Int]) -> [Int] {
        Array(Set(ids)).sorted()
    }

    static func matches(_ predicate: Predicate, _ node: UINode) -> Bool {
        let field: String? = switch predicate.key.lowercased() {
        case "label": node.label ?? node.title
        case "title": node.title
        case "identifier": node.identifier
        case "value": node.value
        case "placeholdervalue": node.placeholder
        default: nil
        }
        guard var field else { return false }
        var value = predicate.value
        if predicate.caseInsensitive {
            field = field.lowercased()
            value = value.lowercased()
        }
        switch predicate.op {
        case .equals: return field == value
        case .contains: return field.contains(value)
        case .beginsWith: return field.hasPrefix(value)
        case .endsWith: return field.hasSuffix(value)
        case .like:
            let pattern = "^" + NSRegularExpression.escapedPattern(for: value)
                .replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
            return field.range(of: pattern, options: .regularExpression) != nil
        }
    }

    // MARK: - Similarity

    /// How alike two strings are, 0…1: edit distance, with a boost when one contains the other.
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a.lowercased()), b = Array(b.lowercased())
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = row
        }
        let score = 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
        let contains = String(a).contains(String(b)) || String(b).contains(String(a))
        return contains ? max(score, 0.6) : score
    }

    // MARK: - Parsing

    /// Parses `query`, ignoring a leading `XCTAssert…(` wrapper and trailing members such as `.exists`, `.click()`
    /// or `.waitForExistence(timeout: 5)`.
    static func parse(_ query: String) throws -> [Step] {
        var parser = Parser(Array(query))
        return try parser.parseQuery()
    }

    private struct Parser {
        let chars: [Character]
        var position = 0

        init(_ chars: [Character]) { self.chars = chars }

        mutating func parseQuery() throws -> [Step] {
            try skipToRoot()
            var steps: [Step] = []
            while true {
                skipSpace()
                guard position < chars.count else { break }
                let start = position
                if chars[position] == "[" {
                    position += 1
                    skipSpace()
                    let key = try string()
                    skipSpace()
                    try expect("]")
                    steps.append(Step(source: source(from: start), operation: .key(key)))
                } else if chars[position] == "." {
                    position += 1
                    let name = identifier()
                    skipSpace()
                    var arguments: [Argument] = []
                    var hasCall = false
                    if position < chars.count, chars[position] == "(" {
                        hasCall = true
                        arguments = try argumentList()
                    }
                    guard let operation = try operation(name: name, arguments: arguments, hasCall: hasCall) else {
                        position = start
                        break // a terminal member: .exists, .click(), .label …
                    }
                    steps.append(Step(source: source(from: start), operation: operation))
                } else {
                    break
                }
            }
            if steps.isEmpty { throw ParseError(message: "Expected a query such as app.buttons[\"Save\"].") }
            return steps
        }

        /// Moves past `app`, `XCUIApplication()` or `XCUIApplication(bundleIdentifier: …)`, skipping any wrapper.
        private mutating func skipToRoot() throws {
            let text = String(chars)
            for root in ["XCUIApplication(", "app."] {
                guard let range = text.range(of: root) else { continue }
                position = text.distance(from: text.startIndex, to: range.lowerBound)
                if root == "app." {
                    position += 3
                } else {
                    position += root.count - 1
                    _ = try argumentList()
                }
                return
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("app[") {
                position = text.distance(from: text.startIndex, to: text.range(of: "app[")!.lowerBound) + 3
                return
            }
            throw ParseError(message: "The query must start from app or XCUIApplication(…).")
        }

        /// The step as written, without whitespace outside string literals (queries are often split across lines).
        private func source(from start: Int) -> String {
            var result = ""
            var quote: Character?
            var previous: Character = " "
            for c in chars[start..<position] {
                if let open = quote {
                    if c == open && previous != "\\" { quote = nil }
                    result.append(c)
                } else if c == "\"" || c == "'" {
                    quote = c
                    result.append(c)
                } else if !c.isWhitespace {
                    result.append(c)
                } else if result.last == "," || result.last == ":" {
                    result.append(" ")
                }
                previous = c
            }
            return result
        }

        private mutating func operation(name: String, arguments: [Argument], hasCall: Bool) throws -> Operation? {
            if !hasCall, let kind = ElementKind.forQueryName(name) { return .descendants(kind.typeName) }
            switch (name, hasCall) {
            case ("firstMatch", false): return .firstMatch
            case ("element", false): return .element
            case ("element", true):
                guard let index = arguments.first(where: { $0.label == "boundBy" })?.integer else {
                    throw ParseError(message: "element(…) needs boundBy: <index>.")
                }
                return .boundBy(index)
            case ("children", true), ("descendants", true):
                guard let type = arguments.first?.type else { throw ParseError(message: "\(name)(matching:) needs an element type like .button.") }
                let typeName = type == "any" ? nil : type
                return name == "children" ? .children(typeName) : .descendants(typeName)
            case ("matching", true):
                if let predicate = arguments.first?.predicate { return .predicate(try Self.predicate(predicate)) }
                if let identifier = arguments.first(where: { $0.label == "identifier" })?.string {
                    if let type = arguments.first?.type { return .typedKey(type, identifier) }
                    return .key(identifier)
                }
                throw ParseError(message: "Unsupported matching(…) form.")
            case ("containing", true):
                if let identifier = arguments.first(where: { $0.label == "identifier" })?.string {
                    let type = arguments.first?.type
                    return .containing(type == "any" ? nil : type, identifier)
                }
                throw ParseError(message: "Only containing(_:identifier:) is supported.")
            default:
                return nil
            }
        }

        /// Parses a single NSPredicate comparison such as `label CONTAINS[c] 'Cart'`.
        private static func predicate(_ format: String) throws -> Predicate {
            let pattern = #"^\s*(\w+)\s*(==|=|CONTAINS|BEGINSWITH|ENDSWITH|LIKE)\s*(\[[cd]+\])?\s*(?:'([^']*)'|"([^"]*)")\s*$"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: format, range: NSRange(format.startIndex..., in: format)) else {
                throw ParseError(message: "Only single comparisons are supported in predicates, e.g. label CONTAINS 'Cart'. Got: \(format)")
            }
            func group(_ index: Int) -> String? {
                Range(match.range(at: index), in: format).map { String(format[$0]) }
            }
            let rawOp = group(2)!.uppercased()
            let op: Predicate.Operator = rawOp == "=" ? .equals : Predicate.Operator(rawValue: rawOp) ?? .equals
            return Predicate(key: group(1)!, op: op, value: group(4) ?? group(5) ?? "", caseInsensitive: group(3)?.contains("c") == true)
        }

        // MARK: Arguments

        struct Argument {
            var label: String?
            var string: String?
            var integer: Int?
            var type: String?
            var predicate: String?
        }

        private mutating func argumentList() throws -> [Argument] {
            try expect("(")
            var arguments: [Argument] = []
            while true {
                skipSpace()
                guard position < chars.count else { throw ParseError(message: "Missing ).") }
                if chars[position] == ")" { position += 1; break }
                arguments.append(try argument())
                skipSpace()
                if position < chars.count, chars[position] == "," { position += 1 }
            }
            return arguments
        }

        private mutating func argument() throws -> Argument {
            var argument = Argument()
            let save = position
            let label = identifier()
            skipSpace()
            if !label.isEmpty, position < chars.count, chars[position] == ":" {
                argument.label = label
                position += 1
                skipSpace()
            } else {
                position = save
            }
            guard position < chars.count else { throw ParseError(message: "Missing argument.") }
            let c = chars[position]
            if c == "\"" || c == "#" {
                argument.string = try string()
            } else if c == "." {
                position += 1
                argument.type = identifier()
            } else if c.isNumber {
                let digits = identifier()
                argument.integer = Int(digits)
            } else {
                let name = identifier()
                guard name == "NSPredicate" else { throw ParseError(message: "Unsupported argument starting at \(name.isEmpty ? String(c) : name).") }
                let inner = try argumentList()
                guard let format = inner.first?.string else { throw ParseError(message: "NSPredicate needs format: \"…\".") }
                argument.predicate = format
            }
            return argument
        }

        // MARK: Lexing

        private mutating func skipSpace() {
            while position < chars.count, chars[position].isWhitespace { position += 1 }
        }

        private mutating func identifier() -> String {
            let start = position
            while position < chars.count, chars[position].isLetter || chars[position].isNumber || chars[position] == "_" { position += 1 }
            return String(chars[start..<position])
        }

        private mutating func expect(_ c: Character) throws {
            guard position < chars.count, chars[position] == c else { throw ParseError(message: "Expected \(c) in the query.") }
            position += 1
        }

        /// A Swift string literal, plain ("…") or raw (#"…"#).
        private mutating func string() throws -> String {
            var hashes = 0
            while position < chars.count, chars[position] == "#" { hashes += 1; position += 1 }
            try expect("\"")
            var result = ""
            while position < chars.count {
                let c = chars[position]
                if c == "\"" {
                    let closing = chars[(position + 1)...].prefix(hashes)
                    if closing.count == hashes, closing.allSatisfy({ $0 == "#" }) {
                        position += 1 + hashes
                        return result
                    }
                }
                if c == "\\", hashes == 0, position + 1 < chars.count {
                    position += 1
                    switch chars[position] {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    default: result.append(chars[position])
                    }
                } else {
                    result.append(c)
                }
                position += 1
            }
            throw ParseError(message: "Unterminated string in the query.")
        }
    }
}
