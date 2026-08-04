# Impact: Provider/Model/Credential Flattening on the AgentKit SDK

Status: READ-ONLY impact research (no source modified).
Scope: AgentKit Swift SDK (this workspace). Runtime-side design docs
(`design-connection-flattening.md`, `design-connection-injection-channel.md`) live
in the code-agent workspace and were not read; all findings below are grounded in
AgentKit source.

## 1. How AgentKit bridges config to the runtime

| Concern | File | Detail |
|---|---|---|
| Runtime host abstraction | `Sources/AgentKit/Core/AgentRuntime.swift` | `AgentRuntime.shared`, `EmbeddedRuntimeConfiguration`, `configure(_:)`, `configureProviderConnections(_:)`, `ensureStarted/start/launch`, `reconfigure(secretsJSON:modelName:)`, `restart()`. Holds `injectedSecretsJSON` and `startupModelNameOverride` between launches. |
| gomobile boundary | `.build/.../CodeAgentRuntime.framework/.../Headers/Mobile.objc.h` (generated; also embedded in `CodeAgentRuntime.xcframework`) | `MobileStart(workspaceDir, dataDir, configYAML, modelName, secretsJSON, serverAccessToken, addr, sandboxed, error)` and `reconfigure(secretsJSON:modelName:error)`. Header doc: "Reconfigure hot-swaps API keys and/or the model without dropping the server or changing the port (v1.2 §3.3)". |
| Config document builder | `Sources/AgentKit/Core/Providers/RuntimeProviderConfigurationBuilder.swift` | `GeneratedRuntimeProviderConfiguration` (configYAML, models, defaultModelID, defaultRuntimeAlias, isEmptyCatalog). `RuntimeConfigDocument` emits `default_model`, `credentials` (`{namespace: {name: {source: "injected"}}}`), `models` (alias → `{provider, base_url, model, credential:{namespace,name}, context_window, pricing}`), plus `agent/provider/web/runtime/currency` blocks. |
| Bundled static config | `Sources/AgentKit/Resources/config.yaml` | Gateway-by-default doc; `credentials.gateway.default` + `credentials.llm.{deepseek,qwen,glm}` with `source: env` + `env: DEEPSEEK_API_KEY` etc.; `models.{gateway,deepseek,deepseek-pro}` with `credential: {namespace, name}` refs. |
| Structural apply queue | `Sources/AgentKit/Core/Providers/RuntimeProviderConfigurationApplyQueue.swift` | Coalesces structural (stop/configure/start) changes until idle; only handles the *full config document* path — there is no hot-swap channel today other than secrets. |

Key point: **connection DEFINITIONS already flow through `configYAML` at start** (the
`credentials` + `models` blocks built by `RuntimeProviderConfigurationBuilder`), and
only *values* flow through `secretsJSON`. Flattening's `connectionsJSON` channel
replaces exactly the definition-carrying portion of the start-time document with a
hot-swappable one.

## 2. secretsJSON serialization

| Concern | File | Detail |
|---|---|---|
| Key encoding | `Sources/AgentKit/Core/Credential/CredentialTarget.swift` | `id` = `namespace/name` (urlPathAllowed minus `/`, i.e. `/` percent-encoded); `init?(id:)` reverse-decodes with `removingPercentEncoding`. Doc comment: "must match Go `Target.String()` exactly". Presets: `gateway` (`gateway/default`), `llm(name)`, `mcp(name)`, `runtimeAccess(connectionID)`. |
| Map → wire | `Sources/AgentKit/Core/Credential/CredentialMap.swift` | `toSecretsJSON()`: top-level `[String:String]` keyed by `CredentialTarget.id`; each value is an **inner JSON string** `{"type": ..., "secret": ..., "expires_at": ...}` (`expires_at` = Unix seconds, nullable, key omitted when nil). `refresh_token` never injected. |
| Value shape | `Sources/AgentKit/Core/Credential/Credential.swift` | `Credential(kind, secret, expiresAt, metadata)`; `strippedForInjection()` drops metadata. `CredentialKind` = bearer/secret/none. `isExpired`/`expiresWithin(seconds:)` used for pre-refresh decisions. |
| Injection call sites | `Sources/AgentKit/Core/AgentRuntime.swift` (lines ~217-243), `Sources/AgentKit/Core/Credential/CredentialSettings.swift` | `ensureStarted(with:)`, `reconfigure(with:)`, `launch(secretsJSON:)` all build `map.toSecretsJSON()`. `AgentSettings.secretsJSON()` is a **legacy second path** with env-var-style keys (`DEEPSEEK_API_KEY`, `TAVILY_API_KEY`) — flat strings, no namespace. |
| Wire-format test | `Tests/AgentKitTests/CredentialMapTests.swift` | Locks `{type, secret, expires_at}` inner shape, no `kind`/`expiresAt`/`metadata`, and refresh_token absence. |

Note the two coexisting key schemes: new `namespace/name` (CredentialMap path) and
legacy env-var names (`AgentSettings` path, used as fallback in
`CredentialSettings.currentSecretsJSON()` and `AgentRuntime` when the map is empty).
Flattening must decide the fate of the legacy env-name keys.

