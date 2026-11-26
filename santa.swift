#!/usr/bin/env swift
import Foundation

struct InputError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

struct Person {
    let id: String
    let name: String
    let email: String
    let phone: String?
    let active: Bool
}

struct FamilyMembership {
    let group: String
    let personID: String
}

struct HistoricalAssignment {
    let year: Int
    let giverID: String
    let recipientID: String?
    let line: Int
}

struct AnnualHistory: Codable, Equatable {
    var participants: [String] = []
    var assignments: [String: String] = [:]
    var historyWaivers: [String] = []
    var submittedEmails: [String] = []
}

typealias History = [String: AnnualHistory]

func validateHistory(_ history: History, personIDs: Set<String>) throws {
    for year in history.keys.sorted() {
        let record = history[year]!
        func invalid(_ message: String) -> InputError {
            InputError("history.json: \(year): \(message)")
        }
        guard year.count == 4, year.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(year), number >= 1000 else {
            throw invalid("Invalid calendar year.")
        }
        let participants = Set(record.participants)
        guard participants.count == record.participants.count else {
            throw invalid("Duplicate participant IDs.")
        }
        guard participants.isSubset(of: personIDs) else {
            throw invalid("Unknown person IDs: \(participants.subtracting(personIDs).sorted().joined(separator: ", ")).")
        }
        guard Set(record.assignments.keys).isSubset(of: participants),
              Set(record.assignments.values).isSubset(of: participants) else {
            throw invalid("Every giver and recipient must have a participation record.")
        }
        guard Set(record.assignments.values).count == record.assignments.count else {
            throw invalid("A recipient has more than one giver.")
        }
        for (name, ids) in [("historyWaivers", record.historyWaivers), ("submittedEmails", record.submittedEmails)] {
            guard Set(ids).count == ids.count, Set(ids).isSubset(of: participants) else {
                throw invalid("\(name) must contain unique participant IDs.")
            }
        }
        guard Set(record.submittedEmails).isSubset(of: Set(record.assignments.keys)) else {
            throw invalid("Submitted emails require a known assignment.")
        }
        guard record.submittedEmails.isEmpty || record.assignments.count == participants.count else {
            throw invalid("Email sending requires a complete draw: every participant must give and receive once.")
        }
        // Historical records may be incomplete or violate today's matching rules.
    }
}

func loadHistory(from url: URL, personIDs: Set<String>) throws -> History {
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    let history: History
    do {
        history = try JSONDecoder().decode(History.self, from: Data(contentsOf: url))
    } catch {
        throw InputError("history.json: Cannot load saved history: \(error). Existing history was not changed.")
    }
    try validateHistory(history, personIDs: personIDs)
    return history
}

func mergeHistory(_ imports: [HistoricalAssignment], into saved: History,
                  personIDs: Set<String>) throws -> History {
    var merged = saved
    for entry in imports {
        let year = String(entry.year)
        var record = merged[year] ?? AnnualHistory()
        let original = record
        if !record.participants.contains(entry.giverID) {
            record.participants.append(entry.giverID)
        }
        if let recipient = entry.recipientID {
            if let existing = record.assignments[entry.giverID], existing != recipient {
                throw InputError("history.csv:\(entry.line): Conflicting assignment for '\(entry.giverID)' in \(year): saved '\(existing)', imported '\(recipient)'. Correct the history explicitly.")
            }
            record.assignments[entry.giverID] = recipient
        }
        guard original.submittedEmails.isEmpty || record == original else {
            throw InputError("history.csv:\(entry.line): Cannot modify \(year) after email sending has started.")
        }
        merged[year] = record
    }
    try validateHistory(merged, personIDs: personIDs)
    return merged
}

