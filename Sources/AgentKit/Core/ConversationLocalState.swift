//
//  ConversationLocalState.swift
//  AgentKit
//
//  Device-local, GUI-owned persistence for composer drafts, model choices and
//  attention/read cursors. Runtime lifecycle facts never live in this store.
//

import Foundation
import SQLite3

public enum ConversationLocalStateKey: Hashable, Sendable {
    case draft(UUID)
    case session(String)

    public var storageKey: String {
        switch self {
        case .draft(let id): return "draft:\(id.uuidString.lowercased())"
        case .session(let id): return "session:\(id)"
        }
    }

    public var draftID: UUID? {
        guard case .draft(let id) = self else { return nil }
        return id
    }
}

public struct DraftAttachmentReference: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var resourceURI: String

    public init(id: String, displayName: String, resourceURI: String) {
        self.id = id
        self.displayName = displayName
        self.resourceURI = resourceURI
    }
}

public struct ComposerDraft: Codable, Sendable, Equatable {
    public var text: String
    public var attachments: [DraftAttachmentReference]
    public var workspaceID: String?
    public var workspacePath: String?
    public var workspaceBranch: String?
    public var executionPolicy: String?
    public var wantsManagedWorktree: Bool
    public var managedWorktreeBaseRef: String?
    public var managedWorktreeSuggestedName: String?
    public var clientRequestID: String?
    public var updatedAt: Date

    public init(
        text: String = "",
        attachments: [DraftAttachmentReference] = [],
        workspaceID: String? = nil,
        workspacePath: String? = nil,
        workspaceBranch: String? = nil,
        executionPolicy: String? = nil,
        wantsManagedWorktree: Bool = false,
        managedWorktreeBaseRef: String? = nil,
        managedWorktreeSuggestedName: String? = nil,
        clientRequestID: String? = nil,
        updatedAt: Date = .now
    ) {
        self.text = text
        self.attachments = attachments
        self.workspaceID = workspaceID
        self.workspacePath = workspacePath
        self.workspaceBranch = workspaceBranch
        self.executionPolicy = executionPolicy
        self.wantsManagedWorktree = wantsManagedWorktree
        self.managedWorktreeBaseRef = managedWorktreeBaseRef
        self.managedWorktreeSuggestedName = managedWorktreeSuggestedName
        self.clientRequestID = clientRequestID
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case text, attachments, workspaceID, workspacePath, workspaceBranch
        case executionPolicy, wantsManagedWorktree, managedWorktreeBaseRef
        case managedWorktreeSuggestedName, clientRequestID, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        attachments = try values.decodeIfPresent([DraftAttachmentReference].self, forKey: .attachments) ?? []
        workspaceID = try values.decodeIfPresent(String.self, forKey: .workspaceID)
        workspacePath = try values.decodeIfPresent(String.self, forKey: .workspacePath)
        workspaceBranch = try values.decodeIfPresent(String.self, forKey: .workspaceBranch)
        executionPolicy = try values.decodeIfPresent(String.self, forKey: .executionPolicy)
        wantsManagedWorktree = try values.decodeIfPresent(Bool.self, forKey: .wantsManagedWorktree) ?? false
        managedWorktreeBaseRef = try values.decodeIfPresent(String.self, forKey: .managedWorktreeBaseRef)
        managedWorktreeSuggestedName = try values.decodeIfPresent(String.self, forKey: .managedWorktreeSuggestedName)
        clientRequestID = try values.decodeIfPresent(String.self, forKey: .clientRequestID)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}

public struct ConversationLocalState: Codable, Sendable, Equatable {
    public var composerDraft: ComposerDraft
    public var selectedModelID: String?
    public var recentModelIDs: [String]
    public var lastReadSequence: Int64
    public var lastSeenTerminalSequence: Int64
    public var lastNotifiedTerminalSequence: Int64
    public var lastNotifiedApprovalSequence: Int64
    public var updatedAt: Date

