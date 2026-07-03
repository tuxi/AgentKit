---
name: code-review
version: "1"
description: Review a diff, PR, or code change — check correctness, error handling, concurrency safety, memory management, style, testing, and design. Use when the user says "review this", "code review", "check this change", "look at this PR", "audit this code", or asks for a structured review of any Swift code. Also triggers on "is this safe?", "anything wrong here?", "review and tell me what to fix."
---

# Code Review (Swift)

You are reviewing code written by another developer (possibly your own prior
self). The goal is to catch problems the author missed — not to nitpick style
that a linter would catch. Every issue you raise must be actionable.

## Workflow

### 1. Determine the scope

Ask the user if it is not clear. Options:

- **Uncommitted changes**: `git_diff` on the workspace.
- **A specific commit or range**: `git log` then `git_diff`.
- **A file or directory**: `read_file` the files.
- **A PR**: user provides the branch or range.

If the user says "just review everything", default to uncommitted changes with
`git_diff`. If there are none, show recent commits and ask which to review.

### 2. Understand the change

Before you review, read enough context to understand what the code does and why.
Do not review a diff line-by-line in isolation — a line that looks wrong may be
correct in the call chain it belongs to.

- Use `project_graph find_references` on changed symbols to see who calls them.
- Use `project_graph find_symbol` to find the definition of unfamiliar types.
- Use `read_file` on callers and callees of the changed functions.
- Use `grep` to find related patterns (same error type used elsewhere, same
  concurrency pattern in the codebase).

### 3. Review along these dimensions

For each dimension, focus on the diff but apply the project's existing patterns
as the baseline. A change that looks unconventional may be fine if it matches
how the rest of the codebase does it.

#### Correctness (always check first)

- Logic errors: off-by-one, inverted conditions, missing cases in switches.
  Swift switches must be exhaustive; new enum cases without corresponding
  switch arms will not compile — but `@unknown default` can hide them.
- Optional safety: force-unwrap (`!`) — is nil provably impossible at this
  point? Implicitly unwrapped optional (`IUO`) — has it been checked before use?
- Type casting: `as!` — is the cast guaranteed? `as?` followed by force-unwrap
  is doubly suspicious.
- `try?` silently discards errors — was this intended, or should the error
  propagate?
- `try!` — is the error truly unrecoverable? Almost never appropriate outside
  of `static` initializers or guaranteed preconditions.
- Value vs reference semantics: struct passed by copy — is the caller expecting
  mutation to be visible? Class passed by reference — unintended sharing?
- Boundary conditions: empty collection, empty string, zero, nil, `Int.max`.
- `didSet` / `willSet`: does `didSet` trigger during `init`? (It does not.)
- `lazy var`: is it thread-safe? `lazy` initialization is not atomic.

#### Error Handling

- Are `throws` functions called with `try`? Any bare calls that would be a
  compile error are already caught — but check for `try?` vs `try` intent.
- `catch` blocks: are errors pattern-matched correctly? `catch let error as
  NSError` vs bare `catch` without binding can lose the error.
- `Result` type: is the failure case handled, not just `.success`?
- Are errors surfaced to the user with context, or swallowed silently?
- Does a `catch` block that calls `fatalError()` or `preconditionFailure()`
  have a legitimate reason, or should it be a logged error?
- `defer` for cleanup: is it placed immediately after the resource acquisition
  (file handle, lock, observer token)?

#### Concurrency Safety (Swift Concurrency)

- **Actor reentrancy**: every `await` is a suspension point where the actor's
  state can change. Are invariants re-checked after `await`?
- **@MainActor**: UI code must run on `@MainActor`. Does the change call UI
  methods from a background context without `await MainActor.run` or
  `@MainActor` annotation?
- **@Sendable**: closures passed across isolation domains must be `@Sendable`.
  Does the closure capture non-Sendable state? `@Sendable` on a closure
  prevents capturing mutable non-Sendable references — a compile error, so
  no runtime surprise, but check for workarounds that defeat it.
- **Task hierarchy**: `Task.detached` breaks priority propagation and
  cancellation — is this intentional? Prefer `Task` (structured) over
  `Task.detached`.
- **Cancellation**: long-running work should call `Task.checkCancellation()`
  or check `Task.isCancelled`. Does this new async code have cancellation
  points?
- **Data races**: structs are generally safe if all properties are Sendable.
  Classes with mutable state shared across concurrency domains must be
  protected (actor, `@MainActor`, or manual locking). Does the change share
  mutable state unsafely?
- **`nonisolated`**: members marked `nonisolated` must not access actor-isolated
  mutable state unless the state is `let` and `Sendable`.
- **`async let`**: these tasks are cancelled when the parent scope exits. If
  one child throws, the other child tasks are implicitly cancelled — is error
  handling aware of this?

