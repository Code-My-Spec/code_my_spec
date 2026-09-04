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
- If not → call `create_persona` to add a lightweight record
  (identity + metadata only — no research artifacts), then
  `link_persona_to_story`.

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

Park unresolved questions with `add_question` so they don't derail
the conversation. Parking is not the same as leaving them: **the
session cannot be sealed while any question is open.** Each one is
either answered with `resolve_question` or closed as somebody
else's problem.

A red card is a thing nobody in the room knew the answer to.
Building on top of one is the failure Example Mapping exists to
prevent, so "more green than red" is not the bar — that reads
whether a story is ready to *estimate*, and says nothing about
whether the conversation finished.

A high question count is still a smell. Several open at once usually
means the PM needs to do more intent-shaping before this session is
worth continuing.

## Done signal — the session is sealed

`three_amigos_complete` reads one thing: whether the story is
**sealed**. Sealing happens when ALL of:

- ≥1 persona is linked to the story.
- ≥1 Rule exists on the story.
- Every Rule has ≥1 scenario (any kind).
- `rules < 15` — the hard ceiling. Past 10 you get a non-blocking
  advisory to consider splitting the story.
- **No question is left open.** Answer each with `resolve_question`,
  or close the ones that turned out to belong somewhere else.

Sealing is one-way, and the gate is the only thing that does it —
so the conditions above cannot be bypassed. Once sealed, a question
raised later does not un-seal the story. That is the next
conversation, not evidence this one never happened.

## Stopping mid-session

The conversation is multi-turn by design and you should freely stop
between turns to let the PM respond.

- Call `evaluate_task` when you believe the conditions are met. On
  pass the story is sealed and the graph advances; on fail you get
  feedback naming what is missing, and you continue.
- If the PM abandons the session (refuses to provide intent, walks
  away, decides the story needs more shaping), the task stays open
  and the next run picks up where you left off — rules, scenarios
  and questions already on the story persist.
- An unsealed story is simply not complete. There is no way to
  report it as done, and nothing completes it on your behalf.

## Anti-patterns to avoid

- **Writing Gherkin to disk during the session.** The MCP tools are
  the persistence layer. Flat files break the live-rendered session
  view the PM watches.
- **Fabricating failure-path scenarios.** Coverage templates are not
  the bar. Only add a `failure_path` when a genuine failure surface
  exists for that rule.
- **Leaving a red card open and moving on.** Parking a question
  during the conversation is right; leaving it open at the end is
  not. It blocks the seal, and that is deliberate — an unanswered
  question that nobody ever returns to is how a story gets built on
  a guess.
- **Skipping persona linkage.** Without a persona, the story has no
  voice. The rules and scenarios should make sense FROM the linked
  persona's perspective.
- **Doing persona research inline.** Lightweight identity + metadata
  is enough at this stage. Full research is `personas_complete`'s
  job (separate requirement on the next graph pass).
- **Splitting one rule across two add_rule calls.** Each rule is one
  statement. If you need "but only when", that's two rules.
