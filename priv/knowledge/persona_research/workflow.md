# Persona Research Workflow

The `persona_research` task produces one persona on the active project:
a DB record (via `create_persona`) plus two markdown artifacts at
`.code_my_spec/personas/<slug>/` (`summary.md` and `sources.md`), with
at least one `link_persona_to_story` call before stopping.

The framework knowledge corpus (`priv/knowledge/persona_research/`)
has the full content for each phase — this doc is the workflow
sequencer pointing at the right knowledge file for each step.

## Prereqs

Personas are **project-scoped**. `create_persona` and
`link_persona_to_story` need the scope to carry an `active_project_id`.
If `create_persona` returns `missing_active_project`, the working
directory isn't linked — run `init_project` to bind it, then retry.

## Reuse before research

Check existing personas first:

- **`list_personas`** — every persona on the active project. Use early
  in the intake to see if a prior session already researched this role.
- **`get_persona`** by `slug` or `id` — fetch the full record. Pair with
  reading `.code_my_spec/personas/<slug>/summary.md` for the research
  text.

Reusing an existing persona via `link_persona_to_story` is often the
right answer. Don't research a duplicate if a close match exists.
Personas from sibling projects are not visible here.

## Required reading per phase

| Phase | Knowledge file |
|---|---|
| Workflow order, guardrails, evidence footer | `priv/knowledge/persona_research/README.md` |
| Persona types (proto / qualitative / statistical), Cooper roles, Goodwin goals | `priv/knowledge/persona_research/overview.md` |
| 15-question intake + artifact checklist | `priv/knowledge/persona_research/pm_intake.md` |
| Planning fresh user interviews | `priv/knowledge/persona_research/primary_research.md` |
| Online mining (Reddit, G2, HN, LinkedIn) | `priv/knowledge/persona_research/secondary_research.md` |
| Jobs-to-Be-Done framework | `priv/knowledge/persona_research/jtbd.md` |
| Synthesis from raw data to persona | `priv/knowledge/persona_research/synthesis.md` |
| Persona fields + one-page layout | `priv/knowledge/persona_research/templates.md` |
| Anti-patterns + bias countermeasures | `priv/knowledge/persona_research/pitfalls.md` |

## Five-step session

### 1. Intake conversation

Open with questions from `pm_intake.md`. The PM brings whatever context
they have — notes, hypotheses, or nothing. Ask, they answer. Don't
start writing until you have enough signal.

### 2. Challenge thin input

If the PM's input is a one-liner, push back with targeted follow-up
questions covering Role, Goals, Pain Points, Context, Decision Drivers.
If the PM refuses to provide more context, end the session rather than
produce a low-evidence persona. Thin in, nothing out.

### 3. Research

Use web search and the framework persona_research knowledge.
**Triangulate** — no claim enters `summary.md` unless ≥3 independent
sources support it. **Verbatim quotes** beat paraphrase. Cite every
source. If sources disagree, surface the conflict to the PM. If
research produces nothing, ask the PM for source leads — don't invent
content.

### 4. Write the three artifacts

All three must exist before stopping:

- **DB record.** `create_persona` with `slug` (lowercase alphanumeric,
  hyphens/underscores ok), `name`, optional `headline`. Pick a
  memorable name.
- **`.code_my_spec/personas/<slug>/summary.md`.** H1 matches persona
  name. Required H2 sections: `## Role`, `## Goals`, `## Pain Points`,
  `## Context`, `## Decision Drivers`, `## Evidence`. Optional H2:
  `## Jobs to Be Done`, `## Quotes`, `## Motivations`, `## Behaviors`,
  `## Anti-Patterns`. Any other section name fails validation.
- **`.code_my_spec/personas/<slug>/sources.md`.** Link list with URL,
  title, and access date per entry — one per line.

### 5. Link to a story

`link_persona_to_story` with the persona's id and at least one story
id. The requirement can't satisfy without ≥1 link.

## Evidence bar

- Triangulate (≥3 independent sources per claim).
- Verbatim quotes with attribution.
- Every claim traces to an entry in `## Evidence`. If it doesn't, cut
  it.
- Decision-useful or cut. If a field wouldn't change a product
  decision, remove it.

## Done signal

`personas_complete` requires:

- ≥1 persona linked to this project via `persona_stories`.
- Every linked persona has a DB row, valid `summary.md` (all required
  sections), and non-empty `sources.md`.

## Manual validation

The stop hook does **not** auto-evaluate this requirement —
intake conversations are multi-turn. You own the completion signal:

- Stop freely between turns to let the PM respond. Each stop is
  cheap; the task stays active across stops.
- When you believe all conditions are met, call `evaluate_task`
  explicitly to run `PersonasChecker.complete?`. Pass/fail feedback
  comes back.
- If the PM abandons (refuses evidence, walks away), call
  `evaluate_task` — the checker reports unsatisfied and the
  requirement stays open for the next run.

Never fabricate artifacts to pass the checker. Thin in, nothing out.