## 3. /v1/runtime/models consumption

| Concern | File | Detail |
|---|---|---|
| HTTP fetch | `Sources/AgentKit/Core/RuntimeHTTPClient.swift` | `runtimeModels()` → `GET /v1/runtime/models`, decoded via `decodeEnvelope(RuntimeServerModelCatalog.self, from:)`. |
| DTOs | `Sources/AgentKit/Core/RuntimeServers/RuntimeServerModelCatalog.swift` | `RuntimeServerModelCatalog` (schema, revision, `default_runtime_alias`, connections); `RuntimeServerModelConnection` (id, `provider_id`, `display_name`, `billing_source`, models); `RuntimeServerModelDescriptor` (`runtime_alias`, `wire_model_id`, `display_name`, `context_window`, `supports_tools`, `supports_reasoning`, `input_modalities: [String]`, `available: Bool`). All fields non-optional — strict decode. |
| Schema guard | `Sources/AgentKit/Core/RuntimeServers/RuntimeServerCoordinator.swift` (~line 451) and `RuntimeServerPreflight.swift` (~line 230) | Both do `guard models.schema == "runtime-model-catalog/v1"` → `RuntimeServerPreflightError.invalidModelCatalogSchema`. **Hard exact-match check.** |
| Unified abstraction | `Sources/AgentKit/Core/Providers/UnifiedModelDescriptor.swift` | `UnifiedModelDescriptor` (SDK's cross-source model model), alias `provider.<b64>.model.<b64>` via `makeRuntimeAlias`, `parseRuntimeAlias` (b64url, padding-stripped). `RuntimeServerModelIdentity.stableID` = `runtime.<b64>.model.<b64>`. |
| Catalog store | `Sources/AgentKit/Core/Providers/UnifiedModelCatalogStore.swift` | Host-facing store: models, default model (UserDefaults key `agentkit.provider_models.default.v1`), descriptor lookup by id or runtimeAlias, `models(connectionID:)`. |
| Local embedded catalog | `Sources/AgentKit/Core/Providers/RuntimeProviderConfigurationBuilder.swift` | Embedded catalog is *generated* (not fetched): `build(connections:...)` → `GeneratedRuntimeProviderConfiguration.models`. The `RuntimeServerModelCatalog` path is used for embedded *and* external runtime servers alike. |
| Tests | `Tests/AgentKitTests/RuntimeServerConnectionsTests.swift`, `RuntimeSharingTests.swift` | Catalog/preflight coverage. |

`available` already exists on the descriptor, but `unavailable_reason` and
per-connection credential status/source are absent today — v2 additions land here.

## 4. auth_expired handling and Reconfigure re-injection

| Concern | File | Detail |
|---|---|---|
| Event routing | `Sources/AgentKit/Features/Conversation/ViewModels/ConversationViewModel.swift` (~line 619) | `handleEvent`: `case .turnFailed(_,_,_,let errorCode)` where `errorCode == "auth_expired"` → `recoverFromAuthExpiry()` (guarded by `isRecoveringAuth`). |
| Host hook | `Sources/AgentKit/Navigation/AgentDependencies.swift` (~line 28) | `onAuthExpired: (@MainActor () async -> Void)?` — "Host implements refresh token → Reconfigure Runtime (credential-injection-v1 §5.2)". |
| Re-injection | `Sources/AgentKit/Core/AgentRuntime.swift` | `reconfigure(secretsJSON:modelName:)` (Swift, no connectionsJSON), plus `reconfigure(with: any CredentialStore)` which re-serializes the whole map. `injectedSecretsJSON` persists across `restart()`. |
| Error code source | `Sources/AgentKit/Core/AgentEvent.swift`, `WireFrame.swift` | `errorCode` from structured `error.code`, open set incl. `auth_expired`. |

## 5. Public API surfaces affected by flattening

- `AgentRuntime.reconfigure(secretsJSON:modelName:)` and `launch/start/restart` — signature change to `(connectionsJSON, secretsJSON, modelName)`; gomobile `MobileStart`/`Mobile.reconfigure` ABI change.
- `CredentialTarget` `id` encoding + `init?(id:)` — Keychain account strings and UserDefaults use these ids.
- `CredentialMap.toSecretsJSON()` — key encoding change (flat connection id vs `namespace/name`).
- `RuntimeProviderConfigurationBuilder` / `GeneratedRuntimeProviderConfiguration` — definitions move from `configYAML` to `connectionsJSON` (new serialization needed).
- `RuntimeServerModelCatalog` / `RuntimeServerModelConnection` / `RuntimeServerModelDescriptor` — v2 fields (`unavailable_reason`, credential status/source) + schema string change.
- `UnifiedModelDescriptor` / `UnifiedModelCatalogStore` / `RuntimeServerModelIdentity` — the SDK's model/connection abstraction exposed to hosts; alias format `provider.<b64>.model.<b64>` must stay.
- `ProviderConnection.credentialTarget` (`gateway→gateway/default`, `apiKey→llm/<id>`) and `RuntimeProviderConfigurationApplyQueue` (structural vs hot-swap semantics).
- `AgentSettings`/`AgentSettingsStore` legacy env-name key path (fallback source of secretsJSON).

## Blockers

1. **gomobile ABI**: `MobileStart` and `Mobile.reconfigure` signatures change when a
   `connectionsJSON` parameter is added. The generated ObjC header (`Mobile.objc.h`)
   and the Swift call sites in `AgentRuntime.swift` (lines ~378, ~204) change
   together; every host embedding the `CodeAgentRuntime.xcframework` must rebuild.
   Cost: coordinated version bump (cf. `cb63a55 chore: bump CodeAgentRuntime to 1.3.2`).
2. **Two legacy key schemes**: `AgentSettings.secretsJSON()` emits env-var keys
   (`DEEPSEEK_API_KEY`) while the CredentialMap path emits `namespace/name`. A flat
   connection-id scheme cannot map the env-name keys without a runtime migration
   table. The design must specify whether the legacy path is dropped or bridged.
3. **Schema guard is exact-match**: two call sites hard-require
   `runtime-model-catalog/v1`; a v2 schema string fails preflight and blocks
   embedded-runtime context load. SDK must accept v1+v2 during the bridging period.
4. **Strict DTO decoding**: all `RuntimeServerModel*` fields are non-optional.
   v2 additions (`unavailable_reason`, per-connection credential status/source) must
   be optional or the DTOs updated in lockstep with the runtime.
5. **`CredentialTarget.id` is a stored identity**: used in Keychain accounts,
   `init?(id:)` parsing, and `toSecretsJSON` keys. Flattening keys changes persisted
   data; the bridging period must keep the SDK able to *emit both* or the runtime to
   *accept both*, and `init?(id:)` must tolerate flat ids without a `/`.
6. **Reconfigure gap**: today only secrets (and modelName) are hot-swappable;
   definitions require stop/configure/start via `RuntimeProviderConfigurationApplyQueue`.
   Flattening's `Reconfigure(connectionsJSON, secretsJSON, modelName)` makes the
   definition channel hot — the SDK's queue/restart logic and the
   "structural = restart required" contract in `configureProviderConnections` need a
   decision on which changes remain restart-only.
7. **`runtime_access` and MCP**: `runtime_access/<connectionID>` (never injected) and
   `mcp/<name>` (MCP stays independent) are namespaces the flattening must not
   collapse into `llm` — the SDK maps `ProviderConnection.credentialTarget` only to
   `gateway`/`llm`, but stores use all four namespaces.

## What the design must specify

- `connectionsJSON` schema: fields per connection (id, provider_id, display_name,
  transport/api type, base_url, model list with wire_model_id/context_window/pricing,
  authentication type) and the credential-source declaration (flat connection id +
  `source: injected|env`), plus `default_model`/default alias and empty-catalog shape.
- Bridging period rules: which secretsJSON key forms are accepted (flat, namespace/name,
  legacy env-name?), and for how long; how the SDK signals which form it emits.
- Catalog v2 field additions: `unavailable_reason`, per-connection
  credential status/source, schema string value, and whether old fields remain.
- Legacy `AgentSettings` env-name path: migrate to CredentialMap or delete.
- gomobile signature: parameter order and whether `connectionsJSON` is nullable
  ("" = keep current) mirroring `secretsJSON`/`modelName` semantics.

## Recommendations (what flattening must preserve for the SDK)

1. Preserve `CredentialTarget.id` (namespace/name) as a *stored identity* and the
   alias format `provider.<b64>.model.<b64>` — both are persisted (Keychain,
   UserDefaults `agentkit.provider_models.default.v1`, transcript/reference history)
   and parsed by `UnifiedModelDescriptor.parseRuntimeAlias`.
2. Keep the secretsJSON **value** shape `{"type","secret","expires_at"}` and the
   refresh_token exclusion; only keys flatten. `CredentialMapTests` locks this shape.
3. Make schema acceptance prefix-based (`runtime-model-catalog/v1` and a v2 value)
   during bridging; add v2 fields as optionals so old SDK binaries tolerate new
   runtimes and vice-versa.
4. Reconfigure should keep `"" = keep current` semantics for all three parameters,
   and the SDK's `injectedSecretsJSON` persistence should generalize to a persisted
   `(connectionsJSON, secretsJSON)` pair so `restart()` survives.
5. Expose the definition channel as a first-class Swift type (e.g.
   `ConnectionsJSON` / `RuntimeConnectionDefinition` encoded like
   `RuntimeProviderConfigurationBuilder` does today) rather than raw strings, so
   hosts never hand-assemble the wire format.
6. Keep `UnifiedModelDescriptor`/`UnifiedModelCatalogStore` as the host-facing model
   abstraction; flattening the wire must not leak connection-id plumbing into hosts
   that already consume the unified model.
7. Preserve `ProviderConnection.credentialTarget` mapping semantics (`gateway`,
   `llm/<id>`) so the SDK can emit both the flat and namespaced secretsJSON forms
   during the bridging period from a single source of truth.
