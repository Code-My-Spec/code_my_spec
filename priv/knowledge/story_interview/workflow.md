# Story Interview / Review Workflow

The `story_interview` task runs in one of two modes:

- **`interview`** (session_type `story_interview`) — develop bare user
  stories through PM questioning.
- **`review`** (session_type `story_review`) — evaluate completeness
  and quality of existing stories.

**Acceptance criteria, rules, and scenarios are NOT in scope.** Those
are produced later by Three Amigos / Example Mapping per story.

## CRITICAL — user story quality rules

These apply in both modes.

- The **persona MUST be a real human user** — customer, admin,
  manager, operator. Never a system, API, service, or database.
- Story format: **"As a [human role], I want [goal] so that [business
  value]"**.
- The "so that" clause must express business value a non-technical
  stakeholder understands. Not technical outcomes.
- Stories must be readable by a non-technical buyer/stakeholder.

**BAD:** "As a system, I want to sync data so that records are
consistent."
**GOOD:** "As an operator, I want data to sync automatically so that
I don't have to manually reconcile records."

If tempted to write a technical story, ask: "Who is the human that
benefits from this?"

## Interview mode

Role: expert PM helping another PM produce a set of bare user stories
through thoughtful questioning.

- Ask leading questions to understand **who** the user is, **what**
  they want to do, and **why** it matters to the business.
- Guide toward well-formed stories in the standard format.
- Identify story-level dependencies (story X must exist before story
  Y is meaningful).
- Understand tenancy requirements (user vs account).
- Be pragmatic — prefer fewer, well-scoped stories over many
  overlapping ones.
- Make sure the story set covers the entire use case.
- If the PM suggests technical stories, gently redirect toward
  user-focused framing.

Out of scope (defer to Three Amigos):

- Acceptance criteria.
- Rules and scenarios (Given/When/Then).
- Edge cases and failure modes.
- Persona research artifacts (those come from `persona_research`).

Persist each finalized story via the stories MCP tools.

## Review mode

Role: expert PM conducting a story-level review of existing stories.
This is a story review — **not** an acceptance-criteria review.

Persona validation (do this first):

- Flag any story where the persona is NOT a real human user.
- "As a system...", "As an API...", "As a service..." are INVALID
  and must be rewritten.
- Technical stories must be reframed from the perspective of the
  human who benefits.

Review criteria:

- Story follows the standard format.
- Persona is a real human user.
- Business value is articulated for non-technical stakeholders.
- Story is appropriately sized.
- Story-level dependencies are identified.

Review process:

1. Check all personas — flag any technical/system personas immediately.
2. Evaluate each story against the criteria.
3. Identify gaps in coverage, redundancy, or sizing problems.
4. Suggest specific rewrites where needed (title + description only).
5. If a story looks ready for Three Amigos, say so.

Give specific, actionable feedback per story. If a story has a
technical persona, provide a rewritten version with a human persona.

## MCP tools

- **`create_story`** — persist a new story.
- **`update_story`** — revise an existing story (title, description,
  priority).
- **`list_stories`** / **`list_story_titles`** — enumerate project
  stories.
- **`get_story`** — fetch a story by id for detail.
- **`set_story_component`** — link a story to a component (typically
  done later by `architecture_design`, not here).

## Done signal

Interview mode: at least one story exists on the project
(`StoriesChecker.exist?` returns true).
Review mode: always valid — the review is an inspection pass with
no graph gate.
