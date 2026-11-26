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
    for name in ["people.csv", "families.csv", "history.csv", "saved-history.json"] {
        try require(fm.isReadableFile(atPath: fixtures.appendingPathComponent(name).path),
                    "Missing required test fixture: Tests/Fixtures/\(name). Restore it before running tests.")
    }
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
        for name in ["history.json", "history.json.bak"] {
            let path = temporary.appendingPathComponent(name)
            if fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) }
        }
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
        let persistedBefore = try persistedSnapshot()
        let result = try execute(binary)
        try require(result.status == (error == nil ? 0 : 1), "Unexpected exit status: \(result.output)")
        if let error { try require(result.output.contains(error), "Expected '\(error)', got: \(result.output)") }
        try require(before == snapshot(), "Input files changed.")
        if error != nil {
            try require(persistedBefore == persistedSnapshot(), "Failed import changed saved history or backup.")
        }
        return result.output
    }

    func persistedSnapshot() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in ["history.json", "history.json.bak"] {
            let path = temporary.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: path.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                result[name] = try Data(contentsOf: path)
            }
        }
        return result
    }
    func readHistory() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: temporary.appendingPathComponent("history.json"))
        guard let records = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            throw TestFailure("Expected JSON object keyed by year.")
        }
        return records
    }
    func writeHistory(_ records: [String: [String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: temporary.appendingPathComponent("history.json"))
    }
    func importSavedFixture() throws {
        try fm.copyItem(at: fixtures.appendingPathComponent("saved-history.json"),
                        to: temporary.appendingPathComponent("history.json"))
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
        ("initial import preserves unknown assignments", {
            try check()
            let records = try readHistory()
            try require(Set(records.keys) == Set(["2024", "2025"]), "Missing imported years.")
            let assignments = records["2025"]?["assignments"] as? [String: String]
            let participants = records["2025"]?["participants"] as? [String]
            try require(assignments?["alex"] == "casey", "Known assignment lost.")
            try require(assignments?["frankie"] == nil && participants?.contains("frankie") == true,
                        "Unknown participation was not preserved.")
            try require(!fm.fileExists(atPath: temporary.appendingPathComponent("history.json.bak").path),
                        "First import should not create a backup.")
        }),
        ("identical reimport changes neither history nor backup", {
            try importSavedFixture()
            try check()
            let before = try persistedSnapshot()
            let output = try check()
            try require(output.contains("History unchanged."), output)
            try require(before == persistedSnapshot(), "Identical reimport rewrote persisted files.")
        }),
        ("unknown recipient filled with exact previous-file backup", {
            try check()
            let before = try Data(contentsOf: temporary.appendingPathComponent("history.json"))
            try replace("history.csv", "2025,frankie,\n", "2025,frankie,blair\n")
            try check()
            let records = try readHistory()
            try require((records["2025"]?["assignments"] as? [String: String])?["frankie"] == "blair",
                        "Missing imported correction.")
            try require(Data(contentsOf: temporary.appendingPathComponent("history.json.bak")) == before,
                        "Backup does not contain the exact previous history.")
            try replace("history.csv", "2025,frankie,blair\n", "2025,frankie,\n")
            let after = try persistedSnapshot()
            try check()
            try require(after == persistedSnapshot(), "Blank import erased a known assignment.")
        }),
        ("conflicting known assignment leaves files intact", {
            try check()
            try replace("history.csv", "2025,alex,casey", "2025,alex,blair")
            try check(error: "Conflicting assignment for 'alex' in 2025")
        }),
        ("merged recipient collision leaves files intact", {
            try check()
            try replace("history.csv", "2025,alex,casey", "2025,alex,")
            try replace("history.csv", "2025,frankie,\n", "2025,frankie,casey\n")
            try check(error: "A recipient has more than one giver")
        }),
        ("existing years and delivery metadata survive import", {
            try importSavedFixture()
            let old = try readHistory()
            let oldData = try Data(contentsOf: temporary.appendingPathComponent("history.json"))
            try check()
            let records = try readHistory()
            try require(NSDictionary(dictionary: records["2023"]!) == NSDictionary(dictionary: old["2023"]!),
                        "Historical year or delivery metadata changed.")
            try require(Data(contentsOf: temporary.appendingPathComponent("history.json.bak")) == oldData,
                        "Previous saved fixture was not backed up.")
        }),
        ("sent year accepts identical rows but rejects additions", {
            try importSavedFixture()
            try replace("history.csv", "year,giver_id,recipient_id\n",
                        "year,giver_id,recipient_id\n2023,alex,blair\n2023,blair,casey\n2023,casey,alex\n")
            try check()
            try replace("history.csv", "2023,casey,alex\n", "2023,casey,alex\n2023,gale,\n")
            try check(error: "Cannot modify 2023 after email sending has started")
        }),
        ("malformed saved JSON is never replaced", {
            try "{ broken JSON".write(to: temporary.appendingPathComponent("history.json"), atomically: true, encoding: .utf8)
            try check(error: "Cannot load saved history")
        }),
        ("unknown saved person is rejected", {
            try importSavedFixture()
            try replace("history.json", "\"casey\"", "\"nobody\"")
            try check(error: "Unknown person IDs: nobody")
        }),
        ("saved participation and metadata are validated", {
            try importSavedFixture()
            var records = try readHistory()
            var assignments = records["2023"]?["assignments"] as! [String: String]
            assignments.removeValue(forKey: "casey")
            records["2023"]?["assignments"] = assignments
            records["2023"]?["submittedEmails"] = ["casey"]
            try writeHistory(records)
            try check(error: "Submitted emails require a known assignment")
        }),
        ("incomplete draw cannot have submitted emails", {
            try importSavedFixture()
            var records = try readHistory()
            var assignments = records["2023"]?["assignments"] as! [String: String]
            assignments.removeValue(forKey: "casey")
            records["2023"]?["assignments"] = assignments
            try writeHistory(records)
            try check(error: "Email sending requires a complete draw")
        }),
        ("JSON loads without a historical CSV", {
            try importSavedFixture()
            try fm.removeItem(at: temporary.appendingPathComponent("history.csv"))
            let before = try persistedSnapshot()
            let output = try check()
            try require(output.contains("2023: 3 participants, 3 known assignments, 0 unknown"), output)
            try require(before == persistedSnapshot(), "Read-only load changed history.")
        }),
        ("no history inputs create no files", {
            try fm.removeItem(at: temporary.appendingPathComponent("history.csv"))
            try check()
            try require(persistedSnapshot().isEmpty, "Empty history should not create files.")
        }),
        ("contact edits and deactivation preserve history", {
            try check()
            let before = try persistedSnapshot()
            try replace("people.csv", "alex,Alex,alex@example.com,,true", "alex,Alexander,new@example.com,,false")
            try check()
            try require(before == persistedSnapshot(), "Contact edits changed historical identity.")
        }),
        ("backup failure prevents history replacement", {
            try check()
            try replace("history.csv", "2025,frankie,\n", "2025,frankie,blair\n")
            try fm.createDirectory(at: temporary.appendingPathComponent("history.json.bak"), withIntermediateDirectories: false)
            try check(error: "Could not save history")
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
