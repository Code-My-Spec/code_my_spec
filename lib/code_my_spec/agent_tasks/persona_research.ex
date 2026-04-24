defmodule CodeMySpec.AgentTasks.PersonaResearch do
  @moduledoc """
  Agent task for running a persona research session.

  `command/2` builds a prompt that references the knowledge base playbook at
  `priv/knowledge/persona_research/` and names the expected output paths under
  `.code_my_spec/personas/<slug>/`. The agent drives a PM intake conversation,
  does web + knowledge research, and writes a DB record plus two markdown files.

  `evaluate/2` delegates to `PersonasChecker.complete?/1` and adapts its
  `{boolean, map}` return into the standard task-evaluation tuple.
  """

  alias CodeMySpec.Requirements.PersonasChecker

  @spec analyzers() :: [atom()]
  def analyzers, do: []

  @spec orchestrate(map()) :: String.t()
  def orchestrate(node) do
    "Run persona research — interview the PM, research, write record + summary.md + sources.md. " <>
      "Call `start_task` with requirement_name `#{node.name}`, " <>
      "entity_type `#{node.entity_type}`, entity_id `#{node.entity_id}`."
  end

  @spec command(term(), map()) :: {:ok, String.t()}
  def command(_scope, _task) do
    {:ok, prompt()}
  end

  @spec evaluate(term(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(scope, _task) do
    case PersonasChecker.complete?(scope, nil) do
      {true, _detail} ->
        {:ok, :valid}

      {false, %{reason: reason}} when is_binary(reason) ->
        {:ok, :invalid, reason}

      {false, detail} ->
        {:ok, :invalid, inspect(detail)}
    end
  end

  defp prompt do
    """
    # Persona Research

    You are running a **persona research session** with the Product Manager on this project.
    Output: one persona in the database (via the `create_persona` MCP tool) and two markdown files
    on disk. Link the persona to at least one story with `link_persona_to_story` before stopping.

    ## Prereqs

    Personas are **account-scoped**, not project-scoped. `create_persona` and
    `link_persona_to_story` need the scope to carry an `active_account_id`, which the local MCP
    resolves from the project record's `account_id` column. If `create_persona` returns
    `missing_active_account`, the project is not linked to an account — re-run `init_project`
    to (re)bind the project to your account, then retry.

    ## Existing personas in this account

    Before creating a new persona, check whether one already covers the PM's target user:

    - `list_personas` — lists every persona in the active account. Use it early in the
      intake to see if a prior session already researched this role.
    - `get_persona` — fetch a full persona record by `slug` or `id`. Pair with
      `read_knowledge` on `.code_my_spec/personas/<slug>/summary.md` to see the research text.

    Reusing an existing persona (via `link_persona_to_story`) is often the right answer —
    don't research a duplicate if a close match already exists in the account.

    ## Read the playbook first

    Before writing anything, load these files from the knowledge MCP server
    (`read_knowledge` tool) to orient yourself and shape the conversation:

    - `persona_research/README.md` — canonical workflow order, guardrails
      (triangulate, verbatim wins, evidence footer)
    - `persona_research/overview.md` — what a persona is, which type to build
      (proto / qualitative / statistical), Cooper roles, Goodwin goal types
    - `persona_research/pm_intake.md` — the 15-question intake bank + artifact checklist
    - `persona_research/primary_research.md` — planning fresh user interviews
      if the PM has no existing qualitative data

    ## The session

    1. **Intake conversation.** Open with the questions from `pm_intake.md`. The PM
       brings whatever context they have — notes, hypotheses, nothing at all. You ask,
       they answer. Do not start writing until you have enough signal.

    2. **Challenge thin input.** If the PM's input is a one-liner, push back with
       targeted follow-up questions covering Role, Goals, Pain Points, Context, and
       Decision Drivers. If the PM refuses to provide more context, end the session
       rather than produce a low-evidence persona. Thin in, nothing out.

    3. **Research.** Once you have signal, do the research. Use web search and the
       knowledge MCP server. Cite every source. If sources disagree, surface the
       conflict to the PM. If research produces no supporting data, ask the PM for
       source leads — do not invent content.

    4. **Write the artifacts.** All three must exist before you stop:

       - **Database record.** Call `create_persona` on the `personas-server` with
         `slug`, `name`, and optional `headline`. Slug must be lowercase alphanumeric
         (hyphens or underscores allowed). Pick a memorable name.
       - **`.code_my_spec/personas/<slug>/summary.md`.** Structured markdown with an
         H1 matching the persona name and the following H2 sections (required):
         `## Role`, `## Goals`, `## Pain Points`, `## Context`,
         `## Decision Drivers`, `## Evidence`. Optional H2 sections: `## Jobs to Be Done`,
         `## Quotes`, `## Motivations`, `## Behaviors`, `## Anti-Patterns`. Any other
         section name will fail validation.
       - **`.code_my_spec/personas/<slug>/sources.md`.** Link list with URL, title,
         and access date per entry — one entry per line.

    5. **Link to a story.** Call `link_persona_to_story` on the `personas-server` with
       the persona's id and a story id this persona applies to. At least one link is
       required before the requirement can be satisfied.

    ## Evidence bar

    - Triangulate — no claim enters `summary.md` unless ≥3 independent sources
      support it (see `persona_research/README.md#guardrails`).
    - Verbatim quotes beat paraphrase. Save exact wording with attribution.
    - Every claim traces to an entry in `## Evidence`. If it doesn't, cut it.
    - Decision-useful or cut it — if a field wouldn't change a product decision,
      remove it.

    ## Done signal

    The `personas_complete` requirement is satisfied when:

    - ≥1 persona linked to this project via `persona_stories`.
    - Every linked persona has a DB row, a valid `summary.md` (all required sections),
      and a non-empty `sources.md`.

    ## This is a manual-validation task

    The stop hook does NOT auto-evaluate this requirement — that would cut the
    intake conversation short every time you stopped to ask the PM a question.
    You own the completion signal:

    - Freely stop between turns to let the PM respond. Each stop is cheap; the
      task stays active across stops.
    - When **you believe** all conditions above are met, call `evaluate_task`
      explicitly to run the checker. Pass/fail feedback comes back; on pass,
      the task completes and the graph advances.
    - If the PM directs you to abandon the session (refuses to provide
      evidence, walks away), stop the task by calling `evaluate_task` with a
      brief summary — the checker will report "unsatisfied" and the
      requirement remains open for the next run.

    Never fabricate artifacts to pass the checker. Thin in, nothing out.
    """
  end
end