    public init(
        composerDraft: ComposerDraft = ComposerDraft(),
        selectedModelID: String? = nil,
        recentModelIDs: [String] = [],
        lastReadSequence: Int64 = 0,
        lastSeenTerminalSequence: Int64 = 0,
        lastNotifiedTerminalSequence: Int64 = 0,
        lastNotifiedApprovalSequence: Int64 = 0,
        updatedAt: Date = .now
    ) {
        self.composerDraft = composerDraft
        self.selectedModelID = selectedModelID
        self.recentModelIDs = recentModelIDs
        self.lastReadSequence = lastReadSequence
        self.lastSeenTerminalSequence = lastSeenTerminalSequence
        self.lastNotifiedTerminalSequence = lastNotifiedTerminalSequence
        self.lastNotifiedApprovalSequence = lastNotifiedApprovalSequence
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case composerDraft, selectedModelID, recentModelIDs, lastReadSequence
        case lastSeenTerminalSequence, lastNotifiedTerminalSequence
        case lastNotifiedApprovalSequence, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        composerDraft = try values.decodeIfPresent(ComposerDraft.self, forKey: .composerDraft) ?? ComposerDraft()
        selectedModelID = try values.decodeIfPresent(String.self, forKey: .selectedModelID)
        recentModelIDs = try values.decodeIfPresent([String].self, forKey: .recentModelIDs) ?? []
        lastReadSequence = try values.decodeIfPresent(Int64.self, forKey: .lastReadSequence) ?? 0
        lastSeenTerminalSequence = try values.decodeIfPresent(Int64.self, forKey: .lastSeenTerminalSequence) ?? 0
        lastNotifiedTerminalSequence = try values.decodeIfPresent(Int64.self, forKey: .lastNotifiedTerminalSequence) ?? 0
        lastNotifiedApprovalSequence = try values.decodeIfPresent(Int64.self, forKey: .lastNotifiedApprovalSequence) ?? 0
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}

public protocol ConversationLocalStateStore: Sendable {
    func state(for key: ConversationLocalStateKey) throws -> ConversationLocalState?
    func save(_ state: ConversationLocalState, for key: ConversationLocalStateKey) throws
    func updateState(
        for key: ConversationLocalStateKey,
        _ update: @Sendable (inout ConversationLocalState) -> Void
    ) throws
    func latestDraft() throws -> (id: UUID, state: ConversationLocalState)?
    func migrateDraft(_ draftID: UUID, to sessionID: String) throws
    func removeState(for key: ConversationLocalStateKey) throws
    func flush() throws

    var hasEstablishedAttentionBaseline: Bool { get }
    func establishAttentionBaseline() throws
}

public enum ConversationLocalStateStoreError: Error, LocalizedError, Sendable {
    case sqlite(String)
    case invalidDraftKey(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message): return "无法保存会话本地状态：\(message)"
        case .invalidDraftKey(let key): return "无效的本地草稿标识：\(key)"
        }
    }
}

/// SQLite-backed production store. A single locked connection keeps synchronous
/// reads tiny enough for model/attention compatibility APIs while WAL allows the
/// Runtime database and this GUI-owned database to evolve independently.
public final class SQLiteConversationLocalStateStore: ConversationLocalStateStore, @unchecked Sendable {
    public static let shared = SQLiteConversationLocalStateStore()

    private static let baselineKey = "attention-baseline-v1"
    private static let migratedDraftPrefix = "migrated-draft:"

    public let databaseURL: URL

    private let lock = NSLock()
    private var database: OpaquePointer?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(databaseURL: URL = SQLiteConversationLocalStateStore.defaultDatabaseURL()) {
        self.databaseURL = databaseURL
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let appNamespace = Bundle.main.bundleIdentifier ?? "AgentKit"
        return base
            .appendingPathComponent(appNamespace, isDirectory: true)
            .appendingPathComponent("conversation-local-state-v1.sqlite", isDirectory: false)
    }

