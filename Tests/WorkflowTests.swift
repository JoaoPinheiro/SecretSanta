// Compiled with production functions and MatchingTests.swift; no real Mail calls.
func runWorkflowTests() throws {
    let fm = FileManager.default
    let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
    let temporary = fm.temporaryDirectory.appendingPathComponent("santa-workflow-\(UUID().uuidString)")
    try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temporary) }
    for name in ["people.csv", "groups.csv", "history.csv", "config.json"] {
        try fm.copyItem(at: fixtures.appendingPathComponent(name), to: temporary.appendingPathComponent(name))
    }
    func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw InputError(message) }
    }
    var submissions = 0
    var confirmations = 0
    let options = try Options([])
    try run(at: temporary, options: options, submit: { _ in submissions += 1 }, checkSender: { _ in }, confirm: { _ in
        confirmations += 1
        return true
    }, output: { _ in })
    try expect(submissions == 6 && confirmations == 1, "Expected one confirmed batch.")
    // A later run skips both confirmation and submission.
    try run(at: temporary, options: options, submit: { _ in submissions += 1 }, checkSender: { _ in },
            confirm: { _ in confirmations += 1; return true }, output: { _ in })
    try expect(submissions == 6 && confirmations == 1, "Completed run resent or prompted.")
    print("PASS: confirmed batch is not resent on reruns")

    try run(at: temporary, options: Options(["--no-email", "--regenerate-matches"]),
            submit: { _ in submissions += 1 }, checkSender: { _ in throw InputError("No-sending checked Mail.") },
            confirm: { _ in confirmations += 1; return true }, output: { _ in })
    try expect(submissions == 6 && confirmations == 1, "No-sending submitted or prompted.")
    print("PASS: no-email skips Mail checks, confirmation and submission")

    let config = Configuration(drawYear: 2028, senderEmail: "santa@example.com", eventNote: "Note {giver}",
                               subjectTemplate: "Gifts {year}", bodyTemplate: "Hi {giver}: {recipient}. {eventNote}")
    try expect(config.render(config.subjectTemplate) == "Gifts 2028", "Subject configuration ignored.")
    try expect(config.render(config.bodyTemplate, giver: "Zoë {recipient}", recipient: "李") == "Hi Zoë {recipient}: 李. Note {giver}",
               "Template expansion corrupted Unicode or interpreted substitutions recursively.")
    print("PASS: configured templates preserve literal names and Unicode")
    print("3 workflow tests passed.")
}

do { try runWorkflowTests() }
catch {
    FileHandle.standardError.write(Data("Workflow test failure: \(error)\n".utf8))
    exit(1)
}
