# AgentKit Conversation Web Workbench v1

> Status: Accepted — Phase 0–8 implementation is present; Web is the eligible macOS default with native rollback
> Date: 2026-07-14
> Scope: Conversation detail renderer on macOS; iOS remains on the native renderer until parity is proven.

Implementation baseline added to the working tree on 2026-07-14:

- `native / web / auto` renderer policy with `.auto` selecting Web only when every active
  Timeline extension supplies semantic Web nodes;
- one private-scheme `WKWebView` shell per active conversation;
- a versioned Swift document builder and ready/apply/ack bridge;
- bundle-local React + TypeScript + GFM Markdown renderer with CSP;
- continuous DOM selection plus local code/table horizontal overflow;
- CSS-only hover/pressed/focus states without Swift bridge traffic;
- Web process reload from the latest Swift document;
- a stable opaque action registry reusing native artifact/asset/file/URL/child-stream/copy
  dispatch, with conversation/revision validation and stale-token rejection;
- file and runtime-resource annotations, per-tool artifacts/assets/output actions, per-code
  and per-turn copy, and native turn-assets Inspector routing;
- revisioned reset/patch envelopes that preserve unchanged turn DOM nodes;
- logical DOM selection anchors plus code/table horizontal offsets and tool expansion state
  restored across tail patches;
- browser-owned pinned/unpinned scrolling, visible-anchor preservation, resize handling,
  forced bottom on a new turn, and jump-to-latest;
- automated private-scheme load, handshake, two-turn render, selection CSS, initial reveal,
  narrow-viewport overflow, streaming selection preservation, stable-turn identity,
  unpinned growth, and new-turn pin verification in a real `WKWebView`.
- semantic `TimelineWebNode` cards/sections/rows/badges/actions, with host action IDs hidden
  behind the current revision's opaque registry;
- `DesktopControlEvidenceTimeline` Web migration and native Inspector documents; HTML
  documents remain outside the conversation DOM in a script/network/navigation-blocked view;
- semantic accessibility, focus restoration that never destroys a text selection,
  reduced-motion/high-contrast styling, expanded CSP and private-scheme allowlisting;
- 500-turn render plus 25 rapid tail patches, raw-HTML rejection, semantic/a11y checks,
  apply-duration diagnostics, repeated-process-failure fallback, and CodeAgent app build.

The default switch is eligibility-gated, not unconditional. `.auto` and `.web` use the Web
workbench only when every active extension conforms to `WebTimelineExtension`; legacy
`AnyView` extensions, shell failure, or three Web process terminations within 30 seconds
fall back to `MacNativeChatTimeline`. The native renderer remains available through the
stability window. Manual VoiceOver product QA and production telemetry monitoring remain
release operations rather than architecture blockers.

## 1. Decision

AgentKit will evolve the macOS conversation detail from a native row-based transcript
(`NSTableView` + one TextKit document per turn) to a **single Web document per active
conversation**, embedded in the existing native SwiftUI/AppKit shell through one
`WKWebView`.

This is a renderer and interaction-boundary change, not a runtime or product-shell
rewrite:

- Swift remains the source of truth for runtime state, turn projection, approvals,
  inspectors, files, assets, navigation, and security decisions.
- The native composer, approval bars, toolbar, sidebar, and inspectors remain native.
- The Web document owns the conversation's vertical scroll viewport, DOM rendering,
  continuous selection, Markdown layout, code/table horizontal overflow, and inline
  tool interactions.
- The current native renderer remains available behind a renderer switch until the
  Web workbench has passed parity, performance, accessibility, and recovery gates.

The goal is to align with the interaction model validated by current coding-agent
workbenches: **one continuous document with stable block identities**, rather than a
collection of independently measured rich-text cells. We are not adopting Electron;
`WKWebView` supplies the relevant Web document behavior inside AgentKit's native app.

## 2. Reference finding and limits

The current ChatGPT/Codex desktop application inspected on 2026-07-14 is a
Chromium/Electron-family application, not a `WKWebView` application. Its bundle contains
`app.asar`, `ElectronAsarIntegrity`, a Chromium base version, and dedicated renderer/GPU/
network processes. Accessibility exposes one `AXWebArea` covering the main window.

The useful reference is therefore its **document topology**, not its exact shell:

```text
one main Web document
  -> sidebar and workbench DOM
  -> conversation DOM
       -> turn nodes
       -> Markdown nodes
       -> code/table overflow regions
       -> interactive tool nodes
```

