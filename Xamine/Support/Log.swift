import os

/// Diagnostic logging. Read with: log show --last 5m --predicate 'subsystem == "com.xamine.Xamine"'
enum Log {
    static let picker = Logger(subsystem: "com.xamine.Xamine", category: "picker")
    static let scan = Logger(subsystem: "com.xamine.Xamine", category: "scan")
    static let capture = Logger(subsystem: "com.xamine.Xamine", category: "capture")
    static let automation = Logger(subsystem: "com.xamine.Xamine", category: "automation")
}
