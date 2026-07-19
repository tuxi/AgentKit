//
//  AgentWireSocket.swift
//  AgentKit
//
//  Agent-wire v1 WebSocket 封装。
//  负责：握手校验 → type/kind 分流 → WireFrame → AgentEvent → AsyncStream。
//  UI 永远不直接接触此类 — 由 RuntimeClient 持有。
//

import Foundation

// MARK: - Wire stream kind

/// 直播 WS 的目标分区。会话流与 job 子流（P8.7 Phase C）用同一套握手/backfill/
/// seq 去重/重连机制，只有 URL 路径不同。
public enum WireStreamKind: Sendable {
    /// `/v1/conversations/{id}/stream` —— 主会话双向流。
    case conversation
    /// `/v1/jobs/{id}/stream` —— 后台 job 只读子流（P8.7 §4 Phase C）。
    case job

    /// 直播 WS 路径。
    func streamPath(id: String) -> String {
        switch self {
        case .conversation: return "v1/conversations/\(id)/stream"
        case .job:          return "v1/jobs/\(id)/stream"
        }
    }
}

// MARK: - AgentWireSocket

public final class AgentWireSocket: @unchecked Sendable {

    // MARK: - State

    private let environment: RuntimeEnvironment
    private let conversationID: String
    private let streamKind: WireStreamKind
    private let decoder = JSONDecoder()
    private let submissionCoordinator: AgentInputSubmissionCoordinator

    /// 底层 WebSocket（来自 CoreKit，处理重连/心跳/前后台）。
    private let wsClient: WebSocketClient

    /// 可选的 credential store（远端或 iOS 内嵌 Runtime 路径）。
    private let credentialStore: (any CredentialStore)?
    private let credentialTarget: CredentialTarget

    /// AsyncStream 的 continuation，用于向 UI 推送 AgentEvent。
    private var continuation: AsyncStream<AgentEvent>.Continuation?

    /// Explicit disconnects are terminal for the UI stream. Transient socket drops are not:
    /// `WebSocketClient` owns retry/reconnect, so keeping the same continuation alive lets
    /// the current ConversationViewModel resume receiving events after reconnect.
    private var isExplicitDisconnect = false

    /// 握手状态：hello 帧到达前，所有消息都缓存或忽略。
    private var handshakeComplete = false

    // ── v1.2 §4 增量续传（docs/client_integration_v1.md §2 / §5.8-8）──

    /// 已收到帧里最大的持久化 `seq` —— 续传游标。
    /// 初值由调用方 seed（= 历史回放批的最大 seq），此后由每个带 seq 的帧推进。
    /// seq 单调递增但有空洞，去重只做 `seq <= maxSeq` 丢弃，绝不按条数推算。
    /// 读写都在主线程（WebSocketClient 回调统一主线程；backfill Task 显式 @MainActor）。
    private var maxSeq: Int

    /// 补缺口取数：`GET /v1/conversations/{id}/events?since=<seq>` → 原始帧。
    /// 由 transport 注入（socket 不持有 HTTP client）。nil = 不补缺口（纯直播）。
    var gapFetch: (@Sendable (_ since: Int) async throws -> [WireFrame])?

    /// backfill 进行中：直播事件帧先入缓冲，补完缺口后按到达顺序冲刷（同一去重口径）。
    private var isBackfilling = false
    private var backfillBuffer: [WireFrame] = []

    /// 每次握手 / 断开递增；过期的 backfill 任务直接放弃，不写回状态。
    private var backfillGeneration = 0

    /// hello 帧中声明的 server capabilities。
    private(set) var serverCapabilities: [String] = []

    /// hello 帧中的 server 标识。
    private(set) var serverIdentifier: String?

    /// 握手完成回调 — 在 hello 帧验证通过后、handshakeComplete 置 true 之后调用。
    /// CodeAgentTransport 用此回调发送 `register_tools`。
    var onHandshake: (@Sendable () -> Void)?

    // MARK: - Init

