# CLAUDE.md

See [`AGENTS.md`](./AGENTS.md) — it holds the repo conventions, workspace shape, local checks, and the CI/CD + GitHub workflow rules for all agents (Claude Code, Cursor, Codex). This file is a pointer to avoid drift; keep guidance in `AGENTS.md`.

Frequent gotcha: to test mic/speech/STT/camera/CUA you must run the **bundled `.app`**, not `tauri dev`. Source `apps/desktop/.env.local` in the same shell *before* `tauri build` so the worker secrets bake in, then `open` the bundle — full commands in [`AGENTS.md`](./AGENTS.md) § "Building & running the bundled app".
