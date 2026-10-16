# Conversation scale and retention policy

This change is integrated into the AgentKit source directory referenced by
`/Users/xiaoyuan/Documents/work/git/chater/Talkify.xcodeproj`. The Examples app is
not part of this integration.

## Lists

- Request the latest 100 active conversations with `limit=100`. The existing
  unparameterized full-list API remains available to old clients and adapters.
- Use opaque `before` cursors from `X-Codeagent-Next-Cursor`; determine completion
  from `X-Codeagent-Has-More`. Without these headers, retain legacy full-list
  behavior and do not show a misleading continuation affordance.
- Refresh only the head page. Preserve already loaded older rows and the older
  continuation cursor, deduplicate by conversation ID, and retain the cursor on
  failure so the user can retry. Local archive/delete responses remain
  authoritative. A missing row in a partial page is never treated as deletion.
- The sidebar starts with recent conversations and exposes explicit load-more
  controls for active and archived lists. Search and workspace groups cover loaded
  records; the sidebar states that scope while more records remain.
- Archived records are fetched when opened, when an already loaded archive is
  refreshed, or when a legacy full list needs to classify a missing selected row.

## Activity and restoration

- Use the existing `since_sequence` activity cursor when both attention snapshot
  and delta capabilities are advertised. If a server resets the cursor, fetch a
  new baseline. Inactive polling backs off; paused sessions remain metadata-only.
- Activity publication does not await background history or socket attachment.
  Restore at most three sessions concurrently, prioritize the selected session,
  and cancel the restoration queue with lifecycle monitoring.
- Active background sessions request `tail=20` to preserve enough tool/approval
  context without replaying all history. Foreground openings request `tail=200`.
  Both retain the history endpoint's hard limit and fragment continuation rules;
  neither requests `/messages`. Detail refresh runs independently.
- The small background tail is intentional: controls and context remain usable
  after app restoration. This is not a zero-history control-only connection.

## Resource ownership

- macOS keeps only the three most recently used timeline views. This bounds
  WKWebView DOMs and AppKit view trees. Evicting a presentation view never calls
  `disconnect` on its controller.
- The supervisor independently keeps at most eight idle controllers, or the
  smaller advertised connected-session limit. The selected controller, active
  turns, pending approvals and in-flight client tools are protected. Active work
  can temporarily exceed the soft limit. Terminal attention remains in the
  lightweight activity/read store after its controller is evicted.
- Returning to an evicted view may recreate its viewport, but durable history,
  composer state, read cursors and background execution remain intact.

These defaults require no host initializer changes. New protocol entry points
have default legacy implementations, so Talkify's existing RuntimeClient and
AgentTransport adapters remain source-compatible.
