#!/usr/bin/env swift
import Foundation

// Local configuration lives beside the script; see templates/config.json.
struct Configuration: Codable {
    let drawYear: Int
    let senderEmail: String
    let eventNote: String
    let subjectTemplate: String
    let bodyTemplate: String

    static func load(at directory: URL) throws -> Configuration {
        let url = directory.appendingPathComponent("config.json")
        let config: Configuration
        do { config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url)) }
        catch { throw InputError("config.json: Cannot load configuration: \(error). Copy templates/config.json and customize it.") }
        guard (1000...9999).contains(config.drawYear) else { throw InputError("config.json: drawYear must be a four-digit calendar year.") }
        guard !config.subjectTemplate.isEmpty, config.bodyTemplate.contains("{recipient}") else {
            throw InputError("config.json: subjectTemplate is required and bodyTemplate must contain {recipient}.")
        }
        return config
    }

    func render(_ template: String, giver: String = "", recipient: String = "") -> String {
        // Replace tokens in a single pass so names cannot introduce template substitutions.
        let values = ["{year}": String(drawYear), "{giver}": giver, "{recipient}": recipient, "{eventNote}": eventNote]
        let pattern = try! NSRegularExpression(pattern: #"\{(?:year|giver|recipient|eventNote)\}"#)
        var result = template
        for match in pattern.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            let range = Range(match.range, in: result)!
            result.replaceSubrange(range, with: values[String(result[range])]!)
        }
        return result
    }
}

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

struct GroupMembership {
    let group: String
    let personID: String
}

struct HistoricalAssignment {
    let year: Int
    let giverID: String
    let recipientID: String
    let line: Int
}

struct AnnualHistory: Codable, Equatable {
    var participants: [String] = []
    var assignments: [String: String] = [:]
    var submittedEmails: [String] = []
}

typealias History = [String: AnnualHistory]

struct PreparedEmail {
    let giverID: String
    let sender: String
    let address: String
    let subject: String
    let body: String
}

struct AppleMailSender {
    let scriptURL: URL

    private func invoke(_ arguments: [String], expecting response: String) throws {
        guard FileManager.default.isReadableFile(atPath: scriptURL.path) else {
            throw InputError("Cannot read Apple Mail helper: \(scriptURL.path)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [scriptURL.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, output == response else {
            throw InputError("Apple Mail helper failed: \(output.isEmpty ? "no success response" : output)")
        }
    }

    func check(sender: String) throws {
        try invoke(["check", sender], expecting: "READY")
    }

    func submit(_ message: PreparedEmail) throws {
        try invoke(["send", message.sender, message.address, message.subject, message.body], expecting: "SUBMITTED")
    }
}

func prepareEmails(people: [Person], history: History, config: Configuration) throws -> [PreparedEmail] {
    let year = config.drawYear
    let sender = config.senderEmail
    try validateHistory(history, personIDs: Set(people.map(\.id)))
    guard let draw = history[String(year)] else {
        throw InputError("No saved draw for \(year). Generate and save it before preparing emails.")
    }
    // Check the saved draw's structure, without applying today's groups or active flags.
    try validateAssignments(draw.assignments, participants: draw.participants,
                            memberships: [], history: [:], year: year)
    func validAddress(_ address: String) -> Bool {
        address.range(of: #"^[^@\s,;<>]+@[^@\s,;<>]+\.[^@\s,;<>]+$"#, options: .regularExpression) != nil
    }
    guard validAddress(sender) else { throw InputError("Configure a valid dedicated senderEmail address.") }
    let contacts = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
    return try draw.participants.sorted().filter { !draw.submittedEmails.contains($0) }.map { giver in
        let person = contacts[giver]!
        guard validAddress(person.email) else {
            throw InputError("\(person.name) [\(giver)] needs a valid email address before sending.")
        }
        let recipient = contacts[draw.assignments[giver]!]!
        return PreparedEmail(giverID: giver, sender: sender, address: person.email,
                             subject: config.render(config.subjectTemplate, giver: person.name, recipient: recipient.name),
                             body: config.render(config.bodyTemplate, giver: person.name, recipient: recipient.name))
    }
}

func submitEmails(_ messages: [PreparedEmail], history: History, year: Int, to url: URL,
                  submit: (PreparedEmail) throws -> Void) throws {
    var progress = history
    for message in messages {
        do {
            try submit(message)
            var updated = progress
            updated[String(year)]!.submittedEmails.append(message.giverID)
            _ = try saveHistory(updated, replacing: progress, to: url)
            progress = updated
        } catch {
            throw InputError("Stopped while sending to \(message.address): \(error). Check Mail before retrying; a message may have been submitted before its status was saved.")
        }
    }
}

func askYesNo(_ prompt: String) -> Bool {
    print(prompt)
    let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return answer == "y" || answer == "yes"
}

func runSending(at directory: URL, config: Configuration,
                submit: (PreparedEmail) throws -> Void,
                checkSender: () throws -> Void = {},
                confirm: (String) -> Bool = askYesNo,
                output: (String) -> Void = { print($0) }) throws {
    let people = try loadPeople(at: directory, requireActiveEmails: false)
    let url = directory.appendingPathComponent("history.json")
    let history = try loadHistory(from: url, personIDs: Set(people.map(\.id)))
    let messages = try prepareEmails(people: people, history: history, config: config)
    guard !messages.isEmpty else {
        output("All messages for \(config.drawYear) are already recorded as submitted. Nothing to send.")
        return
    }
    let names = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.name) })
    output("\(messages.count) assignment emails are ready to send to:")
    for message in messages { output("- \(names[message.giverID]!)") }
    output("")
    guard confirm("Send these emails from \(config.senderEmail)? [y/N]") else {
        output("Sending cancelled. Matches remain saved; no emails sent.")
        return
    }
    try checkSender()
    try submitEmails(messages, history: history, year: config.drawYear, to: url) { message in
        try submit(message)
        output("Submitted email to \(names[message.giverID]!).")
    }
    output("Recorded \(messages.count) submissions. Submission does not confirm delivery.")
}

