//
//  TranscriptCache.swift
//  AgentKit
//
//  Memoizes TurnTranscriptBuilder output per turn. Completed turns never
//  change, so scrolling through history stops re-parsing markdown and
//  rebuilding attributed strings on every body evaluation — only the live
//  (streaming) turn misses the cache.
//

import Foundation

@MainActor
final class TranscriptCache {

    static let shared = TranscriptCache()

    private final class Entry {
        let turn: ConversationTurn
        let state: TranscriptDocumentState
        let transcript: AttributedTranscript

        init(turn: ConversationTurn, state: TranscriptDocumentState, transcript: AttributedTranscript) {
            self.turn = turn
            self.state = state
            self.transcript = transcript
        }
    }

    /// Keyed by turn.id. NSCache handles memory-pressure eviction; the count
    /// limit bounds long multi-conversation sessions.
    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 256
        return cache
    }()

    /// Returns the memoized transcript when both the turn content and the
    /// expand/collapse state are unchanged. The turn comparison is cheap in
    /// the common case: unchanged payload strings share storage with the
    /// graph, so `==` short-circuits on pointer identity.
    func transcript(
        for turn: ConversationTurn,
        state: TranscriptDocumentState
    ) -> AttributedTranscript {
        let key = turn.id as NSString
        if let entry = cache.object(forKey: key),
           entry.state == state,
           entry.turn == turn {
            return entry.transcript
        }
        let transcript = TurnTranscriptBuilder.build(turn: turn, state: state)
        cache.setObject(Entry(turn: turn, state: state, transcript: transcript), forKey: key)
        return transcript
    }
}
