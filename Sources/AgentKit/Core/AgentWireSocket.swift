//
//  AgentWireSocket.swift
//  AgentKit
//
//  Agent-wire v1 WebSocket 封装。
//  负责：握手校验 → type/kind 分流 → WireFrame → AgentEvent → AsyncStream。
//  UI 永远不直接接触此类 — 由 RuntimeClient 持有。
//

import Foundation

// MARK: - AgentWireSocket

public final class AgentWireSocket: @unchecked Sendable {

    // MARK: - State

    private let environment: RuntimeEnvironment
    private let conversationID: String
    private let decoder = JSONDecoder()

    /// 底层 WebSocket（来自 CoreKit，处理重连/心跳/前后台）。
    private let wsClient: WebSocketClient

    /// AsyncStream 的 continuation，用于向 UI 推送 AgentEvent。
    private var continuation: AsyncStream<AgentEvent>.Continuation?

    /// 握手状态：hello 帧到达前，所有消息都缓存或忽略。
    private var handshakeComplete = false

    /// hello 帧中声明的 server capabilities。
    private(set) var serverCapabilities: [String] = []

    /// hello 帧中的 server 标识。
    private(set) var serverIdentifier: String?

    /// 握手完成回调 — 在 hello 帧验证通过后、handshakeComplete 置 true 之后调用。
    /// CodeAgentTransport 用此回调发送 `register_tools`。
    var onHandshake: (@Sendable () -> Void)?

    // MARK: - Init

    public init(environment: RuntimeEnvironment, conversationID: String) {
        self.environment = environment
        self.conversationID = conversationID
        self.wsClient = WebSocketClient(identifier: "agent-wire.\(conversationID)")
    }

    deinit {
        continuation?.finish()
        wsClient.disconnect()
    }

    // MARK: - Session state

    /// 当前是否已连接。
    public var isConnected: Bool { handshakeComplete && wsClient.state == .connected }

    /// 当前绑定的 session ID。
    public var activeSessionID: String? { isConnected ? conversationID : nil }

    // MARK: - Public API

    /// 连接 WebSocket 并返回事件流。
    /// - Returns: `AsyncStream<AgentEvent>` — 持续产出事件直到连接断开或流取消。
    public func connect() -> AsyncStream<AgentEvent> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            self.continuation = continuation

            let conversationID = self.conversationID

            // 连接校验（v1 无 auth）。validator 在每次连接尝试（含重连）时被调用，
            // 这里**每次现算 URL** —— environment 是惰性 provider：runtime 进后台 Stop()、
            // 回前台 Start() 会换一个 OS 动态分配的 ephemeral port，只有现算才能读到新端口
            // （旧实现把含端口的 URL 在闭包外捕获死了，重启后重连仍连旧死口）。
            // 端口未就绪（≤0 → wsURL 为 nil）时返回 nil，由 WebSocketClient 当作 preflight
            // 失败退避重试，待 runtime 起来后自然连上（前台重连由其 handleAppForeground 触发）。
            self.wsClient.connectionValidatorRequest = { [weak self] in
                guard let self,
                      let wsBase = self.environment.wsURL,
                      let url = URL(string: "\(wsBase)/v1/conversations/\(conversationID)/stream")
                else { return nil }
                return URLRequest(url: url)
            }

            // 接收回调 — 每帧 JSON 经此处理
            self.wsClient.onReceive = { [weak self] data in
                self?.handleFrame(data: data)
            }

            // 连接成功回调（isConnected 由 computed property 自动派生）
            self.wsClient.onConnected = {}

            // 断开回调 — 终止流
            self.wsClient.onDisconnected = { [weak self] _ in
                self?.handshakeComplete = false
                self?.continuation?.finish()
                self?.continuation = nil
            }

            // 发起连接
            self.wsClient.connect()
        }
    }

    /// 发送结构化输入（fire-and-forget）。响应来自 event stream。
    public func send(input: AgentInput) {
        let outgoing = OutgoingAgentInput.from(input: input)
        send(outgoing: outgoing)
    }

    /// 发送消息（fire-and-forget）。响应来自 event stream。
    @available(*, deprecated, message: "Use send(input:)")
    public func sendMessage(_ text: String) {
        send(input: .text(text))
    }

    /// 发送审批回复。
    public func sendApproval(id: String, approved: Bool) {
        send(outgoing: OutgoingApprovalResponse(id: id, approved: approved))
    }

    /// 发送计划审批回复。
    public func sendPlanApproval(id: String, approved: Bool) {
        send(outgoing: OutgoingPlanApprovalResponse(id: id, approved: approved))
    }

    /// 取消当前 turn。
    public func cancelTurn() {
        send(outgoing: OutgoingCancelTurn())
    }

    /// 向服务端注册客户端工具。在握手完成后调用。
    public func sendRegisterTools(_ tools: [ClientToolInfo]) {
        let outgoing = OutgoingRegisterTools(
            tools: tools.map {
                OutgoingClientToolDef(name: $0.name, description: $0.description, inputSchema: $0.inputSchema)
            }
        )
        send(outgoing: outgoing)
    }

    /// 主动断开。
    public func disconnect() {
        continuation?.finish()
        continuation = nil
        handshakeComplete = false
        wsClient.disconnect()
    }

    // MARK: - Frame handling

    private func handleFrame(data: Data) {
        guard let frame = try? decoder.decode(WireFrame.self, from: data) else {
            return
        }

        // Step 1: 按 type vs kind 分流
        if let type = frame.type {
            handleControlFrame(type: type, frame: frame)
        } else if frame.kind != nil {
            handleEventFrame(frame: frame)
        }
        // else: 既无 type 也无 kind → 忽略
    }

    // MARK: - Control frame dispatch

    private func handleControlFrame(type: String, frame: WireFrame) {
        switch type {
        case "hello":
            let version = frame.protocolVersion ?? 0
            guard version == 1 else {
                // 协议版本不匹配：断开
                continuation?.finish()
                continuation = nil
                wsClient.disconnect()
                return
            }
            handshakeComplete = true
            serverCapabilities = frame.capabilities ?? []
            serverIdentifier = frame.server
            // 通知 transport 层握手完成（用于发送 register_tools 等）
            onHandshake?()
            // hello 帧是内部握手，不暴露给 UI

        case "approval_request":
            guard let request = ApprovalRequest.from(wire: frame) else { return }
            continuation?.yield(.approvalRequest(turnID: frame.turnId, request: request))

        case "plan_approval_request":
            guard let plan = PlanApprovalRequest.from(wire: frame) else { return }
            continuation?.yield(.planApprovalRequest(turnID: frame.turnId, request: plan))

        default:
            // 未知控制帧类型：忽略（前向兼容）
            break
        }
    }

    // MARK: - Event frame dispatch

    private func handleEventFrame(frame: WireFrame) {
        guard handshakeComplete else { return }

        if let event = AgentEvent.from(wire: frame) {
            continuation?.yield(event)
        }
        // 未知 kind → AgentEvent.from 返回 nil → 忽略（前向兼容）
    }

    // MARK: - Outgoing

    private func send(outgoing: some Encodable) {
        guard let data = try? JSONEncoder().encode(outgoing),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        wsClient.send(json)
    }
}
