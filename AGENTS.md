# Agent Guide — Hands-Off (code)

Instructions for coding agents (Cursor, Claude Code, Codex) working in this repo.

## Project context lives next door

The team's research, decisions, and findings are in the **`HandsOff-Knowledge`** repo,
checked out as a sibling folder: `../HandsOff-Knowledge`.

Before making non-trivial decisions, consult:
- `../HandsOff-Knowledge/decisions/` — accepted architecture decisions (ADRs)
- `../HandsOff-Knowledge/research/tech-stack/` — evaluated frameworks/SDKs
- `../HandsOff-Knowledge/capstone-proposal.md` — the product vision

If you make a decision worth recording, write an ADR in the knowledge repo's
`decisions/` folder (copy its `_templates/decision.md`).

## Code conventions

- `main` is protected. Work on `feat/*` or `fix/*` branches and open PRs.
- Keep this repo code-only; research and notes belong in `HandsOff-Knowledge`.
