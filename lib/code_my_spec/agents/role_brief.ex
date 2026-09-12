defmodule CodeMySpec.Agents.RoleBrief do
  @moduledoc """
  What an agent is for, in its own words, sent to it as the first half of its
  system prompt.

  Until this existed no system prompt was sent at all. `Alloy.Agent.Config`
  accepts one and defaults it to nil, and nothing ever set it — so every agent
  came up knowing only whatever message arrived next. Asked directly what its
  job was, the war epic's product agent answered "My job was to call
  `list_epics` and reply with exactly its result, which I did." Its role decided
  which tools existed and never what it was for. Issue `0f022a10`.

  ## Why these words and not new ones

  Each brief is the boundary `ToolSets` already draws, said to the agent rather
  than about it. That module decides which tools a role gets and explains why in
  the same breath — "a QA agent that can rewrite a criterion can make a failing
  run pass without anybody deciding to" — which is the sharpest statement of
  each role we have. Writing a second description beside it would give us two
  places to disagree about what a QA agent is, and the tool list is the half
  that is enforced.

  So when a role's tools change, this changes with them, and the pair stays one
  decision.

  ## Three things, not one

  The brief below says what a role is for. `OperatingRules` says how the
  machinery behaves — which tools answer before their work is done, what
  actually blocks a story, what an agent must not do by hand — and is the same
  for every role, so it lives beside these rather than being repeated four
  times and drifting. Both travel together as the framework's half of the
  prompt.

  Every rule in that module was delivered by hand to a running agent after it
  had already gone the wrong way. An agent told what it is for and left to infer
  the rest from whatever codebase it is standing in will infer wrong, and the
  most expensive hour of 2026-09-10 was a coding agent building a
  `config/dev_cli.exs` for a game because it had seen that env in CodeMySpec's
  own justfile.

  ## What is deliberately not here

  Project context. `compose/2` on the harness appends the project's own
  `.code_my_spec/AGENTS.md`, which is per-project, already written, and already
  what an external agent is handed. John's call, and the reason is that these
  two halves are maintained in different places by different people: the role is
  the framework's, the workflow is the project's.
  """

  alias CodeMySpec.Agents.OperatingRules
  alias CodeMySpec.Utils

  @briefs %{
    main: """
    You are the MAIN agent on this project.

    Your job is the whole project: shaping stories, organising epics, handing
    work over to other agents, and checking what comes back. You may call every
    tool there is, because scoping you would scope the thing that checks the
    others.

    You edit code when the work calls for it, and you are answerable for the
    files you edit.
    """,
    product: """
    You are the PRODUCT agent on this project.

    Your job is shaping what gets built, and never building it: stories,
    acceptance criteria, rules, personas, epics. Run Three Amigos sessions,
    interview for stories, organise them into epics, and mark them ready.

    You do not write application code, and findings about code are not yours to
    fix. If analysis reports a failing test or a lint finding in a file you did
    not edit, it belongs to whoever wrote it — say so and carry on with your own
    work rather than trying to clear it.
    """,
    coding: """
    You are the CODING agent on this project.

    Your job is writing code against a spec, and reading everything that says
    what the spec is. You are answerable for the files you edit — when analysis
    reports a finding in one of them, it is yours.

    You resolve the issues you fix — `resolve_issue` is yours and the FixIssues
    workflow runs on it.

    You cannot *triage*: `accept_issue` and `dismiss_issue` are product's,
    because deciding whether a report is worth acting on is a different judgement
    from fixing it. And you cannot submit QA results, because an agent that
    grades its own work is not being graded.
    """,
    qa: """
    You are the QA agent on this project.

    Your job is testing a story against the running app and writing down what
    you found: file issues, submit a QA result, invalidate an attempt that was
    not sound.

    You cannot edit the story you are testing. That is deliberate: an agent that
    can rewrite a criterion can make a failing run pass without anybody deciding
    to. If a criterion is wrong, file an issue saying so.
    """
  }

  @doc """
  The brief for `role`, or `nil` when there is nothing to say.

  `nil` rather than a generic paragraph: an agent told something vague about
  itself is worse off than one told nothing, because it will act on it. A role
  this does not know about is a role whose boundary nobody has written down yet.
  """
  @spec for(atom() | String.t() | nil) :: String.t() | nil
  def for(role) when is_binary(role) do
    __MODULE__.for(Utils.safe_to_existing_atom(role))
  end

  def for(role) when is_atom(role) and not is_nil(role) do
    case Map.get(@briefs, role) do
      nil -> nil
      brief -> String.trim(brief) <> "\n\n" <> OperatingRules.text()
    end
  end

  def for(_role), do: nil

  @doc "Every role that has a brief."
  @spec roles() :: [atom()]
  def roles, do: Map.keys(@briefs)
end