Accessibility cannot prove private DOM implementation details, framework choice, or
virtualization strategy. AgentKit's design must be justified by its own requirements and
tests, not by assumptions about an external application's internals.

## 3. Why change

The current native implementation has successfully solved several difficult behaviors:

- synchronous row sizing;
- initial bottom positioning without a visible top-to-bottom scroll;
- bottom following during streaming and tool expansion;
- yielding the viewport when the user scrolls away;
- selection preservation during incremental TextKit updates;
- stable cell reuse and redraw during large scrolls;
- live/history rendering through the same `ConversationTurn` model.

Those improvements also expose the structural cost of the current renderer. Viewport
width, TextKit layout width, row height, block decoration, selection, cell reuse, and
outer scrolling are coupled. A code block or table cannot naturally own horizontal
overflow without adding custom TextKit geometry and gesture routing. Richer content such
as equations, complex tables, interactive diffs, nested tool output, and media will keep
increasing that coupling.

A single Web document makes the desired primitives native to the renderer:

- one browser selection across the whole conversation;
- `overflow-x: auto` per code/table/diff block;
- semantic HTML for headings, lists, tables, code, links, and accessibility;
- stable keyed components for turns and tools;
- DOM patching of only the streaming tail;
- one scroll owner with browser-clamped geometry, eliminating row-height negotiation.

## 4. Goals

### 4.1 Primary goals

1. Continuous native browser selection across user prompts, assistant text, code,
   tables, tools, and multiple turns.
2. Code, table, terminal, JSON, and diff blocks maintain a useful minimum layout width
   and scroll horizontally when the viewport is narrower.
3. Preserve or improve every current bottom-follow and viewport-ownership behavior.
4. Preserve the chronological `ConversationTurn -> TurnBlock` model and all tool,
   artifact, asset, child-stream, and link interactions.
5. Apply streaming updates incrementally without reloading the page, resetting selection,
   losing horizontal offsets, or flashing old content.
6. Keep Swift authoritative for application state and privileged actions.
7. Establish a renderer architecture that can add math, richer tables, structured diffs,
   media, and extension content without another container rewrite.

### 4.2 Success criteria

- No visible initial render at the top of a long conversation.
- No blank overscroll or bounce introduced by streaming, resizing, inspector changes, or
  approval/composer height changes.
- A user selection outside the active patch remains byte-for-byte stable while tokens
  stream.
- A selection spanning a patched node is restored to equivalent logical text anchors.
- Browser copy of a cross-block selection produces clean text without button labels or
  hidden UI chrome.
- A 320-pt conversation viewport shows non-overlapping code/table content with local
  horizontal scrolling.
- Tool actions have functional parity with `TranscriptAction`.
- Live and history snapshots generate the same Web document structure.
- The latest completed turn and the live turn update without rebuilding earlier turns.
- Web content process termination can reconstruct the latest document without losing
  runtime state.

## 5. Non-goals

- Rewriting the entire app in Electron or moving runtime/business state into JavaScript.
- Replacing the native composer, approvals, toolbar, sidebar, inspectors, or workspace
  management.
- Changing the Agent Wire protocol or `ConversationTurn` projection solely for rendering.
- Loading renderer code, fonts, syntax highlighters, or math libraries from a CDN.
- Supporting arbitrary host-provided JavaScript inside the conversation document.
- Removing `MacNativeChatTimeline` before Web parity and fallback gates pass.
- Migrating iOS in the first release slice.

## 6. Behavior contract inherited from the native timeline

The Web workbench must treat the following as compatibility requirements, not optional
polish.

| Area | Required behavior |
| --- | --- |
| Initial open | Build the initial DOM, set the final viewport to the bottom, then reveal. Never render at the top and animate down. |
| Pinned growth | While pinned, token streaming, tool expansion, todo changes, and the live indicator keep the bottom attached. |
| Reader ownership | A user scroll away from the bottom unpins immediately. Background updates must not move the reader. |
| Re-pin | Returning within the bottom tolerance re-pins. A new user turn always re-pins. |
| Conversation switch | A newly selected conversation gets independent scroll and expansion state and opens at its bottom. |
| Resize | Window/inspector/composer resizing must not bounce, overshoot, or change pin state. |
| Selection | Streaming never clears a selection in stable content. Selection may span every block in the document. |
| Tool state | Expand/collapse is keyed by stable group/call IDs and survives unrelated patches. |
| Horizontal overflow | Horizontal input over an overflowing block scrolls that block; vertical input continues to scroll the conversation. |
| Live/history | Both paths render from the same projected turn/block model. |
| Recovery | Renderer reload or Web process termination reconstructs from the latest Swift snapshot. |

