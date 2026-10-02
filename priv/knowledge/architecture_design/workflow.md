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
  component. Use this in revision mode for incremental additions.
- **`update_component`** — edit an existing component's metadata
  (type, parent, description).
- **`add_dependency`** / **`remove_dependency`** — the edges between
  components.
- **`set_story_component`** (Stories tool) — link a story to a
  component. The simplest revision-mode action when the architecture
  already has the right component but the story isn't wired up.
- **`validate_dependency_graph`** — check for circular dependencies
  after edits. Run after any structural change.
- **`execute_proposal`** — force a full read-validate-execute cycle
  on `proposal.md` regardless of mode. Use only when a patch-mode
  edit warrants a fresh design pass.

**Components and their dependencies are records.** To add an edge
from one context to another, call `add_dependency`. No file describes
a component; editing a spec changes nothing.

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
against the document spec, and executes it — creating the components
and their dependencies as records and linking stories to them. If
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
2. **Add a dependency edge** — `add_dependency` from a story-linked
   context to the orphan.
3. **Classify as infrastructure** — `update_component` to type
   `infrastructure`; the orphan rule skips infrastructure-typed
   components.
4. **Delete** — `delete_component`. Code that still names the module
   is discovered again on the next sync.

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
- **Writing a spec file to "create" a component.** Nothing reads it.
  Use `create_component`.
- **Calling `validate_dependency_graph` once at the end.** Run it
  after every structural change so you catch cycles before they
  compound.
- **Listing dependencies in a spec file.** Nothing reads it. Use
  `add_dependency`.
