# AgentKit: HTTP Provider Management via /v1/providers — Requirements

Status: Stage ③ requirements research (read-only). No implementation.
Runtime contract: design-providers-grouped-config.md (code-agent workspace; not
readable from this workspace — grounded in the task description + AgentKit source).
Goal: hosts manage provider configuration through the runtime's `/v1/providers`
HTTP API (single source of truth) instead of each client keeping its own local
registry. Embedded (iOS) stays host-injected.

---

## 1. Current provider-config flow (map)

### 1.1 Local registry — `Sources/AgentKit/Core/Providers/ProviderConnectionRegistry.swift`
- `@MainActor @Observable` final class; persists `[ProviderConnection]` to
  `UserDefaults` under `agentkit.provider_connections.v1` (JSON-encoded).
- API: `upsert(_:)` (validate + persist), `remove(connectionID:)`, `setEnabled(_:connectionID:)`,
  `replaceModels(_:connectionID:)`, `replaceAll(_:)`, `reset()`, and read helpers
  `enabledConnections`, `models` (→ `[UnifiedModelDescriptor]`), `connection(id:)`,
  `model(id:)` / `model(runtimeAlias:)`.
- **Only consumer found**: `UnifiedModelCatalogStore.reload(from: registry)`
  (`Sources/AgentKit/Core/Providers/UnifiedModelCatalogStore.swift:36`) — the
  host-facing model catalog. `Examples/CodeAgent` constructs no `ProviderConnection`.

### 1.2 Connection model — `Sources/AgentKit/Core/Providers/ProviderConnection.swift`
`id` (stable, e.g. `deepseek`), `providerID` (template, e.g. `openai-compatible`),
`displayName`, `transport` (`.openAIChatCompletions` | `.ollama`), `authentication`
(`.gatewayAccount` | `.apiKey` | `.none`), `baseURL`, `modelSource`, `models:
[ProviderModel]`, `isEnabled: Bool`, `allowsInsecurePrivateNetworkHTTP`.
`credentialTarget`: `.gatewayAccount → .gateway`, `.apiKey → .llm(id)`, `.none → nil`.
`isTalkifyGateway`: id == `talkify-gateway` or gatewayAccount auth.

### 1.3 Serialization to the runtime — `RuntimeProviderConfigurationBuilder.swift`
- `build(connections:defaultModelID:options:permissions:verify:hooks:)` → emits the
  **settings.File document** (`RuntimeSettingsDocument`): `default_model`,
  `credentials` (namespace → name → `{source, env}`), `models` (friendly-name →
  `{provider, base_url, model, api_key_env, temperature, context_window, pricing…,
  credential:{namespace,name}, catalog:{connection_id, provider_id, …}}`), plus
  `agent/provider/web/runtime/currency/permissions/verify/hooks`.
- `buildConnectionsJSON(connections:)` → `{ "connections": { "<id>": {id, api,
  base_url, credential:{source, ref, env}, models:[{runtime_alias, wire_model_id,
  context_window, pricing…}]} } }` — the flat connection-id form used by
  `ReconfigureConnections` (hot-swap channel).

### 1.4 Injection into the runtime — `Sources/AgentKit/Core/AgentRuntime.swift`
- `configureProviderConnections(_ generated: GeneratedRuntimeProviderConfiguration)`
  sets `configuration.runtimeSettingsJSON = generated.settingsJSON`; the next
  `launch()` passes it as the MobileStart `settingsJSON` (single config source).
- `reconfigure(connectionsJSON:secretsJSON:modelName:)` → `server.reconfigureConnections`
  (live hot-swap; "" = keep current).
- Structural changes are restart-gated via `RuntimeProviderConfigurationApplyQueue`
  (`Sources/AgentKit/Core/Providers/RuntimeProviderConfigurationApplyQueue.swift`).

### 1.5 HTTP client — `Sources/AgentKit/Core/RuntimeHTTPClient.swift`
- Internal `struct RuntimeHTTPClient` (ephemeral `URLSession`, no-redirect delegate,
  TLS policy hook, `RuntimeEnvironment` origin, `{trace_id,code,msg,data}` envelope
  decode, `RuntimeHTTPError`).
