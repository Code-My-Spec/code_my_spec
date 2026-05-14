# Architecture Design Workflow

The `architecture_design` task maps user stories to application
components (surfaces, contexts, children). It runs in one of two
modes — **initial** (no proposal exists yet) or **revision** (a
proposal is already on disk and the agent patches incrementally).

The rendered prompt tells you which mode you're in. The procedure is
different for each.

## Architecture MCP tools — your primary surface

These tools are how you mutate the architecture. Prefer them over
file edits where they apply.

- **`analyze_stories`** — story grouping and pattern detection.
  First step of initial mode. Returns clusters of related stories so
  you can identify shared contexts.
- **`create_component`** — add a new context, child, or surface
  component to the project DB. Spec file gets scaffolded
  automatically. Use this in revision mode for incremental additions.
- **`update_component`** — edit an existing component's metadata
  (type, parent, description). Spec file gets re-projected.
- **`set_story_component`** (Stories tool) — link a story to a
  component. The simplest revision-mode action when the architecture
  already has the right component but the story isn't wired up.
- **`validate_dependency_graph`** — check for circular dependencies
  after edits. Run after any structural change.
- **`execute_proposal`** — force a full read-validate-execute cycle
  on `proposal.md` regardless of mode. Use only when a patch-mode
  edit warrants a fresh design pass.

**Dependency edges are spec-derived, not a tool call.** To add an
edge from one context to another, edit the source context's spec
file under `.code_my_spec/spec/` and add the target module as a
bullet under `## Dependencies`. ComponentSync re-derives the graph
on save.

## Initial mode — no proposal exists yet

The agent designs the architecture end-to-end, writes
`.code_my_spec/architecture/proposal.md`, and lets the evaluator
auto-execute it.

### Step 1 — analyze stories

Call `analyze_stories` to surface groupings. The tool returns
clusters of related stories with suggested context names.

### Step 2 — design the architecture

For each story, decide:

- **Surface component** — what screen / endpoint handles the user
  interaction? LiveView or Controller.
- **Context** — what domain logic implements the feature? Phoenix
  context module.
- **Children** — schemas, modules, or sub-contexts the context
  composes from.

Consider relationships to existing components when revising.

### Step 3 — write the proposal

Write the proposal to `.code_my_spec/architecture/proposal.md`
matching the `architecture_proposal` document spec (which the prompt
embeds via DocumentSpecProjector).

**Naming conventions:**

- Contexts: `<App>.<ContextName>` (e.g., `MyApp.Accounts`).
- Children: `<App>.<Context>.<Child>` (e.g., `MyApp.Accounts.User`).
- Surface: `<App>Web.<Name>Live` or `<App>Web.<Name>Controller`.

### Step 4 — stop

Stop the session. The evaluator reads the proposal, validates it
against the document spec, and executes it — creating spec files
under `.code_my_spec/spec/` and linking stories to components. If
validation fails, you get feedback for the next run.

## Revision mode — proposal already exists

The architecture has been designed once. Apply targeted edits to
satisfy unsatisfied stories and resolve architectural issues
listed in the prompt. **Do not rewrite the proposal end-to-end**
unless the changes are too sweeping for incremental tools.

### Prefer incremental tools

For each unsatisfied story:

- If a component already exists that fits → `set_story_component` to
  link the story to it.
- If no existing component fits → `create_component` for the new
  context / child / surface.
- After structural changes → `validate_dependency_graph` to check
  for cycles.

### Resolving orphan contexts

Orphans are contexts that aren't linked to a story, not transitively
depended on by a story-linked context, and not classified as
infrastructure. For each:

1. **Link a story directly** — `set_story_component` if a story
   should drive this context.
2. **Add a dependency edge** — edit a story-linked context's spec
   under `.code_my_spec/spec/`, add the orphan as a bullet under
   `## Dependencies`. ComponentSync re-derives the graph.
3. **Classify as infrastructure** — add the context's file path to
   `infrastructure_paths` so the framework treats it as
   non-feature-driven.
4. **Delete** — remove the spec / implementation / test files.
   ComponentSync removes the component on the next sync.

### Fallback — full rewrite

If the design needs a fresh pass, rewrite `proposal.md` to the
`architecture_proposal` format and call `execute_proposal`
explicitly. **The evaluator does NOT auto-execute in revision
mode** — it only verifies every story is linked.

### Stop

Stop when edits are complete. The evaluator checks that every
story has a linked component. Unlinked stories produce feedback
listing them by id.

## Done signal — both modes

`ArchitectureChecker.complete?/2` returns success. The check
requires:

- Every project story has a non-nil `component_id`.
- No orphan contexts remain (or the remaining ones are classified
  as infrastructure).

In initial mode the evaluator additionally validates and executes
the proposal as a single transaction; in revision mode it skips
the execute step (the agent already mutated via tools).

## Anti-patterns

- **Rewriting the proposal in revision mode without calling
  `execute_proposal`.** The evaluator won't apply it; you'll just
  have stale text on disk.
- **Editing the spec files directly to "create" a component.** Use
  `create_component`. The MCP tool keeps the DB and the spec file
  in sync; manual file creation only updates the spec.
- **Calling `validate_dependency_graph` once at the end.** Run it
  after every structural change so you catch cycles before they
  compound.
- **Wiring dependencies through `create_component`.** Dependencies
  live in the source spec's `## Dependencies` section, not on the
  component record. Edit the spec file.
