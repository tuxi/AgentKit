import Foundation

/// UI projection of a runtime conversation. `ConversationRef` intentionally
/// compares by durable session ID only; this value also compares the fields a
/// sidebar row renders, so SwiftUI can invalidate changed row content without
/// changing the row's stable identity.
public struct ConversationListItem: Identifiable, Equatable, Sendable {
    public let ref: ConversationRef
    private let presentationID: String
    let workspaceGroupingID: String
    let workspaceGroupingName: String

    public var id: String { ref.id }

    public init(ref: ConversationRef) {
        self.ref = ref
        self.presentationID = ref.presentationID
        self.workspaceGroupingID = ref.workspaceGroupingID
        self.workspaceGroupingName = ref.workspaceGroupingName
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.presentationID == rhs.presentationID
            && lhs.workspaceGroupingID == rhs.workspaceGroupingID
            && lhs.workspaceGroupingName == rhs.workspaceGroupingName
    }
}