- **No `/v1/providers` client exists.** Endpoints today: `/healthz`,
  `v1/runtime/info`, `v1/runtime/models`, `v1/runtime/capabilities`, `v1/activity`,
  `v1/conversations…`, `v1/jobs…`, `v1/child-streams…`, `v1/repos/clone`.
- Auth: `applyAuth` resolves a bearer token from `credentialStore.resolve(credentialTarget)`
  (default target `CredentialTarget.runtimeAccess("default")`). Credential is injected
  **per request**; `DeviceContext.apply` adds device headers.

### 1.6 Where the bearer token comes from
- **Embedded**: `AgentRuntime.runtimeAccessCredentialStore`
  (`Sources/AgentKit/Core/RuntimeServers/EmbeddedRuntimeAccess.swift`) — a
  `CredentialStore` whose target is `CredentialTarget.runtimeAccess("talkify-embedded-runtime")`,
  rotated at every launch, deliberately excluded from Provider `secretsJSON`
  (`all()` returns empty). Wired in `AgentClientImpl.fromRuntime()`
  (`AgentClientImpl.swift:560-583`), `RuntimeServerCoordinator.makeHTTPClient`
  (line 533-543), `RuntimeServerStatusMonitor` (80-81), `RuntimeSharingController`
  (240-241). Endpoint via `RuntimeEnvironment.fromRuntime()` (lazy `AgentRuntime.shared.port()`).
- **External (local/remote)**: `RuntimeServerConnection.endpoint` + per-connection
  bearer (`connection.credentialTarget`, resolved through `runtimeCredentialStore`).

### 1.7 Runtime Server concept — `RuntimeServerConnection.swift`
`RuntimeServerKind`: `embedded` (id `talkify-embedded-runtime`) | `local` | `remote`.
`RuntimeServerCoordinator`/`Registry` manage these and build HTTP clients. This is the
existing desktop/server hook.

---

## 2. Requirements for HTTP provider management

### 2.1 Public API surface (new)
A public `RuntimeProviderService` (or `ProviderService`) wrapping the internal
`RuntimeHTTPClient`, mirroring how `DefaultAgentClient`/`RuntimeServerCoordinator`
construct clients:

- `init(environment: RuntimeEnvironment, credentialStore: (any CredentialStore)?,
  credentialTarget: CredentialTarget = .runtimeAccess("default"),
  trustPolicy: RuntimeServerTrustPolicy? = nil)`
- Convenience `static func fromRuntime() -> RuntimeProviderService` (embedded: lazy
  port + `runtimeAccessCredentialStore`, exactly like `DefaultAgentClient.fromRuntime()`).
- `listProviders() async throws -> [RuntimeProviderSummary]` → `GET /v1/providers`
- `getProvider(id: String) async throws -> RuntimeProviderDefinition?` → `GET /v1/providers/{id}`
- `upsertProvider(_ definition: RuntimeProviderDefinition) async throws -> RuntimeProviderDefinition` → `PUT /v1/providers/{id}`
- `deleteProvider(id: String) async throws` → `DELETE /v1/providers/{id}`

DTOs (mirror the settings `providers` section, service id → `{base_url, api,
credential, headers, models[]}`):
- `RuntimeProviderDefinition`: `id`, `baseURL` (`base_url`), `api` (`openai`|`ollama`|`gateway`),
  `credential` (reuse `RuntimeConnectionCredentialDeclaration` {source, ref, env} —
  already public in `ConnectionsJSON.swift`), `headers: [String: String]?` (new),
  `models: [RuntimeConnectionModelDefinition]` (already public).
- `RuntimeProviderSummary`: secret-stripped view for `listProviders` (runtime DTO
  strips secrets per contract; SDK must not echo credential values back).

