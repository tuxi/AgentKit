//
//  TurnProjectionCache.swift
//  AgentKit
//
//  Incremental turn projection for RuntimeEngine.
//
//  Full projection rebuilds every turn on every snapshot — O(total content) per
//  event, O(n²) across a long conversation. This cache re-projects only the
//  turns that actually changed, reusing:
//    - per-node projected ExecutionNodes (so completed tool nodes are not
//      re-projected / re-compiled on every event), and
//    - per-turn ConversationTurn values (so unchanged turns keep their
//      contentVersion and skip re-folding).
//
//  Change detection does NOT rely on the reducer's returned node list (some
//  handlers finalize nodes without reporting them, e.g. turnFinished). It uses
//  ExecutionGraph.nodeRevisions / changedNodeIDs, which record every mutation
//  at the graph boundary.
//

import Foundation

/// Incremental turn projection cache. Owned by `RuntimeEngine` (actor), so it
/// is only ever mutated on the engine actor.
struct TurnProjectionCache {
    private let timelineProjection: TimelineProjection

    init(mergePolicy: MergePolicy = DefaultMergePolicy()) {
        self.timelineProjection = TimelineProjection(mergePolicy: mergePolicy)
    }

    // MARK: - State

    /// Turn UID (first node's id) → the turn's node IDs in graph order.
    private var turnNodeIDs: [String: [NodeID]] = [:]
    /// Turn UIDs in graph (append) order.
    private var orderedTurnUIDs: [String] = []
    /// Node ID → owning turn UID.
    private var nodeToTurn: [NodeID: String] = [:]
    /// Turn UID → last projected (merged) ExecutionNodes, in graph order.
    private var turnMergedNodes: [String: [ExecutionNode]] = [:]
    /// Turn UID → last projected ConversationTurn.
    private var cachedTurns: [String: ConversationTurn] = [:]
    /// Turn UID → wall-clock boundaries used by the last projection. A change
    /// (e.g. the terminal `turn_finished` timestamp arriving for a turn whose
    /// content did not change) must re-project the turn even though its blocks
    /// are byte-identical.
    private var projectedWallClock: [String: TurnWallClock] = [:]
    /// Turn UID → content version (bumped only when the turn's content changes).
    private var contentVersions: [String: UInt64] = [:]
    /// Node ID → last projected ExecutionNode (per-node projection cache).
    private var nodeProjections: [NodeID: ExecutionNode] = [:]
    /// Node ID → graph revision the cached projection was built from.
    private var nodeProjectionRevisions: [NodeID: UInt64] = [:]
    /// Turn UID that was the last turn at last projection (for isLive flips).
    private var lastProjectedLastTurnUID: String?
    /// Snapshot-level live flag at last projection.
    private var lastProjectedIsLive = false
    /// Cached assembled timeline (rebuilt only when a turn changed).
    private var assembledTimeline: [ExecutionNode]?
    private var isSeeded = false
    /// Protocol turn id → projection UID, learned while projecting. Needed to
    /// map a turn-level diffstat (keyed by protocol id) back onto its turn.
    private var uidByServerTurnID: [String: String] = [:]
    /// `graph.turnChangesRevision` at last projection. A diffstat can arrive on
    /// a terminal event that touches no node at all, so node revisions alone do
    /// not dirty the turn.
    private var projectedChangesRevision: UInt64 = 0

    // MARK: - API