The existing `MacNativeChatTimeline` and `FollowingScrollView` remain the executable
reference for these behaviors during migration.

## 7. Target architecture

```text
ConversationDetailView (SwiftUI)
  |- native archived/paused bars
  |- ConversationWorkbenchView
  |    `- ConversationWebView (one WKWebView for the active conversation)
  |         |- Web document scroll owner
  |         |- React/TypeScript renderer
  |         |- keyed turn/block/tool DOM
  |         |- selection + scroll-anchor controller
  |         `- Swift <-> Web action bridge
  `- native safe-area bottom content
       |- plan approval bar
       |- tool approval bar
       |- workspace chip
       `- native composer

RuntimeSnapshot (Swift)
  -> existing Turn projection
  -> ConversationWebDocumentBuilder
  -> revisioned Web document operations
  -> ConversationWebCoordinator
  -> JavaScript applyOperations(...)
```

### 7.1 One WebView per conversation, not per turn

The active detail owns exactly one `WKWebView`. Turns, tool groups, code blocks, and
tables are DOM nodes, not nested WebViews.

This is necessary for:

- selection across turns;
- one vertical scroll owner;
- no asynchronous per-row height callbacks;
- native nested horizontal overflow;
- stable DOM state keyed by turn/block/call IDs;
- lower WebView lifecycle and memory overhead.

`ConversationTimelineView.id(conversationID)` continues to scope workbench state. On a
conversation switch the coordinator loads or reconstructs that conversation's document.

### 7.2 Renderer technology

The embedded renderer will use a small, bundle-local **TypeScript + React** application.
React is used for maintainable tool/turn components and keyed subtree preservation; it
does not own application business state.

Constraints:

- compiled JS/CSS assets are bundled with AgentKit;
- dependency versions and the package manager lockfile are committed;
- release builds require no Node installation;
- source lives beside the renderer, and CI rebuilds assets and verifies no generated
  diff;
- completed turn components are memoized and do not re-render during tail streaming;
- selection/scroll preservation does not rely on React behavior alone.

The first version should avoid a general plugin runtime or arbitrary page scripts.

## 8. State ownership

### 8.1 Swift-owned state

Swift remains authoritative for:

- `RuntimeSnapshot` and `[ConversationTurn]`;
- tool status, args, output, artifacts, and assets;
- tool group and call expansion state;
- open inspector/navigation decisions;
- approval and plan decisions;
- active conversation identity;
- renderer revision and recovery snapshot;
- timeline-extension data and actions;
- allowed URL/resource schemes.

### 8.2 Web-owned ephemeral state

The Web document may own only presentation-local state that can be recreated:

- DOM focus and hover;
- current selection range;
- per-block `scrollLeft`;
- Web viewport `scrollTop` and pin state;
- transient copy feedback;
- locally ticking elapsed labels derived from Swift timestamps.

When Web state changes product semantics (for example tool expansion), the page emits an
action and Swift updates the authoritative state. The page may optimistically update for
responsiveness, but must reconcile with the next Swift revision.

## 9. Web document model

Introduce a renderer-specific, `Codable` presentation model. It must not expose raw
runtime objects directly.

```swift
struct ConversationWebDocument: Codable, Equatable {
    let conversationID: String
    let revision: UInt64
    let turns: [WebTurn]
    let todo: WebTodo?
    let liveIndicator: WebLiveIndicator?
}

struct WebTurn: Codable, Equatable, Identifiable {
    let id: String
    let userPrompt: WebMessage?
    let blocks: [WebTurnBlock]
    let footer: WebTurnFooter?
    let actions: [WebActionReference]
}

enum WebTurnBlock: Codable, Equatable {
    case markdown(WebMarkdownBlock)
    case toolGroup(WebToolGroup)
    case artifact(WebArtifactRow)
    case system(WebSystemRow)
    case childStream(WebChildStreamRow)
}
```

Rules:

- IDs derive from `turn.id`, `TurnBlock.id`, `ToolGroup.id`, `callID`, and child IDs.
- Do not use Swift `hashValue`; it is not stable across process launches.
- Markdown sub-block IDs use their parent `TurnBlock.id` plus structural index and a
  deterministic content digest when needed.