Mapping to the existing wire is direct: `buildConnectionsJSON` already produces
`{id, api, base_url, credential:{source,ref,env}, models[]}` — the providers DTO is
the same shape plus an optional `headers`. The SDK should reuse
`RuntimeConnectionDefinition`/`RuntimeConnectionModelDefinition` as the encoding
types where possible, adding only `headers`.

### 2.2 Coexistence with the local registry + injection path
Decision needed from the design, recommended here:
- **Desktop/server**: `/v1/providers` becomes the **source of truth** (runtime
  persists `<root>/.codeagent/settings.json` under flock). The local
  `ProviderConnectionRegistry` is **not used for writes**; it may remain as a
  legacy read path or be removed. The runtime's `settings.json` `providers`
  section replaces the SDK-built `buildConnectionsJSON` document for hosts that
  adopt HTTP — the injected settingsJSON/connectionsJSON path and the HTTP path
  are **two encodings of the same provider data** and must not both be written.
- **iOS embedded**: no disk settings.json; keep the existing
  `configureProviderConnections` + `buildConnectionsJSON` injection path
  unchanged. Registry stays authoritative on iOS.
- Recommended: a thin host-facing facade (e.g. `ProviderStore`) that reads from
  `/v1/providers` on desktop and from `ProviderConnectionRegistry` on iOS, so the
  UI doesn't branch. **Do not implement both write paths simultaneously** (see risks).
- `UnifiedModelCatalogStore`/`RuntimeServerModelCatalog` already consume the
  runtime's `GET /v1/runtime/models`; hosts that adopt `/v1/providers` should feed
  the catalog from that endpoint instead of the registry.

### 2.3 Auth
Identical to `/v1/runtime/models` today:
- Embedded: bearer from `AgentRuntime.shared.runtimeAccessCredentialStore`
  (rotated per launch), endpoint `RuntimeEnvironment.fromRuntime()`.
- External: `connection.credentialTarget` resolved through `runtimeCredentialStore`,
  endpoint from `RuntimeServerConnection.endpoint`.
- Never use Provider/Gateway credentials for the runtime control plane
  (enforced today in `DefaultAgentClient.fromRuntime` doc).
- `/v1/providers` is Bearer-authed per contract — the SDK's existing `applyAuth`
  covers it with no change.

### 2.4 ProviderConnection ↔ providers DTO mapping
| `ProviderConnection` | `providers` DTO (`RuntimeProviderDefinition`) |
|---|---|
| `id` | `id` (service id) |
| `transport` → `baseURL` | `api` (`openai` for `.openAIChatCompletions` non-gateway, `ollama`, `gateway` for `isTalkifyGateway`) |
| `baseURL` | `base_url` |
| `authentication`: `.gatewayAccount` | `credential: {source:"injected", ref:"gateway"}` |
| `authentication`: `.apiKey` | `credential: {source:"injected", ref: connection.id}` |
| `authentication`: `.none` | `credential: nil` |
| `models: [ProviderModel]` | `models[]`: `wire_model_id` = `ProviderModel.id`, `runtime_alias` = `makeRuntimeAlias(id, wireModelID)`, `context_window`/pricing copied |
| — (no current equivalent) | `headers: [String: String]?` — **new optional field** on `ProviderConnection` + DTO |
| `isEnabled` | **open question** (see 4.3) |
| `allowsInsecurePrivateNetworkHTTP`, `modelSource`, `providerID`, `displayName` | no direct DTO field — either dropped (runtime policy) or carried in a `catalog`-style subobject; must be specified |

---

## 3. Scope

**IN SCOPE (desktop/server):**
- New public `RuntimeProviderService` + DTOs over `GET/PUT/DELETE /v1/providers`.
- Host-facing list/get/upsert/delete for a `.local`/`.remote` Runtime Server
  (the runtime has disk `<root>/.codeagent/settings.json`; writes apply, §4.4).
- Reuse of the existing bearer auth, envelope decoding, and client construction
  (`RuntimeHTTPClient`, `RuntimeEnvironment`, credential stores).
- Feed `UnifiedModelCatalogStore`/catalog UI from `/v1/runtime/models` + providers.

