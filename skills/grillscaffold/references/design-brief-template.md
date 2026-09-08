# design-brief.md template

Generate `docs/features/<feature>/design-brief.md` when the user opts into the Stage 1.5
design spike. It is **one single paste-ready prompt** for Claude Design (or any prototyping
tool) — no meta-commentary around it, because the user pastes the whole file. It must speak
the code's vocabulary: every entity and field name comes verbatim from the grilled data
model, so the prototype's labels map 1:1 onto what the phases will build.

Fill every placeholder; delete sections that don't apply.

---

```markdown
# Design spike — <feature>

Prototype the UI for the feature below. This is a THROWAWAY prototype: its job is to answer
the open design questions listed at the end, not to produce production code.

## Context
<2–4 sentences: the product, who uses this feature, and what it must accomplish. Name the
platform (web dashboard / React Native app / both) and the design system in use, if any.>

## Screens & flows
<One subsection per screen. For each: purpose, entry points, primary actions, navigation
targets. Describe flows as ordered steps: "1. User taps X → 2. sheet opens with Y…">

## Data vocabulary — use these EXACT names
<The entities and fields from the grilled data model, verbatim. e.g.:
- `settlement` — `garage_id`, `period_start`, `period_end`, `total_fils`, `status`
  (`draft | approved | paid`)
Prototype labels, table columns, and state names must use these names so the prototype
maps 1:1 onto the code.>

## States to prototype
<Every screen needs: empty, loading, populated, error. Plus feature-specific states
(e.g. "settlement in `draft` vs `paid` — paid rows are read-only").>

## Constraints
<Hard rules: brand colors, RTL/Arabic support, mobile-first breakpoints, existing component
library, accessibility floors — whatever the grill locked.>

## Do NOT prototype
<Explicit exclusions so the spike stays scoped: auth flows, settings, admin surfaces,
anything already built, anything out of feature scope.>

## Open questions this prototype must answer
<The parked UX D-IDs, verbatim, each phrased so the prototype can settle it. e.g.:
- D-3: table-with-drawer vs. card grid for the settlements list — build both, pick one.
- D-5: does per-line-item editing need inline edit or a modal?>

## Deliverables
When done, report back with:
1. A one-line answer per D-ID above, with a one-sentence reason.
2. Screenshots (or an export) of every screen in its main states, to be saved into
   `docs/features/<feature>/design/`.
3. Anything the prototype revealed that the plan missed: new states, missing fields,
   flows that didn't survive contact with a real screen.
```