    public func state(for key: ConversationLocalStateKey) throws -> ConversationLocalState? {
        try lock.withLock {
            let db = try openLocked()
            return try readLocked(key.storageKey, db: db)
        }
    }

    public func save(_ state: ConversationLocalState, for key: ConversationLocalStateKey) throws {
        try lock.withLock {
            let db = try openLocked()
            guard try !isMigratedDraftLocked(key, db: db) else { return }
            var value = state
            value.updatedAt = .now
            value.composerDraft.updatedAt = value.updatedAt
            try writeLocked(value, key: key.storageKey, db: db)
        }
    }

    public func updateState(
        for key: ConversationLocalStateKey,
        _ update: @Sendable (inout ConversationLocalState) -> Void
    ) throws {
        try lock.withLock {
            let db = try openLocked()
            guard try !isMigratedDraftLocked(key, db: db) else { return }
            var value = try readLocked(key.storageKey, db: db) ?? ConversationLocalState()
            update(&value)
            value.updatedAt = .now
            value.composerDraft.updatedAt = value.updatedAt
            try writeLocked(value, key: key.storageKey, db: db)
        }
    }

    public func latestDraft() throws -> (id: UUID, state: ConversationLocalState)? {
        try lock.withLock {
            let db = try openLocked()
            let sql = "SELECT state_key, payload FROM local_state WHERE state_key LIKE 'draft:%' ORDER BY updated_at DESC LIMIT 1"
            let statement = try prepareLocked(sql, db: db)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let key = String(cString: sqlite3_column_text(statement, 0))
            guard let rawID = key.split(separator: ":", maxSplits: 1).last,
                  let id = UUID(uuidString: String(rawID)) else {
                throw ConversationLocalStateStoreError.invalidDraftKey(key)
            }
            let state = try decodeColumn(statement, index: 1)
            return (id, state)
        }
    }

    public func migrateDraft(_ draftID: UUID, to sessionID: String) throws {
        try lock.withLock {
            let db = try openLocked()
            try executeLocked("BEGIN IMMEDIATE", db: db)
            do {
                let draftKey = ConversationLocalStateKey.draft(draftID).storageKey
                let sessionKey = ConversationLocalStateKey.session(sessionID).storageKey
                let draft = try readLocked(draftKey, db: db)
                let existing = try readLocked(sessionKey, db: db)
                if let draft {
                    try writeLocked(merge(draft: draft, session: existing), key: sessionKey, db: db)
                }
                try deleteLocked(draftKey, db: db)
                try setMetadataLocked(Self.migratedDraftPrefix + draftID.uuidString.lowercased(), value: "1", db: db)
                try executeLocked("COMMIT", db: db)
            } catch {
                try? executeLocked("ROLLBACK", db: db)
                throw error
            }
        }
    }

    public func removeState(for key: ConversationLocalStateKey) throws {
        try lock.withLock {
            let db = try openLocked()
            try deleteLocked(key.storageKey, db: db)
        }
    }

