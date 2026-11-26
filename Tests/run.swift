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

func execute(_ executable: URL, _ arguments: [String] = [], input: String = "") throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: "/")
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let stdin = Pipe()
    process.standardInput = stdin
    try process.run()
    stdin.fileHandleForWriting.write(Data(input.utf8))
    try stdin.fileHandleForWriting.close()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func runTests() throws {
    let fm = FileManager.default
    let tests = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent()
    let fixtures = tests.appendingPathComponent("Fixtures")
    for name in ["people.csv", "families.csv", "history.csv", "saved-history.json", "matching.json"] {
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
    func check(error: String? = nil, input: String = "", arguments: [String] = []) throws -> String {
        let before = try snapshot()
        let persistedBefore = try persistedSnapshot()
        let result = try execute(binary, arguments, input: input)
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
            try require(output.contains("2025: 6 participants, 6 assignments."), output)
            try require(output.contains("Active participants: Alex,"), output)
        }),
        ("quoted fields, escaped quotes, BOM, and CRLF", {
            try replace("people.csv", "alex,Alex,", "alex,\"Alex, \"\"Al\"\"\nSmith\",")
            let path = temporary.appendingPathComponent("people.csv")
            let text = try String(contentsOf: path, encoding: .utf8)
            try ("\u{FEFF}" + text.replacingOccurrences(of: "\n", with: "\r\n")).write(to: path, atomically: true, encoding: .utf8)
            let output = try check()
            try require(output.contains("Alex, \"Al\"\nSmith"), output)
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
            try importSavedFixture()
            try replace("history.json", "2023", "2026")
            try replace("families.csv", "household-1,blair", "household-1,blair\nhousehold-1,drew")
            try check()
        }),
        ("initial import preserves complete assignments", {
            try check()
            let records = try readHistory()
            try require(Set(records.keys) == Set(["2024", "2025"]), "Missing imported years.")
            let assignments = records["2025"]?["assignments"] as? [String: String]
            let participants = records["2025"]?["participants"] as? [String]
            try require(assignments?["alex"] == "casey", "Known assignment lost.")
            try require(assignments?["frankie"] == "blair" && participants?.contains("frankie") == true,
                        "Complete participation was not preserved.")
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
        ("new year imported with exact previous-file backup", {
            try check()
            let before = try Data(contentsOf: temporary.appendingPathComponent("history.json"))
            try replace("history.csv", "2024", "2022")
            try check()
            let records = try readHistory()
            try require(records["2022"] != nil && records["2024"] != nil,
                        "New or previously saved year is missing.")
            try require(Data(contentsOf: temporary.appendingPathComponent("history.json.bak")) == before,
                        "Backup does not contain the exact previous history.")
        }),
        ("conflicting known assignment leaves files intact", {
            try check()
            try replace("history.csv", "2025,alex,casey", "2025,alex,blair")
            try replace("history.csv", "2025,frankie,blair", "2025,frankie,casey")
            try check(error: "Conflicting assignment for 'alex' in 2025")
        }),
        ("blank recipient rejected without changing saved history", {
            try check()
            try replace("history.csv", "2025,alex,casey", "2025,alex,")
            try check(error: "Recipient is required; historical years must be complete")
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
            try replace("history.csv", "2023,casey,alex\n", "2023,casey,alex\n2023,drew,ellis\n2023,ellis,frankie\n2023,frankie,drew\n")
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
            records["2023"]?["submittedEmails"] = ["gale"]
            try writeHistory(records)
            try check(error: "submittedEmails must contain unique participant IDs")
        }),
        ("incomplete saved history is rejected even before sending", {
            try importSavedFixture()
            var records = try readHistory()
            var assignments = records["2023"]?["assignments"] as! [String: String]
            assignments.removeValue(forKey: "casey")
            records["2023"]?["assignments"] = assignments
            records["2023"]?["submittedEmails"] = [] as [String]
            try writeHistory(records)
            try check(error: "Incomplete history: every participant must give and receive exactly once")
        }),
        ("JSON loads without a historical CSV", {
            try importSavedFixture()
            try fm.removeItem(at: temporary.appendingPathComponent("history.csv"))
            let before = try persistedSnapshot()
            let output = try check()
            try require(output.contains("2023: 3 participants, 3 assignments."), output)
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
            try replace("history.csv", "2024", "2022")
            try fm.createDirectory(at: temporary.appendingPathComponent("history.json.bak"), withIntermediateDirectories: false)
            try check(error: "Could not save history")
        }),
        ("EOF leaves preview unsaved", {
            let output = try check()
            try require(output.contains("Proposed matches for 2026:"), output)
            try require(output.contains("Save this draw for 2026? [y/N]"), output)
            try require(output.contains("New matches were not saved"), output)
            try require(try readHistory()["2026"] == nil, "Preview was saved.")
            let before = try persistedSnapshot()
            try check()
            try require(before == persistedSnapshot(), "Repeated preview changed history.")
        }),
        ("existing year is not regenerated", {
            try importSavedFixture()
            try replace("history.json", "2023", "2026")
            let output = try check(input: "yes\n")
            try require(output.contains("A draw already exists for 2026"), output)
            try require(!output.contains("Proposed matches"), output)
            try require(!output.contains("Save this draw"), output)
        }),
        ("declining or unrecognized confirmation never saves", {
            try check()
            let before = try persistedSnapshot()
            for answer in ["no\n", "n\n", "\n", "maybe\n"] {
                let output = try check(input: answer)
                try require(output.contains("New matches were not saved"), output)
                try require(before == persistedSnapshot(), "Declining changed saved history.")
            }
        }),
        ("confirmation saves exactly the reviewed assignments", {
            try check()
            let before = try Data(contentsOf: temporary.appendingPathComponent("history.json"))
            let output = try check(input: "yes\n")
            try require(output.contains("Draw for 2026 saved to history.json"), output)
            let records = try readHistory()
            let assignments = records["2026"]?["assignments"] as? [String: String] ?? [:]
            let participants = records["2026"]?["participants"] as? [String] ?? []
            try require(assignments.count == 6 && Set(assignments.keys) == Set(participants)
                        && Set(assignments.values) == Set(participants), "Saved draw is incomplete.")
            let lines = output.components(separatedBy: "\n").filter { $0.contains(" → ") }
            try require(lines.count == assignments.count, "Saved count differs from preview.")
            // These fixture rows are unquoted; the CSV parser is tested separately.
            let contactRows = try String(contentsOf: fixtures.appendingPathComponent("people.csv"), encoding: .utf8)
                .split(separator: "\n").dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false) }
            let names = Dictionary(uniqueKeysWithValues: contactRows.map { (String($0[0]), String($0[1])) })
            for (giver, recipient) in assignments {
                try require(lines.contains("\(names[giver]!) → \(names[recipient]!)"),
                            "Saved assignment differs from preview.")
            }
            try require((records["2026"]?["submittedEmails"] as? [String]) == [], "New draw marked as sent.")
            try require(Data(contentsOf: temporary.appendingPathComponent("history.json.bak")) == before,
                        "Draw save did not preserve the previous history.")
        }),
        ("saved draw survives reruns and participant edits", {
            try check(input: " Y \n")
            let before = try persistedSnapshot()
            let original = try check(input: "yes\n")
            try require(original.contains("A draw already exists for 2026"), original)
            try require(before == persistedSnapshot(), "Rerun rewrote the draw or backup.")
            try replace("people.csv", "alex,Alex,alex@example.com,,true", "alex,Alexander,new@example.com,,false")
            try replace("families.csv", "household-1,alex", "household-1,alex\nhousehold-2,alex\nhousehold-3,alex")
            let output = try check()
            try require(output.contains("Alexander → "), "Saved participant disappeared after deactivation.")
            try require(before == persistedSnapshot(), "Contact or family edits changed saved assignments.")
        }),
        ("saving failure leaves new draw absent", {
            try check()
            try fm.createDirectory(at: temporary.appendingPathComponent("history.json.bak"), withIntermediateDirectories: false)
            try check(error: "Could not save history", input: "yes\n")
            try require(try readHistory()["2026"] == nil, "Failed save persisted a draw.")
        }),
        ("CSV cannot extend an existing target-year draw", {
            try importSavedFixture()
            try replace("history.json", "2023", "2026")
            var records = try readHistory()
            records["2026"]?["submittedEmails"] = [] as [String]
            try writeHistory(records)
            try replace("history.csv", "year,giver_id,recipient_id\n",
                        "year,giver_id,recipient_id\n2026,drew,ellis\n2026,ellis,frankie\n2026,frankie,drew\n")
            try check(error: "importing changes to it is not allowed")
        }),
        ("send requires a saved draw and never imports CSV", {
            try check(error: "No saved draw for 2026", arguments: ["--send"])
            try require(persistedSnapshot().isEmpty, "Send mode imported history.")
        }),
        ("send previews only and ignores family and history CSV", {
            try check(input: "yes\n")
            let before = try persistedSnapshot()
            try "invalid CSV".write(to: temporary.appendingPathComponent("families.csv"), atomically: true, encoding: .utf8)
            try "invalid CSV".write(to: temporary.appendingPathComponent("history.csv"), atomically: true, encoding: .utf8)
            let output = try check(input: "yes\n", arguments: ["--send"])
            try require(output.contains("Pending messages: 6"), output)
            try require(output.contains("real email sending is disabled"), output)
            try require(!output.contains("Proposed matches") && !output.contains("Save this draw"), output)
            try require(before == persistedSnapshot(), "Send preview changed persisted files.")
        }),
        ("unsupported arguments are rejected", {
            try check(error: "Usage: swift santa.swift [--send]", arguments: ["--other"])
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

    // Compile the actual production functions with a separate Swift test entrypoint.
    let matchingSource = temporary.appendingPathComponent("matching-tests.swift")
    let production = try String(contentsOf: source, encoding: .utf8)
    let matchingTests = try String(contentsOf: tests.appendingPathComponent("MatchingTests.swift"), encoding: .utf8)
    try (production + "\n" + matchingTests).write(to: matchingSource, atomically: true, encoding: .utf8)
    let matchingBinary = temporary.appendingPathComponent("matching-tests")
    let matchingCompile = try execute(URL(fileURLWithPath: "/usr/bin/xcrun"), [
        "swiftc", "-D", "TESTING", "-module-cache-path", temporary.appendingPathComponent("cache").path,
        matchingSource.path, "-o", matchingBinary.path,
    ])
    try require(matchingCompile.status == 0, matchingCompile.output)
    let matchingResult = try execute(matchingBinary, [fixtures.path])
    print(matchingResult.output, terminator: "")
    try require(matchingResult.status == 0, "Matching tests failed.")

    let mailSource = temporary.appendingPathComponent("mail-tests.swift")
    let mailTests = try String(contentsOf: tests.appendingPathComponent("MailTests.swift"), encoding: .utf8)
    try (production + "\n" + mailTests).write(to: mailSource, atomically: true, encoding: .utf8)
    let mailBinary = temporary.appendingPathComponent("mail-tests")
    let mailCompile = try execute(URL(fileURLWithPath: "/usr/bin/xcrun"), [
        "swiftc", "-D", "TESTING", "-module-cache-path", temporary.appendingPathComponent("cache").path,
        mailSource.path, "-o", mailBinary.path,
    ])
    try require(mailCompile.status == 0, mailCompile.output)
    let mailResult = try execute(mailBinary, [fixtures.path])
    print(mailResult.output, terminator: "")
    try require(mailResult.status == 0, "Mail tests failed.")
}

do { try runTests() }
catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