    /// Incrementally project the graph. Consumes and clears the graph's
    /// changed-node set. First call (or after `reset`) performs a full seed.
    mutating func project(
        graph: inout ExecutionGraph,
        isLive: Bool,
        wallClock: [String: TurnWallClock] = [:]
    ) -> (timeline: [ExecutionNode], turns: [ConversationTurn]) {
        if !isSeeded {
            return seed(graph: &graph, isLive: isLive, wallClock: wallClock)
        }

        let changed = graph.consumeChangedNodeIDs()
        var dirtyTurnIDs = Set<String>()

        // 1. Map changed nodes to their owning turn. New nodes are assigned to
        //    the current last turn (or start a new turn when userInput), in
        //    graph order — consumeChangedNodeIDs already returns them sorted.
        for nodeID in changed {
            if let existing = nodeToTurn[nodeID] {
                dirtyTurnIDs.insert(existing)
                continue
            }
            guard let node = graph.nodes[nodeID] else {
                // Node was removed before ever being mapped.
                continue
            }
            if node.kind == .userInput {
                let uid = node.id
                turnNodeIDs[uid] = [uid]
                orderedTurnUIDs.append(uid)
                nodeToTurn[uid] = uid
                dirtyTurnIDs.insert(uid)
            } else {
                guard let lastUID = orderedTurnUIDs.last else { continue }
                turnNodeIDs[lastUID, default: []].append(nodeID)
                nodeToTurn[nodeID] = lastUID
                dirtyTurnIDs.insert(lastUID)
            }
        }

        // 2. Removed nodes: drop from their turn's node list and caches.
        for nodeID in changed where graph.nodes[nodeID] == nil {
            if let uid = nodeToTurn[nodeID] {
                turnNodeIDs[uid]?.removeAll { $0 == nodeID }
                dirtyTurnIDs.insert(uid)
            }
            nodeToTurn[nodeID] = nil
            nodeProjections[nodeID] = nil
            nodeProjectionRevisions[nodeID] = nil
        }

        // 3. Last-turn / isLive transitions. When the last turn changes or the
        //    snapshot-level live flag flips, the affected last turn(s) must be
        //    re-projected because their isLive flag changes.
        let currentLastUID = orderedTurnUIDs.last
        if currentLastUID != lastProjectedLastTurnUID || isLive != lastProjectedIsLive {
            if let old = lastProjectedLastTurnUID { dirtyTurnIDs.insert(old) }
            if let current = currentLastUID { dirtyTurnIDs.insert(current) }
            lastProjectedLastTurnUID = currentLastUID
            lastProjectedIsLive = isLive
        }

        // 2.5 Turn-level diffstat arrived. It is stamped by the terminal reducer
        //     case, which may not touch a single node, so it needs its own dirty
        //     signal. Cheap: only fires when the revision actually moved.
        if graph.turnChangesRevision != projectedChangesRevision {
            projectedChangesRevision = graph.turnChangesRevision
            for serverTurnID in graph.turnChanges.keys {
                if let uid = uidByServerTurnID[serverTurnID] { dirtyTurnIDs.insert(uid) }
            }
            // A brand-new finished turn may not be mapped yet on the very first
            // projection after it appeared.
            if let current = currentLastUID { dirtyTurnIDs.insert(current) }
        }

        // 4. Re-project only dirty turns.
        for uid in dirtyTurnIDs {
            reprojectTurn(
                uid, graph: graph, isLive: isLive,
                isLastTurn: uid == currentLastUID, wallClock: wallClock
            )
        }

        // 5. Assemble. Turns may have become empty (all nodes removed) — filter.
        let turns = orderedTurnUIDs.compactMap { cachedTurns[$0] }.filter { !$0.isEmpty }
        if dirtyTurnIDs.isEmpty, let assembledTimeline {
            return (assembledTimeline, turns)
        }
        let timeline = orderedTurnUIDs.flatMap { turnMergedNodes[$0] ?? [] }
        assembledTimeline = timeline
        return (timeline, turns)
    }

    /// Drop all cached state. Next `project` performs a full seed.
    mutating func reset() {
        turnNodeIDs.removeAll()
        orderedTurnUIDs.removeAll()
        nodeToTurn.removeAll()
        turnMergedNodes.removeAll()
        cachedTurns.removeAll()
        projectedWallClock.removeAll()
        contentVersions.removeAll()
        nodeProjections.removeAll()
        nodeProjectionRevisions.removeAll()
        lastProjectedLastTurnUID = nil
        lastProjectedIsLive = false
        assembledTimeline = nil
        uidByServerTurnID.removeAll()
        projectedChangesRevision = 0
        isSeeded = false
    }

