// Compiled with production functions by Tests/run.swift. No Mail app is invoked.
func runMailTests() throws {
    let fm = FileManager.default
    let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
    let temporary = fm.temporaryDirectory.appendingPathComponent("santa-mail-tests-\(UUID().uuidString)")
    try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temporary) }
    let historyURL = temporary.appendingPathComponent("history.json")
    let dedicatedSender = "santa@example.com"
    let year = 2023
    func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw InputError(message) }
    }
    func rejects(_ expected: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch {
            try expect(String(describing: error).contains(expected), "Unexpected error: \(error)")
            return
        }
        throw InputError("Expected rejection: \(expected)")
    }
    func reset() throws {
        for name in ["people.csv", "history.json", "history.json.bak"] {
            let url = temporary.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        try fm.copyItem(at: fixtures.appendingPathComponent("people.csv"), to: temporary.appendingPathComponent("people.csv"))
        try fm.copyItem(at: fixtures.appendingPathComponent("saved-history.json"), to: historyURL)
    }
    func history() throws -> History {
        try JSONDecoder().decode(History.self, from: Data(contentsOf: historyURL))
    }
    func write(_ history: History) throws {
        try JSONEncoder().encode(history).write(to: historyURL)
    }
    func editContacts(_ old: String, _ new: String) throws {
        let url = temporary.appendingPathComponent("people.csv")
        let text = try String(contentsOf: url, encoding: .utf8)
        try expect(text.contains(old), "Missing fixture text: \(old)")
        try text.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
    }
    func messages(sender: String = "santa@example.com") throws -> [PreparedEmail] {
        try prepareEmails(people: loadPeople(at: temporary, requireActiveEmails: false),
                          history: history(), year: year, sender: sender)
    }
    var count = 0
    func test(_ name: String, _ body: () throws -> Void) throws {
        try reset()
        try body()
        count += 1
        print("PASS: \(name)")
    }

    try test("messages use saved assignments and dedicated sender") {
        let pending = try messages()
        try expect(pending.map(\.giverID) == ["blair", "casey"], "Previously submitted giver was not skipped.")
        let people = try loadPeople(at: temporary)
        let contacts = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        let saved = try history()[String(year)]!
        for message in pending {
            let giver = contacts[message.giverID]!
            let recipient = contacts[saved.assignments[message.giverID]!]!
            try expect(message.sender == dedicatedSender && message.address == giver.email, "Incorrect sender or destination.")
            try expect(message.subject.contains(String(year)), "Year missing from subject.")
            try expect(message.body.contains("Hi \(giver.name),") && message.body.contains("gift for \(recipient.name)."), "Incorrect personalized message.")
        }
    }
    try test("current contacts are used even for inactive saved participants") {
        try editContacts("blair,Blair,blair@example.com,+490001234,true", "blair,Blair Updated,new@example.com,+490001234,false")
        // Already submitted participants do not need an address for this batch.
        try editContacts("alex,Alex,alex@example.com,,true", "alex,Alex,,,true")
        let pending = try messages()
        try expect(pending[0].address == "new@example.com" && pending[0].body.contains("Hi Blair Updated,"), "Current contact was ignored.")
    }
    try test("failed account check stops before confirmation or submission") {
        let before = try Data(contentsOf: historyURL)
        var confirmationRequested = false
        var called = false
        try rejects("Account unavailable") {
            try runSending(at: temporary, year: year, sender: dedicatedSender,
                           submit: { _ in called = true }, checkSender: { throw InputError("Account unavailable") },
                           confirm: { _ in confirmationRequested = true; return true }, output: { _ in })
        }
        try expect(!confirmationRequested && !called, "Failed account check continued sending.")
        try expect(Data(contentsOf: historyURL) == before, "Account check changed history.")
    }
    try test("preview and decline never invoke sender or change history") {
        let before = try Data(contentsOf: historyURL)
        var called = false
        try runSending(at: temporary, year: year, sender: dedicatedSender,
                       submit: { _ in called = true }, confirm: { _ in false }, output: { _ in })
        try expect(!called, "Declined sending called sender.")
        try expect(Data(contentsOf: historyURL) == before, "Preview or decline changed history.")
    }
    try test("confirmation follows previews; progress saves after each submission") {
        var output: [String] = []
        var submitted: [PreparedEmail] = []
        var confirmed = false
        try runSending(at: temporary, year: year, sender: dedicatedSender, submit: { message in
            try expect(confirmed, "Sender ran without confirmation.")
            let progress = try history()[String(year)]!.submittedEmails
            try expect(Set(progress) == Set(["alex"] + submitted.map(\.giverID)), "Previous success not saved before next send.")
            submitted.append(message)
        }, confirm: { prompt in
            confirmed = prompt.contains(dedicatedSender) && prompt.contains("2 messages")
                && output.contains { $0.contains("To: blair@example.com") }
                && output.contains { $0.contains("To: casey@example.com") }
            return confirmed
        }, output: { output.append($0) })
        try expect(submitted.map(\.giverID) == ["blair", "casey"], "Wrong batch submitted.")
        for message in submitted {
            try expect(!message.body.isEmpty, "Submitted email has no body.")
            try expect(!output.joined(separator: "\n").contains(message.body), "Send preview revealed an email body.")
        }
        try expect(Set(try history()[String(year)]!.submittedEmails) == Set(["alex", "blair", "casey"]), "Submissions not recorded.")
        var rerunCalls = 0
        try runSending(at: temporary, year: year, sender: dedicatedSender,
                       submit: { _ in rerunCalls += 1 }, confirm: { _ in true }, output: { _ in })
        try expect(rerunCalls == 0, "Rerun duplicated a submission.")
    }
    try test("invalid pending address blocks the entire batch") {
        try editContacts("casey@example.com", "invalid-address")
        let before = try Data(contentsOf: historyURL)
        var calls = 0
        try rejects("needs a valid email address") {
            try runSending(at: temporary, year: year, sender: dedicatedSender,
                           submit: { _ in calls += 1 }, confirm: { _ in true }, output: { _ in })
        }
        try expect(calls == 0 && Data(contentsOf: historyURL) == before, "Invalid batch submitted or changed history.")
        try rejects("dedicated senderEmail") { _ = try messages(sender: "") }
    }
    try test("submission failure stops the batch and preserves earlier successes") {
        var saved = try history()
        saved[String(year)]!.submittedEmails = []
        try write(saved)
        var calls: [String] = []
        try rejects("Check Mail before retrying") {
            try runSending(at: temporary, year: year, sender: dedicatedSender, submit: { message in
                calls.append(message.giverID)
                if calls.count == 2 { throw InputError("Simulated submission failure") }
            }, confirm: { _ in true }, output: { _ in })
        }
        try expect(calls == ["alex", "blair"], "Batch continued after failure.")
        try expect(try history()[String(year)]!.submittedEmails == ["alex"], "Failed submission marked successful.")
        try expect(try messages().map(\.giverID) == ["blair", "casey"], "Pending recipients were lost.")
    }
    try test("progress-save failure stops before another submission") {
        let before = try Data(contentsOf: historyURL)
        try fm.createDirectory(at: historyURL.appendingPathExtension("bak"), withIntermediateDirectories: false)
        var calls = 0
        try rejects("Check Mail before retrying") {
            try runSending(at: temporary, year: year, sender: dedicatedSender,
                           submit: { _ in calls += 1 }, confirm: { _ in true }, output: { _ in })
        }
        try expect(calls == 1, "Batch continued after progress-save failure.")
        try expect(Data(contentsOf: historyURL) == before, "Failed progress save changed history.")
    }
    try test("sending rejects self and reciprocal matches") {
        var saved = try history()
        saved[String(year)]!.assignments = ["alex": "blair", "blair": "alex", "casey": "casey"]
        try write(saved)
        try rejects("self-assignment or reciprocal pair") { _ = try messages() }
    }
    try test("AppleScript adapter preserves literal message arguments") {
        let adapter = AppleMailSender(scriptURL: fixtures.appendingPathComponent("check-mail-arguments.applescript"))
        try adapter.submit(PreparedEmail(giverID: "alex", sender: dedicatedSender,
                                        address: "recipient@example.com", subject: "Secret Santa — \"family\"",
                                        body: "Hi \"Alex\",\nLiteral $(echo unsafe); `echo unsafe` & backslash: \\"))
    }
    try test("AppleScript adapter checks responses and propagates failures") {
        let adapter = AppleMailSender(scriptURL: fixtures.appendingPathComponent("fake-send.applescript"))
        try adapter.check(sender: dedicatedSender)
        try rejects("Dedicated account not found") { try adapter.check(sender: "missing@example.com") }
        for address in ["failure@example.com", "unconfirmed@example.com"] {
            try rejects("Apple Mail helper failed") {
                try adapter.submit(PreparedEmail(giverID: "alex", sender: dedicatedSender,
                                                address: address, subject: "Test", body: "Test"))
            }
        }
        let missing = AppleMailSender(scriptURL: temporary.appendingPathComponent("absent.applescript"))
        try rejects("Cannot read Apple Mail helper") { try missing.check(sender: dedicatedSender) }
    }
    print("\(count) mail tests passed; no real emails sent.")
}

do { try runMailTests() }
catch {
    FileHandle.standardError.write(Data("Mail test failure: \(error)\n".utf8))
    exit(1)
}