struct DrawRestrictions {
    var eligible: [String: Set<String>]
}

func drawRestrictions(participants: [String], memberships: [GroupMembership],
                      history: History, year: Int) throws -> DrawRestrictions {
    let pool = Set(participants)
    var groups: [String: Set<String>] = [:]
    for membership in memberships {
        groups[membership.personID, default: []].insert(membership.group)
    }
    let previousYears = history.keys.compactMap(Int.init).filter { $0 < year }.sorted(by: >)
    var eligible: [String: Set<String>] = [:]
    for giver in participants {
        var options = pool.filter {
            $0 != giver && groups[giver, default: []].isDisjoint(with: groups[$0, default: []])
        }
        if let previousYear = previousYears.first(where: { history[String($0)]!.participants.contains(giver) }) {
            guard let recipient = history[String(previousYear)]!.assignments[giver] else {
                throw InputError("Incomplete history for \(previousYear): missing assignment for '\(giver)'.")
            }
            options.remove(recipient)
        }
        eligible[giver] = options
    }
    return DrawRestrictions(eligible: eligible)
}

// MRV chooses the giver; shuffled ties and recipient branches randomize the DFS.
// The backtrack count lets tests verify that failed branches really are explored.
func findAssignments<R: RandomNumberGenerator>(eligible: [String: Set<String>],
                                               using random: inout R)
    -> (assignments: [String: String]?, backtracks: Int) {
    let participants = eligible.keys.sorted()
    guard participants.count >= 3 else { return (nil, 0) }
    var assignments: [String: String] = [:]
    var taken = Set<String>()
    var backtracks = 0
    func search() -> Bool {
        if assignments.count == participants.count { return true }
        var choices: [(giver: String, recipients: [String])] = []
        var minimum = Int.max
        for giver in participants where assignments[giver] == nil {
            let options = eligible[giver]!.filter {
                !taken.contains($0) && assignments[$0] != giver
            }.sorted()
            if options.isEmpty { return false }
            if options.count < minimum {
                minimum = options.count
                choices = []
            }
            if options.count == minimum { choices.append((giver, options)) }
        }
        choices.shuffle(using: &random)
        let choice = choices[0]
        var recipients = choice.recipients
        recipients.shuffle(using: &random)
        for recipient in recipients {
            assignments[choice.giver] = recipient
            taken.insert(recipient)
            if search() { return true }
            assignments.removeValue(forKey: choice.giver)
            taken.remove(recipient)
            backtracks += 1
        }
        return false
    }
    let found = search()
    return (found ? assignments : nil, backtracks)
}