    public func flush() throws {
        try lock.withLock {
            let db = try openLocked()
            guard sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil) == SQLITE_OK else {
                throw sqliteError(db)
            }
        }
    }

    public var hasEstablishedAttentionBaseline: Bool {
        (try? lock.withLock {
            let db = try openLocked()
            return try metadataLocked(Self.baselineKey, db: db) == "1"
        }) ?? false
    }

    public func establishAttentionBaseline() throws {
        try lock.withLock {
            let db = try openLocked()
            try setMetadataLocked(Self.baselineKey, value: "1", db: db)
        }
    }

    private func openLocked() throws -> OpaquePointer {
        if let database { return database }
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &connection, flags, nil) == SQLITE_OK,
              let connection else {
            defer { if let connection { sqlite3_close(connection) } }
            throw sqliteError(connection)
        }
        database = connection
        do {
            try executeLocked("PRAGMA journal_mode=WAL", db: connection)
            try executeLocked("PRAGMA synchronous=NORMAL", db: connection)
            try executeLocked("PRAGMA busy_timeout=5000", db: connection)
            try executeLocked("CREATE TABLE IF NOT EXISTS local_state (state_key TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, updated_at REAL NOT NULL)", db: connection)
            try executeLocked("CREATE TABLE IF NOT EXISTS local_metadata (metadata_key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)", db: connection)
            #if os(iOS)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: databaseURL.path
            )
            #endif
            return connection
        } catch {
            sqlite3_close(connection)
            database = nil
            throw error
        }
    }

    private func readLocked(_ key: String, db: OpaquePointer) throws -> ConversationLocalState? {
        let statement = try prepareLocked("SELECT payload FROM local_state WHERE state_key = ?", db: db)
        defer { sqlite3_finalize(statement) }
        bindText(key, to: 1, statement: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return try decodeColumn(statement, index: 0)
        case SQLITE_DONE: return nil
        default: throw sqliteError(db)
        }
    }

    private func writeLocked(_ state: ConversationLocalState, key: String, db: OpaquePointer) throws {
        let data = try encoder.encode(state)
        let statement = try prepareLocked(
            "INSERT INTO local_state(state_key, payload, updated_at) VALUES(?, ?, ?) ON CONFLICT(state_key) DO UPDATE SET payload=excluded.payload, updated_at=excluded.updated_at",
            db: db
        )
        defer { sqlite3_finalize(statement) }
        bindText(key, to: 1, statement: statement)
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
        sqlite3_bind_double(statement, 3, state.updatedAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(db) }
    }

    private func deleteLocked(_ key: String, db: OpaquePointer) throws {
        let statement = try prepareLocked("DELETE FROM local_state WHERE state_key = ?", db: db)
        defer { sqlite3_finalize(statement) }
        bindText(key, to: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(db) }
    }

    private func metadataLocked(_ key: String, db: OpaquePointer) throws -> String? {
        let statement = try prepareLocked("SELECT value FROM local_metadata WHERE metadata_key = ?", db: db)
        defer { sqlite3_finalize(statement) }
        bindText(key, to: 1, statement: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return String(cString: sqlite3_column_text(statement, 0))
        case SQLITE_DONE: return nil
        default: throw sqliteError(db)
        }
    }

    private func setMetadataLocked(_ key: String, value: String, db: OpaquePointer) throws {
        let statement = try prepareLocked(
            "INSERT INTO local_metadata(metadata_key, value) VALUES(?, ?) ON CONFLICT(metadata_key) DO UPDATE SET value=excluded.value",
            db: db
        )
        defer { sqlite3_finalize(statement) }
        bindText(key, to: 1, statement: statement)
        bindText(value, to: 2, statement: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(db) }
    }

    private func isMigratedDraftLocked(_ key: ConversationLocalStateKey, db: OpaquePointer) throws -> Bool {
        guard let id = key.draftID else { return false }
        return try metadataLocked(Self.migratedDraftPrefix + id.uuidString.lowercased(), db: db) == "1"
    }

    private func decodeColumn(_ statement: OpaquePointer?, index: Int32) throws -> ConversationLocalState {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let pointer = sqlite3_column_blob(statement, index) else {
            return ConversationLocalState()
        }
        return try decoder.decode(ConversationLocalState.self, from: Data(bytes: pointer, count: count))
    }

    private func prepareLocked(_ sql: String, db: OpaquePointer) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(db)
        }
        return statement
    }

    private func executeLocked(_ sql: String, db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw sqliteError(db) }
    }

    private func bindText(_ value: String, to index: Int32, statement: OpaquePointer?) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
    }

    private func sqliteError(_ db: OpaquePointer?) -> ConversationLocalStateStoreError {
        ConversationLocalStateStoreError.sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database")
    }

    private func merge(
        draft: ConversationLocalState,
        session: ConversationLocalState?
    ) -> ConversationLocalState {
        guard var session else { return draft }
        session.composerDraft = draft.composerDraft
        session.selectedModelID = draft.selectedModelID ?? session.selectedModelID
        session.recentModelIDs = unique(draft.recentModelIDs + session.recentModelIDs)
        session.lastReadSequence = max(session.lastReadSequence, draft.lastReadSequence)
        session.lastSeenTerminalSequence = max(session.lastSeenTerminalSequence, draft.lastSeenTerminalSequence)
        session.lastNotifiedTerminalSequence = max(session.lastNotifiedTerminalSequence, draft.lastNotifiedTerminalSequence)
        session.lastNotifiedApprovalSequence = max(session.lastNotifiedApprovalSequence, draft.lastNotifiedApprovalSequence)
        session.updatedAt = .now
        return session
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

/// Deterministic injectable store for unit tests and hosts that provide their own
/// encrypted persistence later.
public final class InMemoryConversationLocalStateStore: ConversationLocalStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ConversationLocalStateKey: ConversationLocalState] = [:]
    private var migratedDrafts = Set<UUID>()
    private var baseline = false

    public init() {}

    public func state(for key: ConversationLocalStateKey) throws -> ConversationLocalState? {
        lock.withLock { values[key] }
    }

    public func save(_ state: ConversationLocalState, for key: ConversationLocalStateKey) throws {
        lock.withLock {
            guard !isMigratedDraft(key) else { return }
            var value = state
            value.updatedAt = .now
            value.composerDraft.updatedAt = value.updatedAt
            values[key] = value
        }
    }

    public func updateState(
        for key: ConversationLocalStateKey,
        _ update: @Sendable (inout ConversationLocalState) -> Void
    ) throws {
        lock.withLock {
            guard !isMigratedDraft(key) else { return }
            var value = values[key] ?? ConversationLocalState()
            update(&value)
            value.updatedAt = .now
            value.composerDraft.updatedAt = value.updatedAt
            values[key] = value
        }
    }

    public func latestDraft() throws -> (id: UUID, state: ConversationLocalState)? {
        lock.withLock {
            values.compactMap { key, value -> (UUID, ConversationLocalState)? in
                guard case .draft(let id) = key else { return nil }
                return (id, value)
            }.max { $0.1.updatedAt < $1.1.updatedAt }
        }
    }

    public func migrateDraft(_ draftID: UUID, to sessionID: String) throws {
        lock.withLock {
            let draftKey = ConversationLocalStateKey.draft(draftID)
            if let draft = values[draftKey] {
                var session = values[.session(sessionID)] ?? ConversationLocalState()
                session.composerDraft = draft.composerDraft
                session.selectedModelID = draft.selectedModelID ?? session.selectedModelID
                var seen = Set<String>()
                session.recentModelIDs = (draft.recentModelIDs + session.recentModelIDs).filter {
                    seen.insert($0).inserted
                }
                session.lastReadSequence = max(session.lastReadSequence, draft.lastReadSequence)
                session.lastSeenTerminalSequence = max(session.lastSeenTerminalSequence, draft.lastSeenTerminalSequence)
                session.lastNotifiedTerminalSequence = max(
                    session.lastNotifiedTerminalSequence,
                    draft.lastNotifiedTerminalSequence
                )
                session.lastNotifiedApprovalSequence = max(
                    session.lastNotifiedApprovalSequence,
                    draft.lastNotifiedApprovalSequence
                )
                values[.session(sessionID)] = session
            }
            values.removeValue(forKey: draftKey)
            migratedDrafts.insert(draftID)
        }
    }

    public func removeState(for key: ConversationLocalStateKey) throws {
        _ = lock.withLock { values.removeValue(forKey: key) }
    }

    public func flush() throws {}

    public var hasEstablishedAttentionBaseline: Bool { lock.withLock { baseline } }
    public func establishAttentionBaseline() throws { lock.withLock { baseline = true } }

    private func isMigratedDraft(_ key: ConversationLocalStateKey) -> Bool {
        guard case .draft(let id) = key else { return false }
        return migratedDrafts.contains(id)
    }
}
