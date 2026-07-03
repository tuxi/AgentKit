import Foundation

/// 工具调用项 — call_id 是协议级 tool identity。
/// `tool_started` + `tool_finished` = 同一个 ToolCallItem 的状态变化。
public struct ToolCallItem: Identifiable, Sendable {
    public var id: String { callID }
    /// 协议级工具调用标识符（`call_id`）。
    public let callID: String
    public let toolName: String
    public let toolArgs: JSONValue?
    public var status: ToolCallStatus
    /// `tool_finished` 时写入。
    public var result: ToolResult?

    public init(callID: String, toolName: String, toolArgs: JSONValue?) {
        self.callID = callID
        self.toolName = toolName
        self.toolArgs = toolArgs
        self.status = .running
        self.result = nil
    }
}

public enum ToolCallStatus: Sendable, Hashable {
    case running
    case completed
    case failed
}