func validateAssignments(_ assignments: [String: String], participants: [String],
                         memberships: [GroupMembership], history: History, year: Int) throws {
    let pool = Set(participants)
    guard participants.count >= 3, pool.count == participants.count,
          Set(assignments.keys) == pool, Set(assignments.values) == pool else {
        throw InputError("Invalid draw: every participant must give and receive exactly once.")
    }
    // Check the original rules independently rather than trusting the search graph.
    for giver in participants {
        let recipient = assignments[giver]!
        guard giver != recipient, assignments[recipient] != giver else {
            throw InputError("Invalid draw: self-assignment or reciprocal pair involving '\(giver)'.")
        }
        let groups = Set(memberships.filter { $0.personID == giver }.map(\.group))
        guard !memberships.contains(where: { $0.personID == recipient && groups.contains($0.group) }) else {
            throw InputError("Invalid draw: '\(giver)' and '\(recipient)' share a exclusion group.")
        }
        let previousYear = history.keys.compactMap(Int.init).filter {
            $0 < year && history[String($0)]!.participants.contains(giver)
        }.max()
        if let previousYear {
            if let previousRecipient = history[String(previousYear)]!.assignments[giver] {
                guard recipient != previousRecipient else {
                    throw InputError("Invalid draw: '\(giver)' repeats their recipient from \(previousYear).")
                }
            } else {
                throw InputError("Incomplete history for \(previousYear): missing assignment for '\(giver)'.")
            }
        }
    }
}

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
        guard !participants.isEmpty, Set(record.assignments.keys) == participants,
              Set(record.assignments.values) == participants else {
            throw invalid("Incomplete history: every participant must give and receive exactly once.")
        }
        guard Set(record.submittedEmails).count == record.submittedEmails.count,
              Set(record.submittedEmails).isSubset(of: participants) else {
            throw invalid("submittedEmails must contain unique participant IDs.")
        }
        // Historical records need not satisfy today's group exclusions.
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
        let recipient = entry.recipientID
        if let existing = record.assignments[entry.giverID], existing != recipient {
            throw InputError("history.csv:\(entry.line): Conflicting assignment for '\(entry.giverID)' in \(year): saved '\(existing)', imported '\(recipient)'. Correct the history explicitly.")
        }
        record.assignments[entry.giverID] = recipient
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

func loadPeople(at directory: URL, requireActiveEmails: Bool = true) throws -> [Person] {
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
        guard !requireActiveEmails || f[4] == "false" || !f[2].isEmpty else { throw failure("people.csv", row, "Active participants require an email address.") }
        people.append(Person(id: f[0], name: f[1], email: f[2], phone: f[3].isEmpty ? nil : f[3], active: f[4] == "true"))
    }

    return people
}

func loadInputs(at directory: URL) throws -> ([Person], [GroupMembership], [HistoricalAssignment]) {
    let people = try loadPeople(at: directory)
    let personIDs = Set(people.map(\.id))
    func failure(_ file: String, _ row: CSVRow, _ message: String) -> InputError {
        InputError("\(file):\(row.line): \(message)")
    }
    func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    var memberships: [GroupMembership] = []
    var membersByGroup: [String: Set<String>] = [:]
    for row in try readCSV(directory.appendingPathComponent("groups.csv"), headers: ["group", "person_id"]) {
        let f = row.fields.map(clean)
        guard !f[0].isEmpty else { throw failure("groups.csv", row, "Group name is required.") }
        guard personIDs.contains(f[1]) else { throw failure("groups.csv", row, "Unknown person ID '\(f[1])'.") }
        guard membersByGroup[f[0], default: []].insert(f[1]).inserted else {
            throw failure("groups.csv", row, "Duplicate membership for '\(f[1])' in '\(f[0])'.")
        }
        memberships.append(GroupMembership(group: f[0], personID: f[1]))
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
        guard !f[2].isEmpty else {
            throw failure("history.csv", row, "Recipient is required; historical years must be complete.")
        }
        guard personIDs.contains(f[2]) else { throw failure("history.csv", row, "Unknown recipient ID '\(f[2])'.") }
        guard recipientsByYear[year, default: []].insert(f[2]).inserted else {
            throw failure("history.csv", row, "Recipient '\(f[2])' appears more than once in \(year).")
        }
        history.append(HistoricalAssignment(year: year, giverID: f[1], recipientID: f[2], line: row.line))
    }
    for entry in history {
        if !giversByYear[entry.year, default: []].contains(entry.recipientID) {
            throw InputError("history.csv:\(entry.line): Recipient '\(entry.recipientID)' needs a participation row for \(entry.year); historical years must be complete.")
        }
    }
    return (people, memberships, history)
}