    /// - Parameters:
    ///   - since: 续传游标初值 = 调用方已回放事件里最大的 `seq`（0 = 无历史）。
    ///   - streamKind: 目标分区。`.job` 走 `/v1/jobs/{id}/stream`（只读子流），
    ///     不发任何入站帧、不注册工具。默认 `.conversation`（主会话双向流）。
    ///   - credentialStore: 可选的 credential store（远端或 iOS 内嵌 Runtime 路径）。
    ///     非 nil 时，WS 握手请求会注入 `Authorization: Bearer <jwt>` header。
    public convenience init(
        environment: RuntimeEnvironment,
        conversationID: String,
        since: Int = 0,
        streamKind: WireStreamKind = .conversation,
        credentialStore: (any CredentialStore)? = nil,
        credentialTarget: CredentialTarget = .gateway
    ) {
        self.init(
            environment: environment,
            conversationID: conversationID,
            since: since,
            streamKind: streamKind,
            credentialStore: credentialStore,
            submissionCoordinator: AgentInputSubmissionCoordinator(),
            credentialTarget: credentialTarget
        )
    }

    init(environment: RuntimeEnvironment, conversationID: String,
         since: Int = 0, streamKind: WireStreamKind = .conversation,
         credentialStore: (any CredentialStore)? = nil,
         submissionCoordinator: AgentInputSubmissionCoordinator,
         credentialTarget: CredentialTarget = .gateway) {
        self.environment = environment
        self.conversationID = conversationID
        self.streamKind = streamKind
        self.maxSeq = since
        self.credentialStore = credentialStore
        self.submissionCoordinator = submissionCoordinator
        self.credentialTarget = credentialTarget
        let tag = streamKind == .job ? "job" : "agent-wire"
        self.wsClient = WebSocketClient(identifier: "\(tag).\(conversationID)")
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
    /// - Returns: `AsyncStream<AgentEvent>` — 持续产出事件直到主动 disconnect 或流取消。
    public func connect() -> AsyncStream<AgentEvent> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            self.continuation = continuation
            self.isExplicitDisconnect = false

            let conversationID = self.conversationID

            // 连接校验（v1 无 auth）。validator 在每次连接尝试（含重连）时被调用，
            // 这里**每次现算 URL** —— environment 是惰性 provider：runtime 进后台 Stop()、
            // 回前台 Start() 会换一个 OS 动态分配的 ephemeral port，只有现算才能读到新端口
            // （旧实现把含端口的 URL 在闭包外捕获死了，重启后重连仍连旧死口）。
            // 端口未就绪（≤0 → wsURL 为 nil）时返回 nil，由 WebSocketClient 当作 preflight
            // 失败退避重试，待 runtime 起来后自然连上（前台重连由其 handleAppForeground 触发）。
            let streamKind = self.streamKind
            let store = self.credentialStore
            let target = self.credentialTarget
            self.wsClient.connectionValidatorRequest = { [weak self] in
                guard let self,
                      let wsBase = self.environment.wsURL,
                      let url = URL(string: "\(wsBase)/\(streamKind.streamPath(id: conversationID))")
                else { return nil }
                var request = URLRequest(url: url)
                // validator 本身是 async：每次首连/重连都先走异步 resolver，
                // 允许宿主刷新临近过期的 token，再创建 WebSocket upgrade request。
                if let store {
                    guard let cred = try? await store.resolve(target),
                          !cred.secret.isEmpty,
                          cred.kind == .bearer else {
                        // 已配置认证的连接禁止降级成匿名 WS；返回 nil 交给
                        // WebSocketClient 的 preflight backoff 重试。
                        return nil
                    }
                    request.setValue("Bearer \(cred.secret)", forHTTPHeaderField: "Authorization")
                }
                DeviceContext.apply(to: &request)
                return request
            }

            // 接收回调 — 每帧 JSON 经此处理
            self.wsClient.onReceive = { [weak self] data in
                self?.handleFrame(data: data)
            }

            // 连接成功回调（isConnected 由 computed property 自动派生）
            self.wsClient.onConnected = {}

            // 断开回调。
            // 注意：意外断开不能 finish 上层 AsyncStream。底层 WebSocketClient 会自动重连；
            // 如果这里 finish，ConversationViewModel 的 streamTask 会永久结束，后续重连收到的
            // 事件无人消费，表现为“发送成功但当前 UI 没响应，退出重进才看到历史”。
            self.wsClient.onDisconnected = { [weak self] _ in
                guard let self else { return }
                self.handshakeComplete = false
                // 丢弃进行中的 backfill：缓冲帧都已持久化在服务端，游标未被它们推进，
                // 重连后的下一次 backfill 会从同一 maxSeq 重新补齐，不丢事件。
                self.abandonBackfill()
                Task { await self.submissionCoordinator.markReconnecting() }
                guard self.isExplicitDisconnect else { return }
                self.continuation?.finish()
                self.continuation = nil
            }

            // 发起连接
            self.wsClient.connect()
        }
    }

    /// 发送结构化输入（fire-and-forget）。响应来自 event stream。
    public func send(input: AgentInput) async {
        _ = await submit(input: input)
    }

    /// Registers an immutable turn payload before sending it. The coordinator owns
    /// the pending lifetime even when the returned stream has no active subscriber.
    public func submit(input: AgentInput) async -> AgentInputSubmissionTicket {
        let requestID = input.requestID ?? ""
        do {
            try input.validateForSubmission(
                supportsImageInput: serverCapabilities.contains("image_input")
            )
        } catch let rejection as AgentInputRejection {
            return .terminal(requestID: requestID, state: .rejected(rejection))
        } catch {
            return .terminal(
                requestID: requestID,
                state: .rejected(AgentInputRejection(
                    code: error is UserAssetValidationError && input.assets.count > 4
                        ? "too_many_assets"
                        : "invalid_assets",
                    message: error.localizedDescription
                ))
            )
        }

        // Tool/system continuations do not create turns and are not held in the
        // v1.5 durable-submission registry.
        guard case .text = input.kind else {
            send(outgoing: OutgoingAgentInput.from(input: input))
            return .terminal(requestID: requestID, state: .dispatched)
        }
        guard !requestID.isEmpty else {
            return .terminal(
                requestID: requestID,
                state: .rejected(AgentInputRejection(code: "invalid_input", message: "request_id is required"))
            )
        }

        let ticket = await submissionCoordinator.register(input)
        if isConnected {
            send(outgoing: OutgoingAgentInput.from(input: input))
            await submissionCoordinator.markDispatched(requestID: requestID)
        }
        return ticket
    }

    /// 发送消息（fire-and-forget）。响应来自 event stream。
    @available(*, deprecated, message: "Use send(input:)")
    public func sendMessage(_ text: String) {
        Task { await send(input: .text(text)) }
    }

    /// 发送审批回复（两态兼容）。
    public func sendApproval(id: String, approved: Bool) {
        send(outgoing: OutgoingApprovalResponse(id: id, approved: approved))
    }

    /// 发送三态审批回复（v1.2）。
    /// - Parameters:
    ///   - id: 对应 approval_request.id
    ///   - decision: "once" | "always" | "deny"
    ///   - scope: "local"（默认）或 "user"，仅 decision="always" 时有效
    public func sendApproval(id: String, decision: String, scope: String?) {
        send(outgoing: OutgoingApprovalResponse(id: id, decision: decision, scope: scope))
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
        isExplicitDisconnect = true
        continuation?.finish()
        continuation = nil
        handshakeComplete = false
        abandonBackfill()
        wsClient.disconnect()
    }

    // MARK: - Frame handling

    /// internal（而非 private）：单测直接喂帧驱动握手 / 去重 / backfill 路径。
    func handleFrame(data: Data) {
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
            // §5.8-8：每次握手（首连 + 自动重连）都先补缺口再放行直播帧。
            // 首连覆盖「历史 GET 与 WS attach 之间」的窗口；重连覆盖断线期间的缺口。
            startBackfill()
            let supportsImageInput = serverCapabilities.contains("image_input")
            Task { [weak self] in
                guard let self else { return }
                let inputs = await self.submissionCoordinator.replayableInputs(
                    supportsImageInput: supportsImageInput
                )
                for input in inputs {
                    self.send(outgoing: OutgoingAgentInput.from(input: input))
                    if let requestID = input.requestID {
                        await self.submissionCoordinator.markDispatched(requestID: requestID)
                    }
                }
            }
            // hello 帧是内部握手，不暴露给 UI

        case "approval_request":
            guard let request = ApprovalRequest.from(wire: frame) else { return }
            continuation?.yield(.approvalRequest(turnID: frame.turnId, request: request))

        case "plan_approval_request":
            guard let plan = PlanApprovalRequest.from(wire: frame) else { return }
            continuation?.yield(.planApprovalRequest(turnID: frame.turnId, request: plan))

        case "agent_input_rejected":
            let rejection = AgentInputRejection(
                code: frame.error?.code ?? "request_failed",
                message: frame.error?.message ?? "Input was rejected"
            )
            Task {
                await submissionCoordinator.reject(
                    requestID: frame.requestId,
                    rejection: rejection
                )
            }
            continuation?.yield(.agentInputRejected(requestID: frame.requestId, rejection: rejection))

        default:
            // 未知控制帧类型：忽略（前向兼容）
            break
        }
    }

    // MARK: - Event frame dispatch

    private func handleEventFrame(frame: WireFrame) {
        guard handshakeComplete else { return }

        // backfill 期间直播帧先入缓冲，保证「缺口事件 → 直播事件」的时序。
        if isBackfilling {
            backfillBuffer.append(frame)
            return
        }
        yieldEventFrame(frame)
    }

    /// 去重 → 推进游标 → 转换并产出。直播帧与 backfill 帧走同一口径。
    private func yieldEventFrame(_ frame: WireFrame) {
        if let seq = frame.seq {
            // 与历史批 / 补缺批重叠的重复帧：丢弃（v1.2 §4，token_delta 无 seq 直通）。
            guard seq > maxSeq else { return }
            // 游标来自原始帧：未知 kind 被下面 from(wire:) 丢弃也照样推进。
            maxSeq = seq
        }
        if let event = AgentEvent.from(wire: frame) {
            if case .turnAccepted(let turnID, let requestID, _) = event,
               let requestID {
                Task {
                    await submissionCoordinator.accept(requestID: requestID, turnID: turnID)
                }
            }
            continuation?.yield(event)
        }
        // 未知 kind → AgentEvent.from 返回 nil → 忽略（前向兼容）
    }

    // MARK: - Reconnect gap backfill

    /// 握手完成后补缺口：`GET /events?since=<maxSeq>` 先行，期间直播帧缓冲，补完按序冲刷。
    private func startBackfill() {
        guard let gapFetch else { return }
        backfillGeneration += 1
        let generation = backfillGeneration
        isBackfilling = true
        backfillBuffer.removeAll()
        let since = maxSeq

        Task { @MainActor [weak self] in
            // 取数失败按空批处理：直播可用性优先，先放行缓冲帧。此时缺口事件会缺席
            // 到下一次重连 / 整页历史回放（缓冲帧会推进 maxSeq，本次缺口不再自动补）。
            let frames = (try? await gapFetch(since)) ?? []
            guard let self, generation == self.backfillGeneration else { return }
            for frame in frames {
                self.yieldEventFrame(frame)
            }
            let buffered = self.backfillBuffer
            self.backfillBuffer = []
            self.isBackfilling = false
            for frame in buffered {
                self.yieldEventFrame(frame)
            }
        }
    }

    /// 断开（主动或意外）时废弃进行中的 backfill 与缓冲。
    private func abandonBackfill() {
        backfillGeneration += 1
        isBackfilling = false
        backfillBuffer.removeAll()
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