#### Memory Management (ARC)

- **Retain cycles**: class captures `self` in an escaping closure stored as a
  property — `[weak self]` needed.
- **`[weak self]`**: guard against `self` being nil after capture, or use `guard
  let self` at the top to early-exit.
- **`[unowned self]`**: only safe when the captured object's lifetime is
  guaranteed to outlive the closure. In practice, prefer `weak`.
- **Delegate pattern**: delegate properties should be `weak` (or use `any
  Protocol`) to avoid retain cycles.
- **Observation**: `@Observable` (iOS 17+) or `@Published` + `ObservableObject`
  — does the change create observation retain cycles (view → view model → view)?

#### Style & Clarity

- Access control: is the narrowest possible level used? `private` over
  `fileprivate` over `internal` over `public`. New API should justify its
  visibility.
- Protocol conformance: grouped in `extension` blocks? (Common Swift convention.)
- Naming: does the name match Swift API Design Guidelines? Methods should read
  as English phrases at the call site.
- Function length and parameter count: >4 parameters without a config struct?
- `guard` vs `if let`: `guard` for early exit (happy path left-aligned); `if
  let` for conditional branching.
- Comments: do they explain *why*, or *what*? Missing doc comments on `public`
  symbols?
- `any` vs `some`: `some` for opaque return types, `any` for existential
  containers. Using `any` where `some` suffices adds unnecessary boxing overhead.

#### Testing

- Does the change touch a path that has no test? Flag it.
- `XCTAssert` family: is the right assertion used? `XCTAssertEqual` over
  `XCTAssert(a == b)` for better failure messages.
- `async` tests: `XCTest` supports `async` test methods — are async functions
  tested with `await` or wrapped in expectations?
- `setUp()` / `tearDown()`: shared state between tests should be reset in
  `setUp`/`tearDown`, not leaked across tests.
- Test isolation: does the test depend on global state that another test
  could mutate?
- If a bug fix, is there a regression test?

#### Design

- Protocol vs class vs struct: is the right abstraction chosen? Start with a
  struct; use a class only when reference semantics or identity is needed; use a
  protocol when multiple implementations are expected.
- `associatedtype` / generics: added complexity should earn its keep. Generic
  constraints (`where` clauses) should be readable.
- Property wrappers: does a new `@propertyWrapper` add value, or is it
  unnecessary indirection?
- Extension: does the extension add functionality that belongs to the type, or
  is it scattered? Protocol conformance should be in an extension; free
  functions may be better than extensions on types you don't own.
- New abstraction: does it earn its keep, or is it premature?
- Does the change duplicate an existing helper or pattern?
- Does the change break the public API (removing or renaming `public` symbols)?

### 4. Produce the report

Use this structure:

```
## Review: [scope — file, commit, or "uncommitted changes"]

### Summary
[1-3 sentences: what the change does, overall assessment]

### Issues

#### 🔴 [Title] — [file:line]
**Problem**: [what's wrong and why it matters]
**Fix**: [concrete suggestion]

#### 🟡 [Title] — [file:line]
**Problem**: [...]
**Fix**: [...]

#### 🔵 [Title] — [file:line]
**Problem**: [...]
**Fix**: [...]

### ✅ Good
- [Something the author did well — be specific]
```

Severity levels:
- 🔴 **Critical**: crash, data loss, security issue, retain cycle, actor
  reentrancy bug — must fix before merge.
- 🟡 **Important**: likely bug, missing error handling, `try?` swallows error,
  potential race — should fix.
- 🔵 **Nit / Suggestion**: style, naming, clarity — optional, author's call.

### 5. Offer to fix

After the report, ask: "Want me to fix any of these?"

## Rules

- **Never review code you have not read.** If the diff is large, read the key
  files before forming opinions.
- **Silence is not approval.** If you cannot determine whether something is
  correct (e.g. unfamiliar domain logic), say so instead of skipping it.
- **Respect the codebase's conventions.** If the project uses a pattern
  consistently, do not flag it as wrong even if you personally dislike it.
  Some projects use `try!` for programmer errors — don't fight the codebase.
- **One issue per finding.** Do not bundle unrelated problems into one item.
- **If there are no issues, say so clearly.** "No issues found" is a valid
  review. Do not invent problems to fill the report.

## Parallel reviews

For large changes (>5 files or >200 lines), use sub-agents to review
independent files or dimensions in parallel. Each sub-agent gets a focused
prompt: "Review file X for correctness and error handling" with the diff
content. Combine their findings into the final report.

## References

- `references/dimensions.md` — detailed checklist per review dimension. Load
  for deep reviews or when the user asks for an exhaustive audit.