struct Options {
    let showMatches: Bool
    let noEmail: Bool
    let regenerateMatches: Bool

    init(_ arguments: [String]) throws {
        let supported: Set<String> = ["--show-matches", "--no-email", "--regenerate-matches"]
        guard Set(arguments).isSubset(of: supported) else {
            throw InputError("Usage: swift santa.swift [--show-matches] [--no-email] [--regenerate-matches]")
        }
        showMatches = arguments.contains("--show-matches")
        noEmail = arguments.contains("--no-email")
        regenerateMatches = arguments.contains("--regenerate-matches")
    }
}

func run(at directory: URL, options: Options,
         submit: (PreparedEmail) throws -> Void,
         checkSender: (String) throws -> Void,
         confirm: (String) -> Bool = askYesNo,
         output: (String) -> Void = { print($0) }) throws {
    let config = try Configuration.load(at: directory)
    let year = String(config.drawYear)
    let (people, memberships, imports) = try loadInputs(at: directory)
    let personIDs = Set(people.map(\.id))
    let historyURL = directory.appendingPathComponent("history.json")
    let saved = try loadHistory(from: historyURL, personIDs: personIDs)
    // Regeneration explicitly replaces the target year, including target-year CSV imports.
    let applicableImports = options.regenerateMatches ? imports.filter { $0.year != config.drawYear } : imports
    var history = try mergeHistory(applicableImports, into: saved, personIDs: personIDs)
    if !options.regenerateMatches, let existing = saved[year], history[year] != existing {
        throw InputError("A draw already exists for \(config.drawYear); importing changes to it is not allowed.")
    }
    let active = people.filter(\.active)
    output("Inputs valid: \(people.count) people, \(active.count) active, \(Set(memberships.map(\.group)).count) exclusion groups.")
    if history[year] == nil || options.regenerateMatches {
        let participants = active.map(\.id)
        guard participants.count >= 3 else { throw InputError("At least three active participants are required.") }
        let restrictions = try drawRestrictions(participants: participants, memberships: memberships,
                                                history: history, year: config.drawYear)
        var random = SystemRandomNumberGenerator()
        guard let assignments = findAssignments(eligible: restrictions.eligible, using: &random).assignments else {
            throw InputError("No valid draw exists for these participants and restrictions.")
        }
        try validateAssignments(assignments, participants: participants, memberships: memberships,
                                history: history, year: config.drawYear)
        history[year] = AnnualHistory(participants: participants, assignments: assignments)
        output("\(options.regenerateMatches ? "Regenerated" : "Generated") \(assignments.count) matches for \(config.drawYear).")
    } else {
        output("Using \(history[year]!.assignments.count) saved matches for \(config.drawYear).")
    }
    try validateHistory(history, personIDs: personIDs)
    let changed = try saveHistory(history, replacing: saved, to: historyURL)
    output(changed ? "History saved to history.json." : "History unchanged.")
    if options.showMatches {
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.name) })
        for giver in history[year]!.assignments.keys.sorted() {
            output("\(names[giver]!) → \(names[history[year]!.assignments[giver]!]!)")
        }
    }
    if options.noEmail {
        output("Sending disabled. Matches saved to history.json.")
        return
    }
    try runSending(at: directory, config: config, submit: submit,
                   checkSender: { try checkSender(config.senderEmail) }, confirm: confirm, output: output)
}

func main() throws {
    let options = try Options(Array(CommandLine.arguments.dropFirst()))
    let directory = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent()
    let mail = AppleMailSender(scriptURL: directory.appendingPathComponent("send.applescript"))
    try run(at: directory, options: options, submit: mail.submit, checkSender: mail.check)
}

#if !TESTING
do { try main() }
catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}
#endif
