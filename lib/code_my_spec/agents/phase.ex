defmodule CodeMySpec.Agents.Phase do
  @moduledoc """
  One step of a conversation an agent finishes before the next one starts.

  A phase names four things: what the agent is trying to do (`c:goal/1`), what
  it may call to do it (`c:tools/1`), what to do with what it called
  (`c:commit/2`), and whether that finished the job (`c:evaluate/1`). `advance/3`
  runs them.

  ## Why this is not an agent task

  `CodeMySpec.AgentTasks` asks the same two questions — build a prompt, judge the
  result — and answers them for work on a checkout. Its evaluations read files
  through `Environments`, its results land on a `Session`, and the stop hook
  around it reasons about `git_rewrite_at` and tool attribution to decide whether
  a session may finish. A conversation with a visitor who has not signed up has
  no checkout, no session and no working copy, so every one of those would need a
  null to step over.

  The graph is the sharper version of the same argument. Requirement nodes hang
  off a project, a component or a story through `node_scope`, and intake runs
  before any of the three exists. `RequirementDefinitionData` also records what
  happened the last time a multi-turn human conversation was modelled as a node:
  `personas_complete`, `stories_exist` and `three_amigos_complete` all carry
  `validation_type: :manual` so the stop hook would not cut the conversation
  short, and a session holding a manual task leaves `Hooks.Stop.do_decide/6`
  before validation runs at all. Measured on 2026-08-28, 44 of 55 main stops
  skipped spex, credo and exunit entirely because a QA task was open.

  So this borrows the shape and none of the machinery.

  ## The loop is driven by turns, not by a `while`

  The obvious reading of "work until the form is filled in" is a loop that runs
  until `c:evaluate/1` passes. That is right for a phase talking to a filesystem
  and wrong for one talking to a person: the missing field is usually missing
  because nobody has been asked yet, and spinning on it would burn the budget
  without learning anything.

  So `c:evaluate/1` has three answers, not two. `:complete` advances,
  `{:incomplete, feedback}` runs again with the feedback appended — the model
  produced something unusable and gets told why — and `{:ask, question}` parks
  the phase. Parking is a success: the caller shows the question, and the next
  human turn calls `advance/3` again with the answer in the state.

  Only `{:incomplete, _}` consumes an attempt, which is what keeps a model that
  cannot fill the form from looping forever while leaving a conversation free to
  take as many turns as the person needs.

  ## State is the caller's, and nothing here writes

  `c:commit/2` folds a tool call into the phase's own state and returns it.
  Persisting is the caller's, deliberately: `CodeMySpec.Intake` already owns the
  writes for its plan — `ask/2`, `answer/2`, `record_turn/3` — and a phase that
  also wrote would double-write a row two tabs are already racing on. It keeps
  the pure part pure, so a phase can be run in a test without a database.
  """

  use Boundary, top_level?: true, deps: [], exports: :all

  alias CodeMySpec.Agents.Phase.Model

  @typedoc "Whatever the phase carries between turns. Opaque to the runner."
  @type state :: term()

  @typedoc "Why the last attempt was unusable, in terms the model can act on."
  @type feedback :: String.t()

  @typedoc "Something to put to the person before the phase can go on."
  @type question :: String.t()

  @typedoc """
  What `advance/3` settled on.

  `{:ask, question, state}` is not an error — it is the phase waiting for a human.
  """
  @type outcome ::
          {:complete, state()}
          | {:ask, question(), state()}
          | {:error, term()}

  @doc "What the agent is being asked to do, given everything known so far."
  @callback goal(state()) :: String.t()

  @doc """
  The tools this phase may call.

  Per phase rather than per agent: a phase that can only read the form should not
  be holding the tool that submits it.
  """
  @callback tools(state()) :: [module() | Alloy.Tool.Inline.t()]

  @doc """
  Folds one tool call into the state. Does not persist — see the moduledoc.
  """
  @callback commit(state(), map()) :: {:ok, state()} | {:error, term()}

  @doc """
  Whether the phase is finished, waiting on a person, or needs another attempt.
  """
  @callback evaluate(state()) :: :complete | {:ask, question()} | {:incomplete, feedback()}

  # Three, because the failures this retries are a model returning prose instead
  # of a tool call or dropping a required field, and a model that does that twice
  # running is not about to stop. The budget is per `advance/3` call, so a long
  # conversation gets three fresh attempts per human turn rather than three for
  # the whole phase.
  @default_attempts 3

  @doc """
  Runs `phase` until it completes, parks for a person, or runs out of attempts.

  ## Options

    * `:attempts` — how many times an `{:incomplete, _}` may be retried
      (default: #{@default_attempts})
    * `:model` — a `"provider:model"` string, passed to `Model.run/3`
    * `:until_tool` — the tool whose call ends a turn. Only needed when
      `c:tools/1` returns more than one.
    * `:model_module` — anything exporting `run/3` (default:
      `CodeMySpec.Agents.Phase.Model`). The seam a test uses to drive the loop
      without a network call: retrying an `{:incomplete, _}` and giving up are
      this module's own logic, and proving them should not cost a recorded
      cassette per branch.

  Every other option goes through to the model module.
  """
  @spec advance(module(), state(), keyword()) :: outcome()
  def advance(phase, state, opts \\ []) when is_atom(phase) do
    {attempts, opts} = Keyword.pop(opts, :attempts, @default_attempts)
    {model, opts} = Keyword.pop(opts, :model_module, Model)

    attempt(phase, state, nil, attempts, model, opts)
  end

  defp attempt(_phase, _state, feedback, attempts_left, _model, _opts) when attempts_left <= 0 do
    {:error, {:not_converging, feedback}}
  end

  defp attempt(phase, state, feedback, attempts_left, model, opts) do
    prompt = prompt(phase.goal(state), feedback)

    with {:ok, input} <- model.run(prompt, phase.tools(state), opts),
         {:ok, committed} <- phase.commit(state, input) do
      settle(phase, committed, attempts_left, model, opts)
    end
  end

  defp settle(phase, state, attempts_left, model, opts) do
    case phase.evaluate(state) do
      :complete ->
        {:complete, state}

      {:ask, question} ->
        {:ask, question, state}

      {:incomplete, feedback} ->
        attempt(phase, state, feedback, attempts_left - 1, model, opts)
    end
  end

  defp prompt(goal, nil), do: goal

  # Appended rather than prepended. The goal carries the instruction to call the
  # tool, and a model reads the end of a prompt as the thing to do next — putting
  # the correction first left the original instruction as the last word and the
  # same mistake came back.
  defp prompt(goal, feedback) do
    """
    #{goal}

    Your last answer could not be used: #{feedback}

    Answer again, fixing that.
    """
  end
end
