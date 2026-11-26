#!/usr/bin/env swift
import Foundation

// Integration tests use only Tests/Fixtures, copied into a disposable directory.
// Run from the project root: swift Tests/run.swift
struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(message) }
}

func execute(_ executable: URL, _ arguments: [String] = []) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: "/")
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func runTests() throws {
    let fm = FileManager.default
    let tests = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent()
    let fixtures = tests.appendingPathComponent("Fixtures")
    let temporary = fm.temporaryDirectory.appendingPathComponent("santa-tests-\(UUID().uuidString)")
    try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("santa.swift")
    let binary = temporary.appendingPathComponent("santa")
    try fm.copyItem(at: tests.deletingLastPathComponent().appendingPathComponent("santa.swift"), to: source)
    let compiled = try execute(URL(fileURLWithPath: "/usr/bin/xcrun"), [
        "swiftc", "-module-cache-path", temporary.appendingPathComponent("cache").path,
        source.path, "-o", binary.path,
    ])
    try require(compiled.status == 0, "Compilation failed:\n\(compiled.output)")

    let files = ["people.csv", "families.csv", "history.csv"]
    func reset() throws {
        for name in files {
            let destination = temporary.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: fixtures.appendingPathComponent(name), to: destination)
        }
    }
    func replace(_ name: String, _ old: String, _ new: String) throws {
        let path = temporary.appendingPathComponent(name)
        let original = try String(contentsOf: path, encoding: .utf8)
        try require(original.contains(old), "Test fixture missing expected text: \(old)")
        try original.replacingOccurrences(of: old, with: new).write(to: path, atomically: true, encoding: .utf8)
    }
    func snapshot() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in files where fm.fileExists(atPath: temporary.appendingPathComponent(name).path) {
            result[name] = try Data(contentsOf: temporary.appendingPathComponent(name))
        }
        return result
    }
    @discardableResult
    func check(error: String? = nil) throws -> String {
        let before = try snapshot()
        let result = try execute(binary)
        try require(result.status == (error == nil ? 0 : 1), "Unexpected exit status: \(result.output)")
        if let error { try require(result.output.contains(error), "Expected '\(error)', got: \(result.output)") }
        try require(before == snapshot(), "Input files changed.")
        try require(!fm.fileExists(atPath: temporary.appendingPathComponent("history.json").path), "Validation wrote history.json.")
        return result.output
    }

    let cases: [(String, () throws -> Void)] = [
        ("valid dedicated fixtures", {
            let output = try check()
            try require(output.contains("7 people, 6 active, 3 family groups"), output)
            try require(output.contains("2025: 6 participants, 5 known assignments, 1 unknown"), output)
            try require(output.contains("Alex [alex]"), output)
        }),
        ("quoted fields, escaped quotes, BOM, and CRLF", {
            try replace("people.csv", "alex,Alex,", "alex,\"Alex, \"\"Al\"\"\nSmith\",")
            let path = temporary.appendingPathComponent("people.csv")
            let text = try String(contentsOf: path, encoding: .utf8)
            try ("\u{FEFF}" + text.replacingOccurrences(of: "\n", with: "\r\n")).write(to: path, atomically: true, encoding: .utf8)
            let output = try check()
            try require(output.contains("Alex, \"Al\"\nSmith [alex]"), output)
        }),
        ("duplicate person", {
            try replace("people.csv", "blair,Blair", "alex,Blair")
            try check(error: "people.csv:3: Duplicate person ID")
        }),
        ("invalid active flag", {
            try replace("people.csv", ",true", ",yes")
            try check(error: "people.csv:2: active must be true or false")
        }),
        ("unknown family member", {
            try replace("families.csv", "household-1,alex", "household-1,nobody")
            try check(error: "families.csv:2: Unknown person ID")
        }),
        ("unknown historical recipient", {
            try replace("history.csv", "2024,alex,drew", "2024,alex,nobody")
            try check(error: "history.csv:2: Unknown recipient ID")
        }),
        ("missing historical participation", {
            try replace("history.csv", "2024,drew,blair\n", "")
            try check(error: "needs a participation row for 2024")
        }),
        ("duplicate historical recipient", {
            try replace("history.csv", "2024,blair,ellis", "2024,blair,drew")
            try check(error: "appears more than once in 2024")
        }),
        ("optional history absent", {
            try fm.removeItem(at: temporary.appendingPathComponent("history.csv"))
            let output = try check()
            try require(output.contains("No historical participation supplied"), output)
        }),
        ("required input absent", {
            try fm.removeItem(at: temporary.appendingPathComponent("people.csv"))
            try check(error: "people.csv: Cannot read UTF-8 CSV")
        }),
        ("wrong field count", {
            try replace("people.csv", "alex,Alex,alex@example.com,,true", "alex,Alex")
            try check(error: "people.csv:2: Expected 5 fields")
        }),
        ("unterminated quote", {
            try replace("people.csv", "alex,Alex", "alex,\"Alex")
            try check(error: "Unterminated quoted field")
        }),
        ("incorrect header", {
            try replace("families.csv", "group,person_id", "group,person")
            try check(error: "families.csv:1: Expected header")
        }),
        ("history ignores current family exclusions", {
            try replace("families.csv", "household-1,blair", "household-1,blair\nhousehold-1,drew")
            try check()
        }),
    ]
    var failures = 0
    for (name, test) in cases {
        do {
            try reset()
            try test()
            print("PASS: \(name)")
        } catch {
            failures += 1
            print("FAIL: \(name): \(error)")
        }
    }
    print("\(cases.count - failures)/\(cases.count) tests passed.")
    try require(failures == 0, "\(failures) tests failed.")
}

do { try runTests() }
catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