    // MARK: - Seeding

    /// Full projection from scratch, populating all caches. Equivalent to
    /// `TimelineProjection.projectNodes + projectTurns` (see tests).
    private mutating func seed(
        graph: inout ExecutionGraph,
        isLive: Bool,
        wallClock: [String: TurnWallClock] = [:]
    ) -> (timeline: [ExecutionNode], turns: [ConversationTurn]) {
        _ = graph.consumeChangedNodeIDs()

        // Split the raw linear walk into turns, mirroring projectTurns:
        // a new run starts at the first node and at every userInput node.
        var currentTurnUID: String?
        for node in graph.linearWalk() {
            if currentTurnUID == nil || node.kind == .userInput {
                currentTurnUID = node.id
                turnNodeIDs[node.id] = [node.id]
                orderedTurnUIDs.append(node.id)
            } else {
                turnNodeIDs[currentTurnUID!]?.append(node.id)
            }
            nodeToTurn[node.id] = currentTurnUID
        }

        let currentLastUID = orderedTurnUIDs.last
        for uid in orderedTurnUIDs {
            reprojectTurn(
                uid, graph: graph, isLive: isLive,
                isLastTurn: uid == currentLastUID, wallClock: wallClock
            )
        }

        lastProjectedLastTurnUID = currentLastUID
        lastProjectedIsLive = isLive
        projectedChangesRevision = graph.turnChangesRevision
        isSeeded = true

        let turns = orderedTurnUIDs.compactMap { cachedTurns[$0] }.filter { !$0.isEmpty }
        let timeline = orderedTurnUIDs.flatMap { turnMergedNodes[$0] ?? [] }
        assembledTimeline = timeline
        return (timeline, turns)
    }

    // MARK: - Turn projection

    /// Re-project a single turn: project its nodes (with per-node cache),
    /// merge, fold, and stamp a content version only when content changed.
    private mutating func reprojectTurn(
        _ uid: String,
        graph: ExecutionGraph,
        isLive: Bool,
        isLastTurn: Bool,
        wallClock: [String: TurnWallClock] = [:]
    ) {
        let nodeIDs = turnNodeIDs[uid] ?? []
        let nodes: [ExecutionNode] = nodeIDs.compactMap { nodeID in
            guard let graphNode = graph.nodes[nodeID] else { return nil }
            let revision = graph.nodeRevisions[nodeID] ?? 0
            if let cached = nodeProjections[nodeID],
               nodeProjectionRevisions[nodeID] == revision {
                return cached
            }
            guard let projected = timelineProjection.projectNode(graphNode) else { return nil }
            nodeProjections[nodeID] = projected
            nodeProjectionRevisions[nodeID] = revision
            return projected
        }

        let merged = timelineProjection.applyMerge(nodes)
        turnMergedNodes[uid] = merged

        // Wall clock is keyed by the protocol turn id (the merged nodes carry
        // it), not by the local projection UID.
        let serverTurnID = merged.first?.turnID ?? ""
        if !serverTurnID.isEmpty { uidByServerTurnID[serverTurnID] = uid }
        let clock = wallClock[serverTurnID]
        let clockChanged = projectedWallClock[uid] != clock
        projectedWallClock[uid] = clock

        let newTurn = timelineProjection.buildTurn(
            nodes: merged,
            isLive: isLive && isLastTurn,
            wallClock: clock,
            changes: graph.turnChanges[serverTurnID]
        )
        let oldVersion = contentVersions[uid] ?? 0
        if !clockChanged,
           let cached = cachedTurns[uid],
           cached.withContentVersion(oldVersion) == newTurn.withContentVersion(oldVersion) {
            // Content identical — keep the cached turn and its version so the
            // Web differ can skip it in O(1).
            return
        }
        let newVersion = oldVersion + 1
        contentVersions[uid] = newVersion
        cachedTurns[uid] = newTurn.withContentVersion(newVersion)
    }
}
