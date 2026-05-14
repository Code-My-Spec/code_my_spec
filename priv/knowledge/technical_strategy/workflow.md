# Technical Strategy Workflow

The `technical_strategy` task identifies technology decisions the
project needs to make, then produces ADRs documenting each one.
Pre-made ADRs for the standard CodeMySpec stack are auto-written
before the session starts.

## Phase 1 — Pre-made decisions (already done before you see this)

When the task fires, it writes ADRs for every standard-stack topic
that doesn't already have one. The auto-written set covers: Elixir,
Phoenix, LiveView, Tailwind, DaisyUI, phx.gen.auth, ExVCR, Wallaby,
SexySpex BDD, Dotenvy, Resend, Hetzner deployment, and PowAssent +
CodeMySpec generators.

You'll see these in the "Existing Decisions" section of the prompt.
Don't re-decide them.

## Phase 2 — Identify project-specific topics

Read the prompt's dynamic context — architecture, current
dependencies, user stories — and identify technology decisions that
the pre-made ADRs don't cover. Common categories:

- **Testing.** Integration framework, E2E approach, test-data strategy.
- **Deployment.** Hosting target, CI/CD, release process. (Hetzner is
  a pre-made decision; revise the ADR if the project's deployment
  needs differ.)
- **Infrastructure.** Caching, background jobs, file storage, search.
- **Integrations.** Third-party APIs, payment processing, additional
  auth providers, telemetry.

Skip topics already covered by pre-made or existing decisions. If an
existing pre-made decision is wrong for this project, update the
ADR's Status to "Superseded" and write a replacement.

## Phase 3 — Research each topic (cursory)

For each new topic:

1. Search hex.pm for libraries.
2. Skim the leading library's README and quick-start.
3. Evaluate against the project's stories, scale, and budget.
4. Pick one option (or explicitly note "no library — write
   project-local code").

Don't over-research. The ADR captures the decision and rationale;
deep investigation belongs in a separate research task.

## Phase 4 — Write each ADR

Write the decision record to
`.code_my_spec/architecture/decisions/{topic}.md` with these
sections:

- **Title** — concise statement of the decision.
- **Status** — Accepted, Proposed, or Superseded.
- **Context** — why this decision is needed.
- **Options Considered** — alternatives with pros / cons.
- **Decision** — what was chosen and why.
- **Consequences** — tradeoffs and follow-on work.

Pre-made ADRs use a slimmer format (Status, Context, Decision,
Consequences) — match that when writing new ones too. The Options
section is optional but useful for decisions where the choice was
non-obvious.

## Phase 5 — Update the index

Write or update `.code_my_spec/architecture/decisions.md` to list
every ADR file (pre-made + new) with its status. The evaluator's
done signal is this index file's existence.

## Phase 6 — Stop

Stop the session. The evaluator checks the index exists. The
quality of the decisions themselves is reviewed downstream when
`code_generation` and `architecture_designed` consume them.

## Out of scope for this task

- **Deep research.** Use `research_topic` for any decision needing
  more than cursory investigation.
- **Bootstrap / library installation.** That's downstream — the
  decisions guide it but don't perform it.
- **Implementation choices below the library level** (algorithm
  selection, data structure design, etc.). Those live in component
  specs, not ADRs.
