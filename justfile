# Hands-Off quality gate — one entry point for humans, CI, and coding agents.
# Source of truth: ../HandsOff-Knowledge/docs/agent-dev-baseline.md §7 (issue #78).
#
#   just check        authoritative gate — mirrors CI; uses the pinned toolchain.
#   just check-ts     TypeScript/React workspace gate (format, lint, types, tests, build).
#   just check-rust   Rust/Tauri gate (rustfmt, clippy, tests) for the desktop crate.
#   just check-full   check + opt-in analyzers (knip, cargo audit/deny, semgrep).
#                     Install those CLIs first with `just setup`.
#   just setup        install the optional analyzer CLIs.
#
# Run `just` (no args) to list recipes. `just check` must pass on a clean checkout.

set shell := ["bash", "-uc"]

tauri_manifest := "apps/desktop/src-tauri/Cargo.toml"

# Default: list recipes.
default:
    @just --list

# Authoritative gate — mirrors CI's verify job; green on a clean checkout today.
# Rust is opt-in (`check-rust`) + advisory CI until pre-existing rustfmt drift is
# fixed (a child task of #78). `check-all` runs TS + Rust together.
check: check-ts

# TS + Rust together (Rust currently has pre-existing rustfmt drift to clean up).
check-all: check-ts check-rust

# TypeScript / React workspace gate (mirrors .github/workflows/ci.yml `verify`).
check-ts:
    corepack pnpm format:check
    corepack pnpm lint
    corepack pnpm typecheck
    corepack pnpm test
    corepack pnpm build

# Rust / Tauri gate: format, lint (deny warnings), and tests for the desktop crate.
check-rust:
    cargo fmt --manifest-path {{tauri_manifest}} --all --check
    cargo clippy --manifest-path {{tauri_manifest}} --all-targets --all-features -- -D warnings
    cargo test --manifest-path {{tauri_manifest}}

# Full gate: adds the opt-in analyzers from baseline §7. Requires `just setup`.
check-full: check
    corepack pnpm dlx knip
    cargo audit --file apps/desktop/src-tauri/Cargo.lock
    cargo deny --config deny.toml --manifest-path {{tauri_manifest}} check
    semgrep ci --config p/typescript --config p/rust

# Dead-code / unused-dependency analysis only (no install needed).
check-deadcode:
    corepack pnpm dlx knip

# Install the optional analyzer CLIs (the §7 toolbox). Node tools run via pnpm dlx.
setup:
    cargo install cargo-nextest cargo-audit cargo-deny --locked
    @echo "knip      → runs via 'corepack pnpm dlx knip' (no install needed)"
    @echo "semgrep   → pipx install semgrep"
    @echo "gitleaks  → brew install gitleaks  (already enforced in CI secret-scan)"
