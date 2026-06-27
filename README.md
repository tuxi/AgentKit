# AgentKit
> Swift Agent Runtime Protocol Layer — build modern AI Agent experiences for Apple platforms.

*AgentKit* is an open-source Swift framework for building production-quality AI Agent applications on *iOS* and *macOS*.

It is **not** a chat UI kit. It is a **multi-runtime execution graph system** — a protocol-first client layer that decouples UI rendering from backend agent runtimes.

## Design Principles

| Principle | Meaning |
|---|---|
| **Protocol First** | UI depends on `RuntimeClient` protocol, never on implementation |
| **Transport Pluggable** | `AgentTransport` enables backend swap without UI changes |
| **Session is Server-Owned** | `ConversationRef` = server runtime identity; `connect()` attaches, never creates |
| **Event is Source of Truth** | UI state = `reducer(event stream)` |
| **No Business Logic in UI** | UI only does: render, animation, interaction |
| **Async Approval** | Distributed agent system needs async event-based approval, not sync hooks |

## Architecture

```
┌──────────────────────────────────────┐
│            AgentKit UI                │
│   (SwiftUI — 只依赖 RuntimeClient)    │
└──────────────┬───────────────────────┘
               │ RuntimeClient (facade protocol)
               ▼
┌──────────────────────────────────────┐
│        DefaultAgentClient             │  ← thin facade, zero logic
│        (composes AgentTransport)      │
└──────────────┬───────────────────────┘
               │ AgentTransport (runtime boundary protocol)
               ▼
┌──────────────────────────────────────┐
│  CodeAgentTransport                  │  ← backend implementations
│  DreamAITransport                    │     (pluggable)
│  ClaudeTransport                     │
│  MockTransport (testing)             │
└──────────────┬───────────────────────┘
               ▼
┌──────────────────────────────────────┐
│       Backend Runtime                 │
│  (CodeAgent / DreamAI / Claude SDK)  │
└──────────────────────────────────────┘
```

## Features

* 💬 Conversation UI with streaming responses
* 🧠 Thinking / Tool / Observation timeline with event-sourced state
* ✅ Human approval workflow (async, independent channel)
* 📋 Todo visualization
* 📎 Artifact & Inspector
* 🔄 Event-driven runtime (`RuntimeEngine` actor)
* 🌐 Transport-agnostic networking (`AgentTransport` protocol)
* 🔌 Pluggable backend (CodeAgent / DreamAI / OpenAI / Claude)
* 🧪 Mock transport for UI testing

## Quick Start

```swift
import AgentKit

// 1. Create transport for your backend
let transport = CodeAgentTransport(host: "127.0.0.1", port: 8787)

// 2. Create client (thin facade)
let client = DefaultAgentClient(transport: transport)

// 3. Inject into UI
let deps = AgentDependencies(client: client)

// 4. Send structured input
await client.send(input: .text("Analyze this project"))
await client.send(input: .toolResult(ToolResultContent(
    toolUseID: "call_1",
    content: "File contents...",
    isError: false
)))
```

## Protocol v1.1 — Key Types

| Type | Role |
|---|---|
| `RuntimeClient` | UI facade protocol — all UI depends on this |
| `AgentTransport` | Runtime boundary protocol — backend implementations conform |
| `AgentInput` | Structured input — `.text` / `.toolResult` / `.command` / `.system` |
| `AgentEvent` | UI event stream — 16 event kinds, reducer-driven state |
| `AgentCapabilityFlags` | Backend capability declaration — UI adapts rendering |
| `ConversationRef` | Server-owned session identity |
| `CodeAgentTransport` | Reference implementation for CodeAgent backend |

## P0 / P1 / P2 Roadmap

| Priority | Scope |
|---|---|
| **P0 (done)** | `AgentInput` + `AgentTransport` + Session model |
| **P1** | `SystemCommand` schema convergence, capabilities expansion, streaming enhancements |
| **P2** | Subagent execution graph, Permission system, Plan mode |
