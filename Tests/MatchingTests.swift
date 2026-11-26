// Compiled with santa.swift by Tests/run.swift; inputs live in Tests/Fixtures.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}

func runMatchingTests() throws {
    func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw InputError(message) }
    }
    func rejects(_ body: () throws -> Void) throws {
        do { try body() }
        catch { return }
        throw InputError("Expected invalid assignments to be rejected.")
    }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    let data = try Data(contentsOf: directory.appendingPathComponent("matching.json"))
    let fixtures = try JSONDecoder().decode([String: [String: [String]]].self, from: data)
    func graph(_ name: String) -> [String: Set<String>] {
        fixtures[name]!.mapValues(Set.init)
    }
    // This independent checker uses just the supplied graph and the returned draw.
    func checkGraph(_ result: [String: String], _ graph: [String: Set<String>]) throws {
        try expect(Set(result.keys) == Set(graph.keys), "Missing giver.")
        try expect(Set(result.values) == Set(graph.keys), "Missing or repeated recipient.")
        for (giver, recipient) in result {
            try expect(graph[giver]!.contains(recipient), "Ineligible recipient.")
            try expect(giver != recipient && result[recipient] != giver, "Self or reciprocal match.")
        }
    }
    let (people, memberships, imports) = try loadInputs(at: directory)
    let pool = people.filter(\.active).map(\.id)
    let history = try mergeHistory(imports, into: [:], personIDs: Set(people.map(\.id)))
    var count = 0
    func test(_ name: String, _ body: () throws -> Void) throws {
        try body()
        count += 1
        print("PASS: \(name)")
    }

    try test("DFS restores state after failed branches") {
        let eligible = graph("backtracking")
        var backtracked = false
        for seed in 0..<100 {
            var random = SeededRandom(state: UInt64(seed))
            let result = findAssignments(eligible: eligible, using: &random)
            guard let assignments = result.assignments else { throw InputError("Feasible graph rejected.") }
            try checkGraph(assignments, eligible)
            backtracked = backtracked || result.backtracks > 0
        }
        try expect(backtracked, "Fixture never exercised backtracking.")
    }
    try test("randomized branches can produce different valid draws") {
        let ids = graph("backtracking").keys.sorted()
        let eligible = Dictionary(uniqueKeysWithValues: ids.map { ($0, Set(ids).subtracting([$0])) })
        var results = Set<String>()
        for seed in 0..<30 {
            var random = SeededRandom(state: UInt64(seed))
            guard let assignments = findAssignments(eligible: eligible, using: &random).assignments else {
                throw InputError("Unrestricted pool unexpectedly impossible.")
            }
            try checkGraph(assignments, eligible)
            results.insert(ids.map { "\($0):\(assignments[$0]!)" }.joined(separator: ","))
        }
        try expect(results.count > 1, "Random branch order did not vary results.")
    }
    try test("identical seeds reproduce a draw") {
        var first = SeededRandom(state: 17)
        var second = SeededRandom(state: 17)
        try expect(findAssignments(eligible: graph("backtracking"), using: &first).assignments ==
                   findAssignments(eligible: graph("backtracking"), using: &second).assignments,
                   "Seeded search is not reproducible.")
    }
    try test("reciprocal-only pool is impossible") {
        var random = SeededRandom(state: 1)
        try expect(findAssignments(eligible: graph("impossible"), using: &random).assignments == nil,
                   "Reciprocal pairs were allowed.")
    }
    try test("multiple cycles are permitted") {
        let eligible = graph("multipleCycles")
        var random = SeededRandom(state: 1)
        guard let result = findAssignments(eligible: eligible, using: &random).assignments else {
            throw InputError("Multiple cycles incorrectly rejected.")
        }
        try checkGraph(result, eligible)
    }
    try test("group and historical constraints hold across seeded draws") {
        let restrictions = try drawRestrictions(participants: pool, memberships: memberships, history: history, year: 2026)
        for seed in 0..<30 {
            var random = SeededRandom(state: UInt64(seed))
            guard let result = findAssignments(eligible: restrictions.eligible, using: &random).assignments else {
                throw InputError("Sample pool unexpectedly impossible.")
            }
            try checkGraph(result, restrictions.eligible)
            try validateAssignments(result, participants: pool, memberships: memberships,
                                    history: history, year: 2026)
        }
    }
    try test("last participation survives skipped years; future records ignored") {
        var historical = history
        historical["2025"]!.participants.removeAll { $0 == "alex" }
        historical["2025"]!.assignments.removeValue(forKey: "alex")
        historical["2025"]!.assignments = historical["2025"]!.assignments.filter { $0.value != "alex" }
        historical["2025"]!.assignments["ellis"] = "casey"
        historical["2030"] = history["2025"]
        try validateHistory(historical, personIDs: Set(people.map(\.id)))
        let restrictions = try drawRestrictions(participants: pool, memberships: [], history: historical, year: 2026)
        try expect(restrictions.eligible["alex"]!.contains("casey"), "Older recipient was not selected.")
        try expect(!restrictions.eligible["alex"]!.contains("drew"), "Last participation ignored.")
    }
    try test("overlapping group exclusions are not transitive") {
        let overlap = memberships + [GroupMembership(group: "bridge", personID: "blair"),
                                     GroupMembership(group: "bridge", personID: "casey")]
        let restrictions = try drawRestrictions(participants: pool, memberships: overlap, history: [:], year: 2026)
        try expect(!restrictions.eligible["blair"]!.contains("alex"), "First group ignored after adding another membership.")
        try expect(!restrictions.eligible["blair"]!.contains("casey"), "Shared group ignored.")
        try expect(!restrictions.eligible["casey"]!.contains("blair"), "Exclusion is not mutual.")
        try expect(restrictions.eligible["alex"]!.contains("casey"), "Groups incorrectly made transitive.")
    }
    try test("previous recipient outside pool needs no special handling") {
        let subset = pool.filter { $0 != "casey" }
        let restrictions = try drawRestrictions(participants: subset, memberships: [], history: history, year: 2026)
        try expect(restrictions.eligible["alex"] == Set(subset).subtracting(["alex"]),
                   "Absent previous recipient blocked another participant.")
    }
    try test("independent validation catches invalid assignments") {
        let valid = ["a": "b", "b": "c", "c": "a"]
        try validateAssignments(valid, participants: ["a", "b", "c"], memberships: [], history: [:], year: 2026)
        for invalid in [["a": "a", "b": "c", "c": "b"],
                        ["a": "b", "b": "a", "c": "d", "d": "c"],
                        ["a": "b", "b": "c", "c": "b"]] {
            try rejects {
                try validateAssignments(invalid, participants: invalid.keys.sorted(), memberships: [], history: [:], year: 2026)
            }
        }
        try rejects {
            try validateAssignments(valid, participants: ["a", "b", "c"],
                memberships: [GroupMembership(group: "group", personID: "a"), GroupMembership(group: "group", personID: "b")],
                history: [:], year: 2026)
        }
        try rejects {
            try validateAssignments(valid, participants: ["a", "b", "c"], memberships: [],
                history: ["2024": AnnualHistory(participants: ["a", "b", "c"], assignments: valid)], year: 2026)
        }
    }
    print("\(count) matching tests passed.")
}

do { try runMatchingTests() }
catch {
    FileHandle.standardError.write(Data("Matching test failure: \(error)\n".utf8))
    exit(1)
}
