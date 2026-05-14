# Three Amigos / Example Mapping Workflow

The `three_amigos` task runs a facilitated discovery session on a
single story. The agent plays all three amigos in turn — **Business**
(rules and outcomes), **Developer** (constraints and dependencies),
**QA** (failure modes and edge cases) — while the human Product
Manager holds product intent.

The deliverable is a populated set of Rule + Criterion (scenario) +
Question records on the story, persisted via dedicated MCP tools. No
flat files. No Gherkin written to disk.

## Protocol ordering

**Persona linkage → Rules → Scenarios → Questions.** Do not skip
ahead. Each phase has a different MCP tool and a different card
color in the Example Mapping convention.

### 1. Persona linkage

Call `list_personas` to see what already exists on this project.

- If a suitable persona exists → call `link_persona_to_story` with
  the story_id and persona_id.
- If not → call `add_persona` (alias for `create_persona`) to add a
  lightweight record (identity + metadata only — no research
  artifacts), then `link_persona_to_story`.

Full persona research happens later as a separate
`personas_complete` requirement on the next graph pass — don't try
to do it inline.

### 2. Rules (blue cards)

For each governing constraint or business rule the PM names, call
`add_rule` with the story_id and the rule statement in business
terms. Rules are short — a single declarative sentence. If you need
to qualify it with "but only when X", that's two rules.

### 3. Scenarios (green cards)

For each rule, generate at least one scenario.

- `kind: happy_path` — the normal flow. Every rule has one.
- `kind: failure_path` — add **only when a genuine failure surface
  exists for that rule**. Do not fabricate failure-path examples to
  fill a coverage template. If a rule's failure mode lives at a
  different layer (e.g. infrastructure rather than the business
  rule), leave it out.

Call `add_scenario` with story_id, rule_id, a title, kind, and the
Given/When/Then body in plain Gherkin (single-line per step is
fine; this is example mapping, not full BDD spec writing —
`write_bdd_specs` handles that downstream).

### 4. Questions (red cards)

Park unresolved questions with `add_question`. Don't let them
derail the conversation. The PM resolves them between sessions or
in a follow-up; the session moves on.

A high question count is a smell. If questions outnumber scenarios,
the story isn't ready for this session — the PM needs to do more
intent-shaping first.

## Done signal

The `three_amigos_complete` requirement is satisfied when ALL of:

- ≥1 persona is linked to the story.
- ≥1 Rule exists on the story.
- Every Rule has ≥1 scenario (any kind).
- `rules < 10` — if you're past 10 rules the story is too big;
  split it.
- `scenarios > open questions` (if any questions exist) — if
  questions outnumber scenarios, the story isn't ready.

## This is a manual-validation task

The stop hook does **not** auto-evaluate this requirement. You own
the completion signal.

- Freely stop between turns to let the PM respond. The conversation
  is multi-turn by design.
- When you believe the readiness conditions are met, call
  `evaluate_task` explicitly to run the checker. On pass, the
  task completes and the graph advances.
- If the PM directs you to abandon the session (refuses to provide
  intent, walks away, decides the story needs more shaping), the
  task remains open. The next run picks up where you left off —
  rules and scenarios already on the story persist.

## Anti-patterns to avoid

- **Writing Gherkin to disk during the session.** The MCP tools are
  the persistence layer. Flat files break the live-rendered session
  view the PM watches.
- **Fabricating failure-path scenarios.** Coverage templates are not
  the bar. Only add a `failure_path` when a genuine failure surface
  exists for that rule.
- **Skipping persona linkage.** Without a persona, the story has no
  voice. The rules and scenarios should make sense FROM the linked
  persona's perspective.
- **Doing persona research inline.** Lightweight identity + metadata
  is enough at this stage. Full research is `personas_complete`'s
  job (separate requirement on the next graph pass).
- **Splitting one rule across two add_rule calls.** Each rule is one
  statement. If you need "but only when", that's two rules.