- The builder reuses `ToolTranscriptPresenter`, `AssetIndex`, and current artifact
  semantics so native and Web renderers do not invent different tool meaning.
- Text blocks carry raw Markdown plus structured text annotations/assets needed to turn
  paths, URLs, runtime resources, and artifacts into opaque Swift actions.
- Runtime-provided raw HTML is never injected into the main document.

### 9.1 Markdown rendering

The Web renderer may use a locked, GFM-capable Markdown pipeline, but it must consume the
same `TurnBlock.text` boundaries as the native renderer. Security requirements:

- raw HTML disabled by default;
- sanitized output with a fixed allowlist;
- links converted to opaque action IDs;
- code inserted as text, never executable HTML;
- active streaming blocks may defer expensive syntax highlighting until structurally
  stable;
- completed Markdown blocks are memoized.

Swift-side Markdown tests remain useful for projection semantics during migration. New
renderer fixtures become the source of truth for Web HTML and copy output.

## 10. Revisioned update protocol

The initial page shell loads once. Normal updates must never call `loadHTMLString` again.

Swift sends ordered operations with a monotonically increasing revision:

```swift
enum ConversationWebOperation: Codable {
    case reset(ConversationWebDocument)
    case insertTurn(WebTurn, after: String?)
    case removeTurn(id: String)
    case updateUserPrompt(turnID: String, message: WebMessage)
    case upsertBlock(turnID: String, block: WebTurnBlock, after: String?)
    case removeBlock(turnID: String, blockID: String)
    case updateTool(callID: String, tool: WebTool)
    case updateFooter(turnID: String, footer: WebTurnFooter?)
    case updateTodo(WebTodo?)
    case updateLiveIndicator(WebLiveIndicator?)
    case updateTheme(WebTheme)
}
```

Protocol rules:

1. JS applies a batch only when `revision == currentRevision + 1`.
2. A stale batch is discarded; a gap requests a full `reset` from Swift.
3. Snapshot publications are coalesced to the display cadence so token events do not
   cause unbounded `evaluateJavaScript` calls.
4. The differ normally touches only the live turn and active text/tool block.
5. Completed turn DOM nodes remain mounted and unchanged.
6. JS acknowledges applied revisions and reports patch duration/error metadata.
7. A Web process restart uses the latest full Swift document, not replayed UI mutations.

## 11. Selection and copy contract

Selection is a product feature and a release gate.

### 11.1 Stable selection anchors

Before a destructive DOM patch, the page records both endpoints as logical anchors:

```text
{ stableNodeID, UTF16TextOffset, affinity }
```

After the patch it resolves those anchors into the new DOM and restores the `Range`.
Rules:

- if neither endpoint is in a changed subtree, do not touch the browser selection;
- if an endpoint is in a changed subtree, restore by logical text offset;
- if content before the endpoint was deleted, clamp to the nearest valid position;
- do not move focus or collapse a non-empty range merely because tokens arrived;
- selection restoration must work across nested inline elements and syntax spans.

### 11.2 Copy output

- UI chrome (`copy`, chevrons, status controls) uses `user-select: none` and appropriate
  accessibility labels.
- Browser default copy is retained for ordinary selections.
- A document-level `copy` handler normalizes table cells, code, and hidden/collapsed
  content only when necessary.
- Per-code-block and per-turn copy actions use the Swift-owned canonical copy text.
- Copy tests assert plain text, not implementation-specific HTML clipboard markup.

### 11.3 Pointer, hover, and click/selection arbitration

Every actionable DOM node exposes consistent `rest -> hover -> pressed` and
`focus-visible` states. Hover is presentation-only and never crosses the JS/Swift bridge;
only an explicit click or keyboard activation sends an action.

- normal transcript content uses `user-select: text`;
- only UI chrome such as chevrons and copy icons uses `user-select: none`;
- inline links use semantic anchors so WebKit arbitrates click versus drag selection;
- an entire clickable row fires only when pointer movement stays below the click threshold
  and the browser selection is collapsed;
- `pointerdown` must not call `preventDefault()` on selectable transcript content;
- custom tooltips appear after 300–400 ms, avoid viewport edges, close on `Escape`, and
  expose their content with `aria-describedby`;
- hover and active states never use scale transforms that shift text or selection geometry;
- disabled elements do not advertise hover affordance.

Acceptance gate: dragging across any actionable link/tool row must neither collapse the
range nor dispatch the action when the pointer is released.

