# Hands-Off

Code repository for the **Hands-Off** capstone (Gauntlet AI) — a real-time, multimodal
collaborative canvas: design systems together by speaking, pointing, and looking.

> **Project plan:** see [`PLANNING.md`](./PLANNING.md) — the team's D01 planning document
> (problem, technical approach, scope, and ownership).

## Repos

This project is split into two repos under the `Capstone/` folder:

| Repo | Purpose | Workflow |
| --- | --- | --- |
| **`HandsOff`** (this repo) | Application code | Strict git hygiene: feature branches + PRs + review |
| **`HandsOff-Knowledge`** | Research, decisions, findings (Markdown / Obsidian vault) | Low-ceremony, auto-synced via Obsidian Git |

Keep code here and knowledge there. See the knowledge repo's `README.md` and `AGENTS.md`
for how the team brain works.

## Git workflow

- `main` is protected; no direct pushes.
- Branch per feature: `feat/<short-name>`, `fix/<short-name>`.
- Open a PR, get one review, then merge.

## Getting started

> Tech stack is still under research (see `HandsOff-Knowledge/research/tech-stack/`).
> This README will be filled in once the stack is chosen.
