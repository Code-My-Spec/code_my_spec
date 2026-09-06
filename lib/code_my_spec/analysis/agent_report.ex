defmodule CodeMySpec.Analysis.AgentReport do
  @moduledoc """
  Tell the agents in a working copy that their analysis has landed.

  The internal half of story 1042. There are two consumers of an analyzer
  result and they are not variations of one thing:

    * An **external** agent — Claude Code — keeps running and fires hooks. It is
      offered a wait endpoint, and the digest reaches it on `PostToolUse` via
      `Hooks.AnalysisAlert`. That path is a *pull*: the agent's next tool call
      collects it.

    * An **internal** agent — Alloy, in our own BEAM — has a process we can
      reach. It should start a run, end its turn, and be told when the run is
      done. That is a *push*, and it is this module.

  John, when the internal agent was found waiting on a `curl` instead: "the
  analysis tool is different for the Alloy agent — when we run analysis, the
  agent should stop, we should run analysis, and then when it's done running
  analysis it should message the Alloy agent back."

  ## Why the wording differs from the hook's

  `Alert.message/2` is capped at 199 characters, and its own comment says why:
  "it rides on every tool call in every turn, so the budget is a sentence."
  That is the *hook's* budget, not a message's. A push costs one delivery, so
  it can carry the counts by source and say what to do next — which is the
  difference between "something is failing" and something the agent can act on
  without a round trip.

  ## Silence is a result

  A clean run says nothing (criterion 3046). A message wakes a process and
  costs it a turn, and an agent woken to be told its tree is fine has been
  charged for no information — the same rule `StopDecision` keeps everywhere.

  Delivery is dispatched, never called: `message_agent/4` runs the whole turn
  inside a `GenServer.call`, and this runs inside the reconciler, which must not
  wait out an agent's reply to finish recording a run.

  An agent with no process is not owed delivery and is not a failure
  (criterion 3049). `dispatch_message` answers `{:error, :not_running}` and this
  drops it — an agent halted on purpose is not news anybody is waiting for.
  """

  require Logger

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Transport
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  import Ecto.Query

  @doc """
  Tell every internal agent in this run's working copy what landed.

  Answers `:ok` regardless. This runs at the end of `Reconciler.reconcile/4`,
  where the run has already been recorded — a delivery that fails must not make
  a completed run look incomplete.
  """
  @spec deliver(Scope.t(), atom() | String.t(), [struct()]) :: :ok
  def deliver(%Scope{active_working_copy_id: copy_id} = scope, source, problems)
      when is_binary(copy_id) do
    case digest(source, problems) do
      nil ->
        :ok

      message ->
        scope
        |> internal_agents(copy_id)
        |> Enum.each(&tell(&1, message))
    end
  end

  def deliver(_scope, _source, _problems), do: :ok

  # Alloy only. A Claude Code session in the same copy has its own path and
  # would be told twice — once here and once on its next tool call — which is
  # the duplicate criterion 3048 exists to keep out.
  defp internal_agents(%Scope{active_project_id: project_id}, copy_id) do
    Agent
    |> where(
      [a],
      a.working_copy_id == ^copy_id and a.project_id == ^project_id and
        a.status != :stopped and a.engine == :alloy
    )
    |> Repo.all()
  end

  defp tell(%Agent{} = agent, message) do
    ref = "analysis-" <> Ecto.UUID.generate()

    case Transport.impl().dispatch_message(agent.working_copy_id, agent, ref, message, 10_000) do
      {:ok, _disposition} ->
        :ok

      # Not a warning. Nobody to tell is an ordinary state — the agent was
      # stopped — and logging it as a failure is what criterion 3049 forbids.
      {:error, :not_running} ->
        :ok

      {:error, reason} ->
        Logger.info(
          "[Analysis] could not tell agent #{agent.id} about the run: #{inspect(reason)}"
        )

        :ok
    end
  end

  # What landed, by source, and what to do about it. `nil` when there is nothing
  # worth waking anyone for.
  defp digest(source, problems) do
    case Enum.count(problems, &(&1.severity == :error)) do
      0 ->
        nil

      count ->
        """
        Your #{source} run finished: #{count} #{noun(count)} in this working copy.

        Call `list_problems` for the detail. If they are yours, fix them and run
        the analyzers again; if the run says something you have already fixed,
        it measured the tree before your edit and the next one will disagree
        with it.
        """
    end
  end

  defp noun(1), do: "problem"
  defp noun(_), do: "problems"
end