## 12. Scroll contract

The Web document is the sole vertical scroll owner. No outer `NSTableView` or SwiftUI
`ScrollView` wraps it.

### 12.1 Pin state

```text
initial state                 -> pinned
user scrolls > tolerance away -> unpinned
user returns to bottom         -> pinned
new user turn inserted         -> force pinned
content grows while pinned     -> preserve zero bottom distance
content grows while unpinned   -> preserve visible anchor
```

User ownership is derived from wheel/touch/keyboard input plus scroll events, not from
content size changes. Programmatic scrolling is marked so it cannot alter user intent.

### 12.2 Initial reveal

1. Keep the page root hidden.
2. Apply the full initial document.
3. Wait for layout/fonts for the first stable frame.
4. Set `scrollTop = scrollHeight` without animation.
5. Reveal the page.

This replaces the native timeline's `alphaValue`/row-height reconciliation with an
equivalent no-flash contract.

### 12.3 Unpinned anchor preservation

Before applying patches while unpinned, record the first visible stable block ID and its
offset from the viewport top. Restore that anchor after layout. Do not rely solely on CSS
scroll anchoring because tool expansion and Markdown restructuring can choose an
undesired anchor.

### 12.4 Composer and approval resize

The native safe-area content changes the WebView frame. A `ResizeObserver`/viewport
notification applies:

- pinned: restore bottom distance to zero;
- unpinned: keep the visible stable block at the same screen position;
- never change pin state due to resize alone.

### 12.5 Horizontal overflow

```css
.block-scroll {
  max-inline-size: 100%;
  overflow-x: auto;
  overscroll-behavior-inline: contain;
}

.block-scroll > pre {
  inline-size: max-content;
  min-inline-size: max(100%, 35rem);
  white-space: pre;
}

.table-scroll > table {
  inline-size: max-content;
  min-inline-size: max(100%, 40rem);
}
```

Initial desktop design tokens:

- code/terminal/diff minimum content width: 560 pt equivalent;
- table minimum content width: 640 pt equivalent;
- long table cells wrap within a capped column instead of widening without limit;
- vertical trackpad input scrolls the conversation; horizontal input over a block scrolls
  that block using browser-native gesture arbitration.

## 13. Tool and workbench interactions

The Web renderer must cover every existing `TranscriptAction`:

| Current action | Web behavior | Swift owner |
| --- | --- | --- |
| `toggleTool` | Expand/collapse keyed group or call | Workbench UI state |
| `openArtifact` | Open native file/diff/directory/terminal inspector | `TurnActionDispatcher` successor |
| `openAsset` | Open native asset inspector or external URL | Swift |
| `openURL` | Validate scheme, then system open | Swift |
| `openPath` | Resolve artifact/asset or copy fallback | Swift |
| `openChildStream` | Open native child-stream inspector | Swift |
| `copyBlock` | Copy canonical source text | Swift |

The page sends only opaque IDs:

```json
{
  "version": 1,
  "type": "action",
  "conversationID": "...",
  "revision": 42,
  "actionID": "turn:.../action:..."
}
```

Swift resolves `actionID` in the latest action registry. Messages with an old conversation,
unknown action, stale incompatible revision, invalid schema, or disallowed URL are ignored
and logged.

### 13.1 Native interactions that stay outside the page

- plan approval bar;
- tool approval bar;
- pause/archive/resume bars;
- composer and stop/send controls;
- workspace chip;
- inspector panes;
- toolbar and global pending-approval navigation.

Todo content and the live thinking/timer indicator move into the Web document so they
participate in the same scroll geometry. Their clocks run locally in JS from Swift-provided
timestamps instead of requiring a Swift snapshot every second.

## 14. Timeline extension migration

The current extension API returns `AnyView`, which cannot be inserted into one Web
document:

```swift
func makeContent(for turnID: String) -> AnyView?
```

Introduce a semantic Web-capable companion protocol while keeping the existing protocol
source-compatible:

```swift
public protocol WebTimelineExtension: TimelineExtension {
    func makeWebNode(for turnID: String) -> TimelineWebNode?
    func handleWebAction(_ action: TimelineWebAction) async
}
```

`TimelineWebNode` is a safe, Codable schema containing cards, sections, rows, badges,
Markdown, media references, and opaque actions. It does not accept arbitrary JavaScript.
Any HTML document fallback is sandboxed, script-disabled, sanitized, and opened in an
inspector rather than injected into the main document.

