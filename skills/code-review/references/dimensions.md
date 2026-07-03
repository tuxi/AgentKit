# Review Dimensions — Detailed Checklist (Swift)

Load this when the user asks for a deep/exhaustive review, or when the change
is in a high-risk area (auth, data persistence, concurrency primitives, public
API surface).

## Correctness

- [ ] Every `if` condition is the right polarity.
- [ ] Every `switch` is exhaustive; `@unknown default` not masking new enum
  cases that need handling.
- [ ] Integer arithmetic: overflow, underflow, division by zero.
- [ ] Force-unwrap (`!`): nil is provably impossible here?
- [ ] `try?`: error intentionally discarded, or should it propagate?
- [ ] `try!`: error truly unrecoverable? (Rarely justified outside `static`
  initializers.)
- [ ] `as!`: cast guaranteed by control flow, not assumed?
- [ ] Value vs reference: struct mutation visible to caller? Class sharing
  intended?
- [ ] `didSet`/`willSet`: aware they don't fire during `init`?
- [ ] `lazy var`: thread-safe in the usage context?

## Error Handling

- [ ] `throws` calls use explicit `try`; `try?` vs `try` intent is correct.
- [ ] `catch` blocks bind the error or use typed patterns; not bare `catch`
  without justification.
- [ ] `Result` failure case handled; not just `.success` unwrapped.
- [ ] `defer` for cleanup placed immediately after resource acquisition.
- [ ] `fatalError()` / `preconditionFailure()` only for programmer errors, not
  recoverable runtime errors.

## Concurrency (Swift)

- [ ] Actor reentrancy: invariants re-checked after every `await`.
- [ ] `@MainActor`: UI methods not called from background contexts.
- [ ] `@Sendable`: closures crossing isolation boundaries are safe; no
  accidental capture of mutable non-Sendable state.
- [ ] `Task.detached` justified? Prefer structured `Task` for automatic
  cancellation and priority inheritance.
- [ ] Cancellation: long-running async work has `Task.checkCancellation()` or
  `Task.isCancelled` checks.
- [ ] Mutable class state shared across concurrency domains: protected by
  actor, `@MainActor`, or explicit locking?
- [ ] `nonisolated` members don't access actor-isolated mutable state.
- [ ] `async let`: aware that one child throwing cancels siblings?

## Memory Management (ARC)

- [ ] Retain cycles: `self` captured in escaping closure stored as property →
  `[weak self]`.
- [ ] `[weak self]`: nil guarded or `guard let self` used.
- [ ] `[unowned self]`: only when lifetime is guaranteed.
- [ ] Delegate / observer properties are `weak`.
- [ ] `@Observable` / `ObservableObject`: no view-model-view retain cycles.

## Resource Management

- [ ] File handles, network connections, observation tokens: cleaned up in
  `defer` or `deinit`.
- [ ] Large buffers / caches: bounded; no unbounded growth.

## Testing

- [ ] New code paths have tests.
- [ ] `XCTAssertEqual` over `XCTAssert(a == b)` for better failure messages.
- [ ] Async test methods use `await` directly (XCTest supports `async`).
- [ ] `setUp()`/`tearDown()` reset shared state; tests are isolated.
- [ ] No dependency on process-wide global mutable state between tests.
- [ ] Bug fix has a regression test.

## Design

- [ ] Right abstraction: struct first, class for reference semantics, protocol
  for multiple implementations.
- [ ] Generics / `associatedtype` earn their complexity.
- [ ] Access control: narrowest level used (`private` > `fileprivate` >
  `internal` > `public`).
- [ ] Protocol conformances in `extension` blocks.
- [ ] Public API changes: no breaking renames/removals without migration path.

## Security (when relevant)

- [ ] Input validation: user-supplied strings, file paths, HTTP params.
- [ ] Path traversal: paths derived from user input are sanitized and
  contained.
- [ ] Command injection: no user input concatenated into shell command strings.
- [ ] Sensitive data: not logged, not in error messages, not in user-visible
  strings.
- [ ] Randomness: `SystemRandomNumberGenerator` or `SecRandomCopyBytes` for
  security-sensitive values.

## Documentation

- [ ] Every `public` symbol has a doc comment.
- [ ] Doc comments explain *what* and *why*, not *how*.
- [ ] Deprecated symbols marked with `@available(*, deprecated, message:)`.
