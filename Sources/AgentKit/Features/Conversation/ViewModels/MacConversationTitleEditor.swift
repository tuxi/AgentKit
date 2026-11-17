#if os(macOS)
import Foundation
import Observation

@MainActor
@Observable
final class MacConversationTitleEditor {
    var text = ""
    private(set) var target: ConversationRef?
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var focusRevision = 0

    func begin(_ conversation: ConversationRef) {
        guard !isSaving else { return }
        target = conversation
        text = conversation.name ?? ""
        errorMessage = nil
        focusRevision += 1
    }

    func cancel() {
        guard !isSaving else { return }
        target = nil
        errorMessage = nil
    }

    func dismissError() {
        errorMessage = nil
        focusRevision += 1
    }

    func save(rename: (ConversationRef, String) async -> ConversationRef?, failure: () -> String) async {
        guard let target, !isSaving, errorMessage == nil else { return }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorMessage = "名称不能为空。"; return }
        guard !name.contains(where: \.isNewline) else { errorMessage = "名称不能包含换行。"; return }
        if name == target.name { cancel(); return }
        isSaving = true
        defer { isSaving = false }
        if await rename(target, name) != nil {
            self.target = nil
            errorMessage = nil
        } else {
            errorMessage = failure()
        }
    }
}
#endif