Rollout rule:

- Web mode is eligible only when every active timeline extension conforms to
  `WebTimelineExtension`.
- Otherwise `.auto` renderer mode falls back to `MacNativeChatTimeline`.
- Migrate `DesktopControlEvidenceTimeline` first and use it as the reference extension.
- Deprecate `AnyView` only after all shipped hosts support the semantic contract.

Native overlays synchronized to DOM positions are explicitly rejected; they create two
scroll/layout systems and repeat the problem this project is trying to remove.

## 15. Security

- Bundle all renderer assets; no CDN or arbitrary remote script execution.
- Apply a strict Content Security Policy.
- Disable raw Markdown HTML unless sanitized by the fixed allowlist.
- Register a custom `agentkit-resource://` scheme for authorized local/runtime resources.
- The scheme handler resolves opaque resource IDs; Web content never receives unrestricted
  filesystem access.
- Intercept all navigation and new-window requests. HTTP(S)/file actions go through Swift
  validation and existing dispatch rules.
- Validate every bridge message by version, conversation ID, revision, action ID, and size.
- Use weak script-message handler wrappers to avoid retaining the WebView/coordinator.
- Disable development inspection in production builds.
- Recover from `webViewWebContentProcessDidTerminate` using the latest Swift document.

## 16. Accessibility

The renderer must expose semantic content rather than hiding the transcript subtree:

- one `<main>` for the conversation;
- one `<article>` per turn with meaningful labels;
- real headings, lists, `<pre><code>`, `<table>`, `<th scope>`, and buttons;
- keyboard activation for all interactive controls;
- stable focus after expansion and patches;
- `aria-live` limited to a throttled status indicator, not every streamed token;
- reduced-motion, high-contrast, zoom, and system font-size support;
- no `aria-hidden` on selectable conversation content;
- VoiceOver and keyboard selection included in release gates.

## 17. Performance strategy

Do not begin with turn virtualization, because unmounting DOM breaks whole-document
selection, browser find, and accessibility.

Start with:

- immutable completed turn subtrees;
- memoized React components;
- coalesced operation batches;
- collapsed tool details not mounted until expanded;
- deferred highlighting for the active streaming block;
- bounded rendering for extremely large tool outputs with explicit “open in inspector”;
- CSS containment only after accessibility and selection testing.

Measure before introducing DOM windowing. If very long conversations require
virtualization, it needs a separate design that preserves semantic copy/search and locks
mounted ranges while a selection is active.

Record at minimum:

- shell load and initial reveal latency;
- operation batch size and apply duration;
- stale/gapped revision count;
- selection restore failures;
- scroll-anchor corrections;
- Web process termination/recovery count;
- DOM node count and memory for representative long conversations.

## 18. Renderer selection and rollback

Introduce an internal renderer mode:

```swift
enum ConversationRendererMode {
    case native
    case web
    case auto
}
```

- Development builds expose an explicit switch.
- Production uses `.auto`, selecting Web when every active extension is semantic.
- Unsupported timeline extensions, shell load failure, or repeated Web process failure
  select the native renderer.
- The mode is injected/configured by the host; it is not silently changed by runtime data.
- A renderer switch reconstructs from `RuntimeSnapshot`; it never changes conversation
  state or sends runtime commands.

`MacNativeChatTimeline`, `NativeTranscriptView`, and their tests are retained through at
least one stable release after Web becomes the default.

## 19. Implementation plan

Each phase must be independently buildable and reviewable.

Implementation checkpoint (2026-07-15):

| Phase | Current state |
| --- | --- |
| 0–1 | Core contract, renderer switch, private-scheme shell, bridge, bundled renderer, recovery, and integration test are implemented. |
| 2 | Turn/block/tool/todo/live projection is implemented; broader visual and HTML fixture coverage remains. |
| 3 | Opaque registry and native action/Inspector routing are implemented; the exhaustive action and keyboard matrix remains. |
| 4 | Revisioned tail patches, resync, logical selection anchors, horizontal offsets, expansion state, and unchanged-turn identity are implemented and integration-tested. |
| 5 | Initial reveal, pin ownership, unpinned anchors, resize restoration, jump-to-latest, and new-turn force-pin are implemented; the full manual/native parity matrix remains. |
| 6 | Implemented: semantic extension schema/action routing, Desktop Control evidence migration, native document Inspector, and legacy eligibility fallback. |
| 7 | Core hardening implemented: semantic roles/names, stable keyboard focus, selection priority, reduced motion/contrast, CSP and scheme allowlist checks, 500-turn/rapid-patch stress, recovery/apply diagnostics. Manual VoiceOver QA and production monitoring continue. |
| 8 | Eligible macOS configurations now default to Web through `.auto`; legacy extensions and repeated renderer failures fall back to native. Native code is intentionally retained for the stability window. |