**OUT OF SCOPE (iOS embedded):**
- No disk settings.json → `/v1/providers` **write is not applicable**; provider
  config continues via host-injected `Options.SettingsJSON` /
  `configureProviderConnections` / `buildConnectionsJSON`.
- `ProviderConnectionRegistry` remains the iOS write path and default read path.
- Possibly out of scope for stage ③: the registry's desktop deprecation/migration
  tooling (list in 4.2) — flag for a follow-up stage.

---

## 4. Risks

1. **Dual-write (local registry + HTTP).** Two writers = two truths. Must pick
   exactly one authoritative path per platform. Recommended: HTTP on desktop,
   registry on iOS, and a compile-time/plumbed choice, never both. The runtime
   itself is single-writer on desktop (flock on settings.json), so the SDK must
   route all desktop writes through `/v1/providers`.
2. **Migration of existing local connections.** Existing
   `agentkit.provider_connections.v1` entries must be PUT into the runtime once.
   Open questions: trigger (first successful preflight? explicit host action?),
   conflict policy when the runtime already has a provider with the same id
   (last-write-wins vs error), and whether migration runs before the old
   injected-settings path is removed.
3. **enable/disable semantics.** Current `isEnabled: Bool` (registry keeps the
   record, flips a flag) vs providers `{id → definition}` presence/absence
   (DELETE removes the config entirely). Deleting a disabled provider loses its
   definition. Need explicit design: either (a) providers DTO carries an
   `enabled` flag, or (b) "disable" = remove from runtime + retain in a local
   draft store, or (c) hosts never disable, only delete. **Must be specified in
   the contract before implementing** — the current `setEnabled` API has no HTTP
   analogue.
4. **Structural change vs restart.** The SDK's `RuntimeProviderConfigurationApplyQueue`
   gates structural changes behind idle + stop/configure/start. `/v1/providers`
   PUT triggers the runtime's Reconfigure callback **with rollback** (live, no
   restart). The SDK must await the runtime's Reconfigure result and surface
   failure/rollback instead of managing its own restart; the apply-queue becomes
   desktop-irrelevant for providers (still relevant for iOS injection).
5. **Secrets.** GET strips secrets; PUT must send credential **references**
   (`credential.env`/`source`), not values — consistent with `ProviderConnection`
   (values live in `CredentialStore`, never in the registry/settings). The SDK
   must not log or persist returned definitions that contain secret echoes.
6. **Embedded capability detection.** On iOS the embedded runtime may serve
   `GET /v1/providers` (from injected settings) but reject writes (§4.4).
   `RuntimeProviderService` should detect this (e.g. `RuntimeHTTPError.unsupported`
   / 404 / capability flag) and fail fast with a clear error rather than
   half-applying.
7. **New `headers` field.** No current `ProviderConnection` equivalent — needs an
   optional `headers` property + validation (no Authorization header injection
   from host headers), and a decision on whether `settings.json` template and
   `buildConnectionsJSON` also emit it (consistency across the two encodings).
8. **`ProviderConnection` fields with no DTO slot** (`providerID`, `displayName`,
   `allowsInsecurePrivateNetworkHTTP`, `modelSource`). If the runtime's providers
   DTO drops them, round-tripping a definition back to `ProviderConnection`
   loses data — specify a lossless mapping or an explicit "desktop uses DTO,
   iOS uses ProviderConnection" split.

---

## 5. Files this stage would touch (implementation, not done)
- `Sources/AgentKit/Core/Providers/ProviderService.swift` (new) — service + DTOs.
- `Sources/AgentKit/Core/RuntimeHTTPClient.swift` — add `v1/providers` endpoints
  (or keep them in the service; prefer extending the client for consistency).
- `Sources/AgentKit/Core/Providers/ProviderConnection.swift` — optional `headers`
  (if adopted).
- `Sources/AgentKit/Core/Providers/RuntimeProviderConfigurationBuilder.swift` —
  reuse of `RuntimeConnectionDefinition` types; possible `headers` emission.
- Tests: `ProviderServiceTests` (mocked transport), mapping tests.
