defmodule CodeMySpec.Agents.Phase do
  @moduledoc """
  One step of a conversation an agent finishes before the next one starts.

  A phase names four things: what the agent is trying to do (`c:goal/1`), what
  it may call to do it (`c:tools/1`), what to do with what it called
  (`c:commit/2`), and whether that finished the job (`c:evaluate/1`). `advance/3`
  runs them.

  ## Why this is not an agent task

  `CodeMySpec.AgentTasks` asks the same two questions — build a prompt, judge
  the result — for work on a checkout, through `ExecutionContexts` and a `Session`.
  A conversation with a visitor who has not signed up has no checkout, session,
  working copy or project for a requirement node to hang off. So this borrows
  the shape and none of the machinery.

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
  Persisting is the caller's: `CodeMySpec.Intake` owns the writes for its plan
  (`ask/2`, `answer/2`, `record_turn/3`), and a phase that also wrote would
  double-write a row two tabs race on. A phase runs in a test without a database.
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

  # Retries a model returning prose instead of a tool call or dropping a field;
  # one that does it twice running is not about to stop. Per `advance/3` call,
  # so per human turn.
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
      without a network call.

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

  # Appended: a model reads the end of a prompt as the thing to do next, and a
  # correction placed first brought the same mistake back.
  defp prompt(goal, feedback) do
    """
    #{goal}

    Your last answer could not be used: #{feedback}

    Answer again, fixing that.
    """
  end
end
