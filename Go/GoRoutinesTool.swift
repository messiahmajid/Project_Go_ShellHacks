import Foundation

/// A routine request from the voice model, for when the owner's wording wasn't
/// recognised locally. It resolves to the same `GoRoutineIntent` Go handles itself.
nonisolated struct GoRoutinesRequest: Equatable, Sendable {
    let operation: String?
    let name: String?
    let sourceQuote: String?

    init(_ arguments: [String: Any]?) {
        operation = arguments?["operation"] as? String
        name = (arguments?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        sourceQuote = arguments?["sourceQuote"] as? String
    }

    /// Listing changes nothing; every other operation must quote the owner.
    var needsOwnerWords: Bool { operation != "list" }

    /// The request as Go's own routine intent, its name matched to a saved routine.
    func intent(names: [String]) -> GoRoutineIntent? {
        switch operation {
        case "list": return .list
        case "deleteAll": return .deleteAll
        case "run", "walk", "delete":
            guard let name, !name.isEmpty else { return nil }
            guard let match = GoRoutine.match(GoRoutineIntent.trimmingFiller(name.lowercased()), among: names, fuzzy: true) else {
                return .unknown(name: name)
            }
            return operation == "run" ? .run(name: match) : operation == "walk" ? .walk(name: match) : .delete(name: match)
        default: return nil
        }
    }
}

nonisolated enum GoRoutinesTool {
    static let name = "go_routines"
    static let instructions = """

    Saved routines are Go's own feature, not something on the screen. For any request about them, however it is phrased (which routines are saved, run one, walk through one, delete one, delete all of them), call go_routines. Never use go_walkthrough, go_goal or screen actions for routines, and never say you can't manage them. Go speaks the result itself.
    """
    static var declaration: [String: Any] {
        ["name": name, "description": "List, run, walk through or delete the owner's saved routines (Go's own saved step sequences).",
         "parameters": ["type": "object", "properties": [
            "operation": ["type": "string", "enum": ["list", "run", "walk", "delete", "deleteAll"]],
            "name": ["type": "string", "description": "The routine's name as the owner said it (run, walk, delete)."],
            "sourceQuote": ["type": "string", "description": "Exact current owner words asking for this."]
         ], "required": ["operation"]]]
    }
}
