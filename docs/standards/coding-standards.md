# Coding Standards

This document is the source of truth for code reviews and general coding
guidelines in foreman. The architecture invariants the daemon depends on
(source of truth, claim protocol, untrusted input) live in
[CLAUDE.md](../../CLAUDE.md) and are reviewed alongside these rules.

## 1. SOLID Principles in Rust

Rust is not an object-oriented language, but SOLID still guides design:

*   **Single Responsibility Principle (SRP)**: A struct or module has one,
    and only one, reason to change. The daemon is already split along these
    lines (`claim`, `claimable`, `markers`, `sweep`, `review`, …); keep new
    behavior in the module that owns that concern instead of growing
    `worker.rs` or `pipeline.rs`.
*   **Open/Closed Principle (OCP)**: Open for extension, closed for
    modification — in Rust, through traits. `Forge`, `CommandRunner`,
    `Notifier`, `Clock`, and `ProcessProbe` exist so a new forge, vendor,
    or transport is a new implementation, not an edit to existing ones.
*   **Liskov Substitution Principle (LSP)**: Code taking a trait object or a
    trait-bounded generic must work with every implementation. The
    in-memory fakes (`FakeForge`, `TestClock`, the scripted runner) are
    first-class implementations — the integration tests depend on it.
*   **Interface Segregation Principle (ISP)**: Prefer many small, specific
    traits over one large one. Do not widen `Forge` with a method only one
    caller needs when a narrower trait would do.
*   **Dependency Inversion Principle (DIP)**: Depend on abstractions. The
    worker and pipeline take `Arc<dyn Trait>` / generics, never a concrete
    `GithubForge` or `TokioRunner`; only `main.rs` wires concretions.

## 2. Rust Idioms & Safety

*   **Error Handling**: Library crates and daemon modules define typed
    errors with `thiserror` (`ForgeError` is the model); `anyhow::Result`
    with `.context(...)` is used only at the binary edge (`main.rs`,
    `src/bin/*`). Errors that cross a trait boundary must be a typed enum
    so callers can match on them (rate limit vs. not found vs. transport).
*   **Avoid Panics**: No `unwrap()`, `expect()`, `panic!`, or
    `unreachable!` in production paths. Handle errors with `?` or explicit
    matching; a daemon that panics on one bad ticket stops dispatching for
    the whole fleet. The one accepted exception is `Mutex::lock().unwrap()`
    on process-local state, where a poisoned lock is itself an
    unrecoverable invariant break. Panics are fine in tests and in
    `#[cfg(test)]` / test-support code.
*   **Never exit on forge failure**: A forge error is data, not a crash.
    Log it, back off, and try again on a later tick (see `next_poll_delay`
    in `worker.rs`). A code path that propagates a forge error out of the
    tick loop is a Blocker.
*   **Leverage the Type System**: Make invalid states unrepresentable. Use
    enums for state machines (the pipeline phase, `PrState`, marker
    kinds) and newtypes instead of primitive obsession (`TicketRef`, not a
    bare `(String, u64)`; a `Duration`, not a `u64` of seconds).
*   **Untrusted input stays structured**: Issue bodies, comments, and
    reviewer output are parsed field-by-field into typed values; free
    prose is never interpreted, and values only ever land in fixed CLI
    argument slots. Any new path that reads prose from the forge into a
    decision is a Blocker.
*   **Secrets never touch argv, files, or logs**: Tokens come from the
    environment (`FOREMAN_GITHUB_TOKEN`, `MATTERMOST_TOKEN`); `Debug`
    impls on clients must redact them (there is a test for `GithubForge`).
*   **Immutability by Default**: Prefer immutable bindings and references;
    use `mut` only when necessary.
*   **Ownership and Borrowing**: Avoid unnecessary `.clone()`; prefer
    `&T` / `&mut T`. Cloning an `Arc` to hand to a spawned task is fine;
    cloning a `Vec<Comment>` to avoid a lifetime is not.
*   **Config drain semantics**: Take a `ConfigHandle::snapshot()` when a
    unit of work starts and use that snapshot until it ends. Reading the
    live config mid-task is a bug, not a feature.
*   **Formatting and lints**: `cargo fmt --all --check` and
    `cargo clippy --workspace --all-targets -- -D warnings` are CI gates;
    a change that introduces a warning fails review. Edition is 2024.

## 3. Tests

*   Behavior in the claim / pipeline / review / sweep path gets an
    offline test against `FakeForge` and the scripted runner, in the
    matching `tests/*.rs` file (`loop.rs`, `race.rs`, `fleet.rs`) or the
    module's `#[cfg(test)]` block — never a live-forge run as the only
    evidence.
*   Tests are deterministic: drive time with `TestClock`, not sleeps; drive
    the worker tick by tick.
*   Do not weaken the exit-condition tests (`race.rs`: no double-runs, no
    lost tasks; `fleet.rs`: degraded mode) to make a change pass.

## 4. Architecture and Implementation References

*   **[CLAUDE.md](../../CLAUDE.md)**: Build commands, crate layout, and the
    invariants that span modules.
*   **[README.md](../../README.md)**: Locked design decisions and the phased
    roadmap.
*   **[docs/fleet.md](../fleet.md)**: Multi-worker routing, the two caps,
    and coordinator-death degraded mode.