### Phase 0 — Characterization and contracts

- Land this design decision.
- Convert the behavior table in section 6 into a manual/automated parity checklist.
- Add fixtures covering long history, streaming Markdown, wide code/table, grouped and
  parallel tools, failed tools, assets, child streams, todos, and extensions.
- Record native renderer reference behavior and performance.
- Add `ConversationRendererMode` with native behavior unchanged.

Exit gate: no user-visible change; native regression suite is green.

### Phase 1 — Web shell and bridge skeleton

- Add `ConversationWebWorkbenchView` / `ConversationWebCoordinator`.
- Add bundled HTML/TypeScript/React/CSS assets and deterministic build verification.
- Configure one `WKWebView`, CSP, navigation policy, theme injection, and process recovery.
- Render static fixture content and prove one-document cross-turn selection.
- Add a versioned Swift/JS handshake and operation acknowledgement.

Exit gate: fixture opens at bottom without flashing; code/table overflow and selection
work; no runtime actions yet.

### Phase 2 — Presentation model and static parity

- Add `ConversationWebDocument` and builder from `RuntimeSnapshot.turns`.
- Port user bubbles, Markdown, tool summaries/details, system/error rows, child streams,
  footer, todo, and live indicator.
- Reuse `ToolTranscriptPresenter`, asset resolution, annotations, and canonical copy text.
- Add Swift model tests and Web component/HTML snapshots.

Exit gate: history snapshots achieve visual/semantic parity with the native renderer.

### Phase 3 — Action parity

- Add the opaque action registry and JS message bridge.
- Route all `TranscriptAction` cases to native inspectors/navigation/clipboard.
- Implement tool/group expansion state and per-turn copy/assets controls.
- Verify focus, keyboard interaction, and stale-action rejection.

Exit gate: every current interactive fixture works in Web mode.

### Phase 4 — Incremental streaming and selection preservation

- Add the revisioned document differ and operation batching.
- Update only the live turn/active block.
- Add stable logical selection anchors and restore logic.
- Preserve code/table `scrollLeft`, focus, and expansion across patches.
- Handle malformed/gapped revisions with a full reset.

Exit gate: continuous selection survives streaming and tool completion; completed turns do
not re-render.

### Phase 5 — Scroll parity

- Implement initial hidden layout and bottom reveal.
- Port pinned/unpinned/new-turn behavior.
- Add unpinned visible-anchor preservation.
- Handle composer, approval, inspector, and window resizing.
- Add jump-to-latest control and user/programmatic scroll ownership tracking.

Exit gate: the complete `MacNativeChatTimeline` behavior matrix passes without blank
frames, overshoot, bounce, or reader theft.

### Phase 6 — Timeline extensions

- Add `TimelineWebNode` and extension action routing.
- Migrate `DesktopControlEvidenceTimeline`.
- Implement `.auto` eligibility/fallback for legacy native-only extensions.
- Add extension cards to selection, scroll, accessibility, and recovery tests.

Exit gate: the shipped CodeAgent host can run in Web mode without losing extension
content or actions.

### Phase 7 — Accessibility, security, and stress hardening

- VoiceOver and keyboard audit.
- CSP/navigation/resource-scheme penetration tests.
- Long conversation, huge code, wide table, rapid token, parallel tool, and process-crash
  stress tests.
- Add telemetry and recovery diagnostics.
- Compare memory/CPU/first-paint metrics against native baselines.

Exit gate: no P0/P1 accessibility or security issue; agreed performance budgets pass.

### Phase 8 — Default switch and cleanup

- Enable Web by default for eligible macOS configurations.
- Keep a visible/internal rollback path and monitor at least one stable release.
- After stability, remove native-only macOS row-measurement code in a separate change.
- Retain reusable projection, presenter, asset, dispatcher, and native inspector logic.
- Plan iOS adoption separately using the same Web document contract.

Exit gate: Web is the supported macOS conversation workbench; native is fallback until
the deprecation window closes.

## 20. Test matrix

