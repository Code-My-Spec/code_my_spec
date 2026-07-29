# Agent Persona Research

Sibling guide to `workflow.md` for personas whose actor is an
**LLM agent class**, not a human. The artifact contract is
identical to the human path — `create_persona` for the DB record and
`summary.md` + `sources.md` on disk — but the research methodology is
different.

## When this applies

Use this guide when the user's request, the linked story's
"As a..." clause, or the persona's headline describes a **class
of LLM agent** running against the CodeMySpec harness. Examples
already in the system:

- `Per-Story QA Agent` — invoked by the per-story qa_complete
  task; calls submit_qa_result / list_qa_attempts /
  invalidate_qa_attempt
- `Code Writer Agent` — invoked from start_implementation;
  writes lib/ files against a spec
- `BDD Spec Writer Agent` — invoked from write-bdd-specs; writes
  test/spex/<story>/ files against criteria

The pattern: the persona is consuming the harness as an MCP
client + filesystem actor, not as a human in a browser.

## Why the human workflow doesn't apply

Standard persona research has five steps (intake → challenge
thin input → research → write artifacts → link). For agent
personas:

- **Intake**: no one to interview. The PM and you (the researcher
  agent) both already know what the agent does because it's
  defined in code.
- **Primary research** (interviews, observations of humans): the
  equivalent is reading the agent definition file
  (`CodeMySpec/agents/<name>.md`), the MCP tools the agent has
  access to, and observed behavior in `~/.codemyspec/server.log`
  / `~/.codemyspec/cli.log`.
- **Secondary research** (industry reports, articles about a
  human role): the equivalent is upstream docs — Anthropic agent
  tool-use docs, the MCP spec, framework references for the
  tools the agent calls.
- **Self-reflection** is a first-class source — the researcher
  agent IS a member of the same class as the persona. First-person
  observations triangulated against the code references count
  toward the ≥3-sources-per-claim bar.

The synthesis step is the same: distill into the required H2
sections (Role, Goals, Pain Points, Context, Decision Drivers,
Evidence).

## Source types for triangulation

For each load-bearing claim in the summary, cite at least three
of the following:

1. **Agent definition file** at
   `CodeMySpec/agents/<agent_name>.md` — declares tools the agent
   has access to, model, system prompt fragments, color, etc.
2. **MCP tool registry** — the tools the agent can actually call
   (`LocalServer.__components__(:tool)` for the local set). The
   tool's `@moduledoc` is the agent-facing contract.
3. **Upstream docs**:
   - https://docs.anthropic.com/en/docs/agents-and-tools/ — agent
     tool-use patterns
   - https://modelcontextprotocol.io/ — MCP spec, what agents
     expect from a tool surface
4. **Observed behavior**:
   - QA briefs and results under `.code_my_spec/qa/<story_id>/`
   - Task transcripts in `~/.codemyspec/server.log` (search
     `request_id=` + `mfa=`)
   - Failing patterns in framework-scoped issues (`list_issues
     scope: framework`) — they document where the agent class
     hits friction
5. **Adjacent agent definitions** — comparing the persona's
   agent against sibling agents (e.g. comparing
   `Per-Story QA Agent` against `Code Writer Agent`) sharpens
   what's distinctive about its role.
6. **Self-reflection** — you, the researcher, are an instance of
   an LLM agent and frequently a member of the same class. First-
   person observations ("when I run this task I want X") count
   when triangulated against the code/log evidence.

## Required deliverables (identical to the human path)

### `.code_my_spec/personas/<slug>/summary.md`

H2 sections (any other H2 fails validation):

- `Role` — what kind of agent, invoked when, by what
- `Goals` — the agent's success criteria (typed events,
  satisfied requirements, etc.)
- `Pain Points` — friction the agent class hits today; cite
  framework-scoped issues
- `Context` — the surface the agent operates against (MCP tools
  available, files it reads/writes, hooks that fire around it)
- `Decision Drivers` — what trade-offs the agent's design makes
  (e.g. typed events beat file parsing; validation at boundary
  beats post-hoc cleanup)
- `Evidence` — numbered list of sources used, with file paths,
  URLs, and access dates

Optional: `Jobs to Be Done`, `Quotes`, `Motivations`, `Behaviors`,
`Anti-Patterns`.

### `.code_my_spec/personas/<slug>/sources.md`

Link list per source. For codebase references, include the
commit SHA at access time so the citation is reproducible:

```markdown
- `CodeMySpec/agents/qa.md` @ a7a0bf53 — declared tool list and
  system prompt for the QA agent. Accessed 2026-05-17.
- https://modelcontextprotocol.io/specification/2025-03-26 — MCP
  tools/call contract. Accessed 2026-05-17.
- `.code_my_spec/qa/607/result.md` @ a7a0bf53 — observed agent
  output for a per-story QA run. Accessed 2026-05-17.
```

## Anti-patterns

- **Don't manufacture human attributes.** An agent has no
  "demographic," no "personal motivations" — only its programmed
  goals and the friction it encounters. If you find yourself
  writing about an LLM's family or hobbies, stop.
- **Don't conflate the agent class with a specific model.** The
  persona describes "the kind of agent that runs this task,"
  not "Claude Sonnet 4.5" specifically. Model choice is config,
  not identity.
- **Don't skip the evidence triangulation.** "I think the agent
  wants X" without ≥3 sources is opinion. Cite the code, the
  spec, the observed behavior.
- **Don't fork the workflow further.** If you find yourself
  wanting a third research methodology (e.g. for hybrid
  human/agent personas), surface it as a framework issue rather
  than adding a third file.
