#if os(macOS)
import Foundation

extension WorkspaceStore {
    /// Managed worktrees are provisioned before this point. Resolve relative
    /// references against that final checkout, never the source repository.
    func prepareComposerReferences(for key: ConversationLocalStateKey, sessionID: String, sourceRoot: String, finalRoot: String) async throws {
        guard let draft = try localStateStore.state(for: key)?.composerDraft else { return }
        for token in draft.tokens {
            if let scope = token.workspacePath, !scope.isEmpty, scope != sourceRoot, scope != finalRoot {
                throw AgentInputRejection(code: "reference_scope_changed", message: "工作区已变更，请重新添加相关引用。")
            }
        }
        for reference in draft.fileReferences where reference.relativePath != nil {
            if let scope = reference.workspacePath, scope != sourceRoot, scope != finalRoot {
                throw AgentInputRejection(code: "reference_scope_changed", message: "工作区已变更，请重新添加相关文件。")
            }
        }
        let referenceFiles = ComposerMessageContent.referenceFiles(files: draft.fileReferences, attachments: draft.attachments, imagesAsPaths: draft.imagesAsPaths)
        let paths = referenceFiles.map { $0.relativePath ?? $0.path }
            + draft.tokens.compactMap { $0.item.relativePath }
        if !paths.isEmpty {
            do {
                try await client.composerValidatePaths(ComposerQuery(sessionID: sessionID, kind: "reference", query: "", revision: draft.revision), paths: Array(Set(paths)).sorted())
            } catch {
                throw Self.composerPathRejection(error)
            }
        }
        if sourceRoot != finalRoot {
            try localStateStore.updateState(for: key) { state in
                for index in state.composerDraft.fileReferences.indices {
                    guard let path = state.composerDraft.fileReferences[index].relativePath else { continue }
                    state.composerDraft.fileReferences[index].path = URL(fileURLWithPath: finalRoot).appendingPathComponent(path).path
                    state.composerDraft.fileReferences[index].workspacePath = finalRoot
                }
                for index in state.composerDraft.tokens.indices where state.composerDraft.tokens[index].workspacePath == sourceRoot {
                    state.composerDraft.tokens[index].workspacePath = finalRoot
                }
            }
        }
    }
    static func composerPathRejection(_ error: Error) -> AgentInputRejection {
        if let rejection = error as? AgentInputRejection { return rejection }
        if case RuntimeHTTPError.unexpectedStatus(let status, let body) = error {
            switch status {
            case 403, 40300:
                let message = body.contains("external paths")
                    ? "当前 Runtime 不允许引用工作区外的路径。请更新 Runtime，或将引用放到当前工作区后重新添加。"
                    : "引用路径超出当前工作区的访问范围，或会话工作区需要重新绑定。请检查引用与执行环境。"
                return AgentInputRejection(code: "reference_access_denied", message: message)
            case 409, 40900:
                return AgentInputRejection(code: "reference_unavailable", message: "有引用路径在执行环境中不存在或不可读。远程运行时请引用远程环境中的文件。")
            case 404, 40400, 501, 50100:
                return AgentInputRejection(code: "reference_validation_unsupported", message: "当前 Runtime 不支持文件引用校验，请更新 Runtime 后重试。")
            default: break
            }
        }
        return AgentInputRejection(code: "reference_validation_failed", message: "无法连接执行环境校验引用路径，请检查连接后重试。")
    }

}
#endif
