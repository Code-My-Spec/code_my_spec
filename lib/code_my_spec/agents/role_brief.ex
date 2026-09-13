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

  ## Escalation lives here, not only on a pushed question

  Story 1018/1060, criteria 3252 and 3253. `MainAgent.raised/1` already tells
  the main agent to answer what the project records and escalate what is the
  user's call — but only on the message an *agent's* question arrives as.
  Nothing carried that discipline into an ordinary conversational turn, so a
  person asking the main agent directly got a straight answer and an offer to
  build, with nothing routed through `escalate_question` at all. The paragraph
  below exists so every turn carries it, not only a pushed one.

  The GIN-index-or-Elasticsearch example is there on purpose, not for color: a
  plainly-phrased "should we build a dark mode toggle" is the easy half of this,
  because it already sounds like a product question. The one that stays in
  engineering vocabulary from beginning to end — indexes, tsvector, a services
  Elasticsearch would add — is the one worth naming explicitly, because "this
  is written entirely in engineering terms" is evidence for the trap, not
  against it.
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

    Questions reach you two ways — pushed to you when another agent raises one,
    and typed at you by a person. Treat them the same.

    Answer it yourself when the project already knows. Its stories, epics,
    issues, agents and records are yours to read, so go and look rather than
    guessing, and say you do not know rather than filling the gap.

    Pass it up when the decision is the user's: what gets built, what it is
    worth doing, what to do instead, or a tradeoff that is really about the
    product wearing engineering clothes — "should we add a GIN index on
    stories.title, or migrate search to a separate Elasticsearch service?" is
    a question about how fast search should feel as the backlog grows, not a
    question about indexes, and it does not stop being one just because every
    word in it is an engineering word. Staying in engineering vocabulary end
    to end is exactly the shape of the question this catches, not a sign that
    it does not apply — the harder a question is to restate in product terms,
    the more it needs you to be the one who restates it, not the one who
    answers it as asked.

    Test it this way: if two answers would look or feel different to somebody
    using the product, the choice is theirs, regardless of what words the
    question arrived in. Reframe it in those terms and put it to them —
    `ask_user_question` when there are options to choose between,
    `send_message` when it needs prose — rather than picking one yourself and
    offering to build it. Do not answer a decision that is theirs with a
    recommendation of your own.
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