func saveHistory(_ history: History, replacing previous: History, to url: URL) throws -> Bool {
    guard history != previous else { return false }
    var ordered = history
    for year in ordered.keys {
        ordered[year]!.participants.sort()
        ordered[year]!.historyWaivers.sort()
        ordered[year]!.submittedEmails.sort()
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(ordered)
    data.append(0x0A)
    do {
        if FileManager.default.fileExists(atPath: url.path) {
            let previousData = try Data(contentsOf: url)
            try previousData.write(to: url.appendingPathExtension("bak"), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    } catch {
        throw InputError("history.json: Could not save history: \(error.localizedDescription)")
    }
    return true
}

struct CSVRow {
    let fields: [String]
    let line: Int
}

// Parse standard quoted CSV, preserving embedded newlines and reporting physical lines.
func parseCSV(_ text: String, file: String) throws -> [CSVRow] {
    enum State { case plain, quoted, closed }
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    var chars = Array(normalized)
    if chars.first == "\u{FEFF}" { chars.removeFirst() }
    var rows: [CSVRow] = []
    var fields: [String] = []
    var field = ""
    var state = State.plain
    var line = 1
    var startLine = 1
    var recordStarted = false
    var index = 0

    func fail(_ message: String) -> InputError {
        InputError("\(file):\(line): \(message)")
    }
    func finishRow() {
        if recordStarted || !fields.isEmpty || !field.isEmpty {
            rows.append(CSVRow(fields: fields + [field], line: startLine))
        }
        fields = []
        field = ""
        recordStarted = false
        state = .plain
    }

    while index < chars.count {
        let char = chars[index]
        switch state {
        case .quoted:
            if char == "\"" {
                if index + 1 < chars.count && chars[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    state = .closed
                }
            } else {
                field.append(char)
                if char == "\n" { line += 1 }
            }
        case .plain, .closed:
            if char == "," {
                fields.append(field)
                field = ""
                state = .plain
                recordStarted = true
            } else if char == "\n" {
                finishRow()
                line += 1
                startLine = line
            } else if state == .closed {
                throw fail("Unexpected character after closing quote.")
            } else if char == "\"" {
                guard field.isEmpty else { throw fail("Quote inside an unquoted field.") }
                state = .quoted
                recordStarted = true
            } else {
                field.append(char)
                recordStarted = true
            }
        }
        index += 1
    }
    guard state != .quoted else { throw fail("Unterminated quoted field (record starts on line \(startLine)).") }
    finishRow()
    return rows
}

func readCSV(_ url: URL, headers: [String], optional: Bool = false) throws -> [CSVRow] {
    if optional && !FileManager.default.fileExists(atPath: url.path) { return [] }
    let text: String
    do { text = try String(contentsOf: url, encoding: .utf8) }
    catch { throw InputError("\(url.lastPathComponent): Cannot read UTF-8 CSV: \(error.localizedDescription)") }
    let rows = try parseCSV(text, file: url.lastPathComponent)
    guard let header = rows.first, header.fields == headers else {
        throw InputError("\(url.lastPathComponent):1: Expected header: \(headers.joined(separator: ","))")
    }
    for row in rows.dropFirst() where row.fields.count != headers.count {
        throw InputError("\(url.lastPathComponent):\(row.line): Expected \(headers.count) fields, found \(row.fields.count).")
    }
    return Array(rows.dropFirst())
}

func loadInputs(at directory: URL) throws -> ([Person], [FamilyMembership], [HistoricalAssignment]) {
    func failure(_ file: String, _ row: CSVRow, _ message: String) -> InputError {
        InputError("\(file):\(row.line): \(message)")
    }
    func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    var people: [Person] = []
    var personIDs = Set<String>()
    for row in try readCSV(directory.appendingPathComponent("people.csv"), headers: ["id", "name", "email", "phone", "active"]) {
        let f = row.fields.map(clean)
        guard !f[0].isEmpty, !f[1].isEmpty else { throw failure("people.csv", row, "ID and name are required.") }
        guard personIDs.insert(f[0]).inserted else { throw failure("people.csv", row, "Duplicate person ID '\(f[0])'.") }
        guard f[4] == "true" || f[4] == "false" else { throw failure("people.csv", row, "active must be true or false.") }
        guard f[4] == "false" || !f[2].isEmpty else { throw failure("people.csv", row, "Active participants require an email address.") }
        people.append(Person(id: f[0], name: f[1], email: f[2], phone: f[3].isEmpty ? nil : f[3], active: f[4] == "true"))
    }

    var memberships: [FamilyMembership] = []
    var membersByGroup: [String: Set<String>] = [:]
    for row in try readCSV(directory.appendingPathComponent("families.csv"), headers: ["group", "person_id"]) {
        let f = row.fields.map(clean)
        guard !f[0].isEmpty else { throw failure("families.csv", row, "Group name is required.") }
        guard personIDs.contains(f[1]) else { throw failure("families.csv", row, "Unknown person ID '\(f[1])'.") }
        guard membersByGroup[f[0], default: []].insert(f[1]).inserted else {
            throw failure("families.csv", row, "Duplicate membership for '\(f[1])' in '\(f[0])'.")
        }
        memberships.append(FamilyMembership(group: f[0], personID: f[1]))
    }

    var history: [HistoricalAssignment] = []
    var giversByYear: [Int: Set<String>] = [:]
    var recipientsByYear: [Int: Set<String>] = [:]
    for row in try readCSV(directory.appendingPathComponent("history.csv"), headers: ["year", "giver_id", "recipient_id"], optional: true) {
        let f = row.fields.map(clean)
        guard f[0].count == 4, f[0].allSatisfy({ $0.isASCII && $0.isNumber }), let year = Int(f[0]), year >= 1000 else {
            throw failure("history.csv", row, "Year must be a four-digit calendar year.")
        }
        guard personIDs.contains(f[1]) else { throw failure("history.csv", row, "Unknown giver ID '\(f[1])'.") }
        guard giversByYear[year, default: []].insert(f[1]).inserted else {
            throw failure("history.csv", row, "Duplicate participation for '\(f[1])' in \(year).")
        }
        if !f[2].isEmpty {
            guard personIDs.contains(f[2]) else { throw failure("history.csv", row, "Unknown recipient ID '\(f[2])'.") }
            guard recipientsByYear[year, default: []].insert(f[2]).inserted else {
                throw failure("history.csv", row, "Recipient '\(f[2])' appears more than once in \(year).")
            }
        }
        history.append(HistoricalAssignment(year: year, giverID: f[1], recipientID: f[2].isEmpty ? nil : f[2], line: row.line))
    }
    for entry in history {
        if let recipient = entry.recipientID, !giversByYear[entry.year, default: []].contains(recipient) {
            throw InputError("history.csv:\(entry.line): Recipient '\(recipient)' needs a participation row for \(entry.year) (leave their recipient blank if unknown).")
        }
    }
    return (people, memberships, history)
}

func main() throws {
    guard CommandLine.arguments.count == 1 else {
        throw InputError("Usage: swift santa.swift (history import only; matching and sending are not implemented yet)")
    }
    let directory = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent()
    let (people, memberships, imports) = try loadInputs(at: directory)
    let personIDs = Set(people.map(\.id))
    let historyURL = directory.appendingPathComponent("history.json")
    let saved = try loadHistory(from: historyURL, personIDs: personIDs)
    let history = try mergeHistory(imports, into: saved, personIDs: personIDs)
    let changed = try saveHistory(history, replacing: saved, to: historyURL)
    let active = people.filter(\.active)
    print("Inputs valid: \(people.count) people, \(active.count) active, \(Set(memberships.map(\.group)).count) family groups.")
    print("Active participants: \(active.map { "\($0.name) [\($0.id)]" }.joined(separator: ", "))")
    if history.isEmpty { print("No historical participation supplied.") }
    for year in history.keys.sorted() {
        let record = history[year]!
        let unknown = record.participants.count - record.assignments.count
        print("\(year): \(record.participants.count) participants, \(record.assignments.count) known assignments, \(unknown) unknown.")
    }
    print(changed ? "Imported history saved to history.json." : "History unchanged.")
    print("No new matches generated or emails sent.")
}

do { try main() }
catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}
