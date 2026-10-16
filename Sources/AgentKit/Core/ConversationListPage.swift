import Foundation

/// A stable server-ordered page. Legacy adapters return a complete unpaged list.
public struct ConversationListPage: Sendable {
    public let conversations: [ConversationRef]
    public let nextCursor: String?
    public let hasMore: Bool
    public let isPaged: Bool

    public init(conversations: [ConversationRef], nextCursor: String? = nil,
                hasMore: Bool = false, isPaged: Bool = false) {
        self.conversations = conversations
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.isPaged = isPaged
    }
}
