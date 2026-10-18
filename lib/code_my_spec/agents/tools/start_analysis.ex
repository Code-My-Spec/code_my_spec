defmodule CodeMySpec.Agents.Tools.StartAnalysis do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Analysis

  @sources ~w(spex exunit credo compiler)

  @impl true
  def name, do: "start_analysis"

  @impl true
  def description do
    """
    Start an analyzer run and return immediately.

    Sources: `spex`, `exunit`, `credo`, `compiler`. Returns as soon as the run is
    opened — it does not wait, and you should not wait for it.

    `paths` scopes the run to specific files, the same way the PreToolUse hook's
    own `mix test test/foo_test.exs` rewrite does. Scoped runs can never satisfy
    freshness — they cover only what they name — so use this for a focused
    validation, not as a substitute for the full sweep `ready_for_qa` reads.

    An agent running inside our own BEAM is sent the result as a message when the
    run lands, so the thing to do after calling this is stop. A Claude Code
    session collects it on its next tool call instead.
    """
  end

  @impl true
  def params do
    %{
      source: {:required, {:meta, :string, [description: "spex | exunit | credo | compiler"]}},
      paths:
        {:meta, {{:list, :string}, {:default, []}},
         [
           description:
             "Scope the run to these paths (e.g. one test file), instead of the full suite. Empty runs everything. A scoped run is `:partial` and can never satisfy freshness on its own — it covers only what it names."
         ]}
    }
  end

  @impl true
  def call(%{source: source} = params, context) when source in @sources do
    scope = context[:scope]
    agent_id = context[:agent_id]
    paths = Map.get(params, :paths, [])

    requested_by = %{kind: "mcp_tool", tool: "start_analysis", agent_id: agent_id}

    response =
      case Analysis.start_run(scope, source, paths, requested_by: requested_by) do
        {:ok, :skipped, run_id} ->
          {:error, "#{source} run #{run_id} skipped because of compiler errors."}

        {:ok, _admission, run_id} ->
          {:ok, "Run #{run_id} admitted.\n\n" <> started(source, agent_id)}

        {:error, :no_executor} ->
          {:error,
           "Cannot request #{source}: no harness is connected for this working copy " <>
             "and this server has no local analysis executor. Reconnect its harness and retry."}

        {:error, reason} ->
          {:error, "Could not admit #{source}: #{inspect(reason)}"}
      end

    response
  rescue
    error ->
      {:error, "Could not admit #{source}: #{Exception.message(error)}"}
  catch
    :exit, reason ->
      {:error, "Could not admit #{source}: #{inspect(reason)}"}
  end

  def call(%{source: source}, _context) do
    {:error, "#{inspect(source)} is not an analyzer. Use one of: #{Enum.join(@sources, ", ")}."}
  end

  # "Requested", not "Started", and the difference is not pedantry.
  #
  # Analyzer concurrency is one run machine-wide. A request made while another
  # copy is running queues behind it, and nothing on this side knows which
  # happened — the harness does, and logs "an analyzer run is waiting for a
  # machine-wide slot: 1 already running (limit 1), waiting up to 1800000ms".
  # Saying "Started" promises something this tool cannot check.
  #
  # The cost of the promise is an agent that holds its task and waits forever.
  # `Work.runnable_state?/1` skips an agent with an open task, so once it is
  # waiting on a result that never lands, no wake path in the system can reach
  # it — only a human message. Measured on the math project 2026-09-22 three
  # times in one session: 22, 25 and 26 minutes, each ended by hand, each agent
  # doing exactly what this text told it to do.
  #
  # So the text now says what is true (a request was recorded), what silence
  # means (it may be queued), and what to do about it (dispose of the task
  # rather than hold it open). `evaluate_task` answers "analysis pending" for a
  # run that has not landed, which is a clean turn end rather than a hang.
  defp started(source, agent_id) when is_binary(agent_id) do
    """
    Requested #{source}. A run usually takes several minutes.

    Do not wait for it and do not poll — the result is delivered to you as a
    message when it lands. Stop when you have nothing else to do.

    If it has not landed by your next turn, it may be queued: analyzer runs are
    one-at-a-time across this whole machine, so another checkout's run can be
    ahead of yours. That is ordinary and not a fault of yours.

    Do not hold a task open waiting for it. Close the loop with `evaluate_task`,
    which answers "analysis pending" while no fresh run exists — an agent
    holding an open task cannot be offered another turn, so waiting with one
    held is how a turn becomes an indefinite wait.
    """
  end

  defp started(source, _agent_id) do
    """
    Requested #{source}. It may be queued and usually takes several minutes.

    The digest reaches you on your next tool call once it lands. To block until
    it finishes instead, `POST localhost:4004/api/harnesses/<working_copy_id>/analysis/wait`.
    """
  end
end
