import Foundation

/// UI projection of a runtime conversation. `ConversationRef` intentionally
/// compares by durable session ID only; this value also compares the fields a
/// sidebar row renders, so SwiftUI can invalidate changed row content without
/// changing the row's stable identity.
public struct ConversationListItem: Identifiable, Equatable, Sendable {
    public let ref: ConversationRef

    public var id: String { ref.id }

    public init(ref: ConversationRef) {
        self.ref = ref
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.ref.presentationID == rhs.ref.presentationID
            && lhs.ref.workspaceGroupingID == rhs.ref.workspaceGroupingID
            && lhs.ref.workspaceGroupingName == rhs.ref.workspaceGroupingName
    }
}