| Category | Required cases |
| --- | --- |
| Markdown | headings, nested lists, quotes, inline code, fenced code, tables, links, malformed streaming fences |
| Width | 320/480/760/1200 pt, inspector toggle, live resize |
| Selection | prose-to-code, code-to-table, user-to-assistant, cross-turn, active-tail patch, tool expansion |
| Copy | ordinary range, whole turn, code button, table cells, collapsed tools, CJK/emoji/UTF-16 offsets |
| Scroll | initial long history, pinned growth, unpinned growth, new turn, resize, approval bar, conversation switch |
| Tools | running/completed/failed/auto, grouped, parallel, args/output kinds, huge output, job wait, subagent |
| Actions | URL/path/artifact/asset/resource/child stream/copy, stale and invalid action IDs |
| Lifecycle | live/history equivalence, reconnect/replay, cancellation, pause/resume/archive |
| Extensions | semantic extension, legacy fallback, extension actions, HTML document inspector |
| Recovery | JS error, revision gap, shell navigation failure, Web process termination |
| Accessibility | VoiceOver order, roles, focus retention, keyboard, zoom, reduced motion, high contrast |
| Performance | 100/500 turns, large diffs, rapid token stream, many syntax spans, multiple parallel tools |

## 21. Files expected to change

New areas (names may be refined during implementation):

```text
Sources/AgentKit/Features/Conversation/Web/
  ConversationWebWorkbenchView.swift
  ConversationWebCoordinator.swift
  ConversationWebDocument.swift
  ConversationWebDocumentBuilder.swift
  ConversationWebDocumentDiffer.swift
  ConversationWebActionDispatcher.swift
  ConversationWebSchemeHandler.swift

Sources/AgentKit/Resources/ConversationWeb/
  index.html
  dist/conversation-workbench.js
  dist/conversation-workbench.css

Web/ConversationWorkbench/
  package.json
  lockfile
  src/
  tests/
```

Existing areas likely to evolve:

- `ConversationTimelineView.swift` — renderer selection.
- `ConversationDetailView.swift` — Web viewport integration, native bars unchanged.
- `TranscriptAction` / `TurnActionDispatcher` — shared action routing instead of
  TextKit-specific ownership.
- `TimelineExtension.swift` — add the companion semantic Web node contract without
  breaking the legacy `AnyView` protocol.
- `Package.swift` — bundled renderer resources.
- `ToolTranscriptPresenter.swift`, `AssetReference.swift` — shared presentation inputs.

Files explicitly retained during rollout:

- `MacNativeChatTimeline.swift`;
- `NativeTranscriptView.swift`;
- `FollowingScrollView.swift`;
- native transcript tests and previews.

## 22. Resolved decisions and remaining questions

Resolved:

- one Web document per active conversation;
- native app shell and native composer/approvals/inspectors;
- Web owns conversation scrolling and selection;
- Swift owns product state and privileged actions;
- macOS first with native fallback;
- no arbitrary extension JavaScript;
- no row-embedded or block-embedded WebViews.
- React 19 + `react-markdown` + `remark-gfm`, with exact versions and a committed npm
  lockfile; Vite emits bundle-local release assets.
- renderer mode is host-injected, `.auto` is the eligible Web default, and explicit
  `.native` plus automatic failure/legacy fallback retain the rollback path.

Remaining rollout decisions:

1. Performance budgets for initial reveal, patch duration, memory, and recovery.
2. Whether renderer mode should also appear in a developer settings UI.
3. Which math and syntax-highlighting libraries enter v1 versus a later slice.
4. How long the native fallback remains after Web becomes default.

## 23. Related documents

- [`../conversation_turn_ui_design.md`](../conversation_turn_ui_design.md) — turn/block
  semantics and live/history invariants.
- [`../codeagentmac-timeline-integration.md`](../codeagentmac-timeline-integration.md) —
  current host-owned timeline extension.
- [`../artifact_system_plan.md`](../artifact_system_plan.md) — artifact semantics.
- [`../p8.7-client-plan.md`](../p8.7-client-plan.md) — child stream rendering.
- [`../protocols/agent-wire-v1.3-tool-assets.md`](../protocols/agent-wire-v1.3-tool-assets.md) —
  structured tool assets.
- [OpenAI: moving to the new ChatGPT desktop app](https://help.openai.com/en/articles/20001276-moving-to-the-new-chatgpt-desktop-app) — current product consolidation context; it
  does not document renderer internals.
