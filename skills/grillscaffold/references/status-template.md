# status.md template

Generate `docs/features/<feature>/status.md` with this exact structure. This is the **only**
file executing sessions may update, and the file the `/loop` orchestrator parses — so the
phase table format is strict. Seed it at scaffold time with every phase as `todo` (or
`blocked` if it depends on an open D-ID).

**State enum — closed set, no other values ever:**

- `todo` — not started
- `in-progress` — a session is on it right now (the orchestrator sets this before spawning)
- `done` — scope confirmed against the plan, all gates green, invariants held
- `qa-pending` — code complete but something is unverified; the Notes cell names exactly what.
  Code complete but unverified is **never** `done`.
- `blocked` — cannot run; Notes names the blocker (a D-ID, a failed gate, a plan
  contradiction, or a dead subagent)

The loop picks "the first `todo` phase whose `Depends on` phases are all `done`". Nothing else
is runnable. `qa-pending` **satisfies** a dependency — it means complete-but-unverified, so
dependents proceed and the gap becomes a QA.md line. Run with `STRICT_DEPS=1` if you want only
`done` to unblock dependents.

---

```markdown
# <Feature Name> — Status

Plan: [plan.md](plan.md) · Prompts: [prompts.md](prompts.md)

## Phase table

| Phase | State | Depends on | Date | Gates | Notes |
|---|---|---|---|---|---|
| P1 | todo | — | — | — | — |
| P2 | todo | P1 | — | — | — |
| P3 | blocked | P2 | — | — | D-1 unanswered |

<Gates cell on completion lists each gate with ✅/❌, e.g. `build ✅ lint ✅ tsc ✅`. A gate
that could not run is written explicitly — `emu skipped — no JDK 21` — never left blank; a
blank is indistinguishable from forgotten.>

## Progress log

<One dated entry per completed phase, appended by the session that ran it. Free prose:
what changed, what was verified, what was deliberately left. Newest entries at the bottom.>

### <date> — <P-ID>

- <what changed>
- <what was verified>
- <what was deliberately left and why>

## Deferred

<Append-only. Anything found but not acted on — out-of-scope discoveries, plan
contradictions, environment problems, and the loop's stop notes. Prefix each item with the
phase that found it. Severity-mark genuinely dangerous findings (🔴) so they surface in the
audit and in the owner's morning read.>

- [<P-ID>] <finding — why it wasn't fixed here — where it belongs>
```
