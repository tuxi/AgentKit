//
//  ClientTool.swift
//  AgentKit
//
//  Client-side tool execution protocol.
//  When server emits tool_started with executor: "client",
//  AgentKit routes execution to the registered ClientTool.
//
//  Protocol: AgentKit Runtime Protocol v1.1 §ClientTool
//

import Foundation

// MARK: - ClientTool

/// 客户端工具协议 — 在本地设备上执行的工具。
///
/// 服务端声明 `executor: "client"` 的工具调用，由注册的 `ClientTool` 实例在本地执行。
/// 典型场景：AVFoundation 视频处理、HealthKit 数据读取、系统权限请求。
///
/// ```swift
/// struct TrimVideoTool: ClientTool {
///     let name = "trim_video"
///     let description = "Trim a video file using AVFoundation"
///
///     func execute(args: JSONValue?) async throws -> String {
///         // AVFoundation 本地实现
///         return "修剪完成: /tmp/output.mp4"
///     }
/// }
/// ```
public protocol ClientTool: Sendable {
    /// 工具名称 — 必须与服务端 `tool_started.tool_name` 完全匹配。
    var name: String { get }

    /// 人类可读描述。
    var description: String { get }

    /// JSON Schema 格式的输入参数定义。默认空对象（无参数）。
    var inputSchema: JSONValue? { get }

    /// 执行工具。
    /// - Parameter args: 服务端下发的 `tool_args`（任意 JSON 对象）。
    /// - Returns: 工具执行结果文本。
    /// - Throws: 执行失败时抛出，AgentKit 自动组装 `isError: true` 的 `toolResult`。
    func execute(args: JSONValue?) async throws -> String
}

extension ClientTool {
    /// 默认无参数。
    public var inputSchema: JSONValue? { nil }
}

/// Structured result returned by client-side tools that can expose clickable
/// assets in addition to the transcript text.
public struct ClientToolExecutionResult: Sendable, Hashable {
    public let content: String
    public let output: JSONValue?
    public let assets: [AgentAssetRef]
    public let isError: Bool

    public init(
        content: String,
        output: JSONValue? = nil,
        assets: [AgentAssetRef] = [],
        isError: Bool = false
    ) {
        self.content = content
        self.output = output
        self.assets = assets
        self.isError = isError
    }
}

/// Optional v1.3 extension for client tools that can return structured output
/// and asset refs. Existing tools can keep implementing `ClientTool.execute`.
public protocol StructuredClientTool: ClientTool {
    func executeResult(args: JSONValue?) async throws -> ClientToolExecutionResult
}

extension StructuredClientTool {
    public func execute(args: JSONValue?) async throws -> String {
        try await executeResult(args: args).content
    }
}

// MARK: - ToolRegistry

/// 客户端工具注册表 — 线程安全的工具查找。
///
/// 使用 actor 保证并发安全。工具通过 `AgentDependencies` 注入，
/// `ConversationViewModel` 通过 registry 匹配并执行客户端工具。
public actor ToolRegistry {
    private var tools: [String: any ClientTool] = [:]

    public init() {}

    /// 注册一个客户端工具。
    public func register(_ tool: any ClientTool) {
        tools[tool.name] = tool
    }

    /// 根据名称查找工具。
    public func find(name: String) -> (any ClientTool)? {
        tools[name]
    }

    /// 注销工具。
    public func unregister(name: String) {
        tools.removeValue(forKey: name)
    }

    /// 已注册工具数量。
    public var count: Int { tools.count }

    /// 所有已注册工具的名称。
    public var registeredNames: [String] {
        Array(tools.keys).sorted()
    }

    /// 导出工具信息列表（用于向服务端注册）。
    public var registeredToolInfos: [ClientToolInfo] {
        tools.values.map { ClientToolInfo(name: $0.name, description: $0.description, inputSchema: $0.inputSchema) }
            .sorted { $0.name < $1.name }
    }
}

// MARK: - ClientToolInfo

/// 客户端工具元信息 — 用于向服务端注册。
/// 通过 `register_tools` wire message 在握手后发送。
public struct ClientToolInfo: Sendable, Codable {
    public let name: String
    public let description: String
    /// JSON Schema 格式的工具输入定义。默认空对象（无参数）。
    public let inputSchema: JSONValue?

    public init(name: String, description: String, inputSchema: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}
