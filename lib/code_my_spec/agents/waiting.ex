defmodule CodeMySpec.Agents.Waiting do
  @moduledoc """
  Why an agent is legitimately waiting, or nil.

  An agent waiting on something that will reach it when it lands is neither
  nudged at turn end (`StopDecision`) nor offered a turn (`Work`): either one
  only buys a "still waiting" turn. Each entry in `@checks` names the paths it
  holds — `:turn_end` (`StopDecision`), `:wake` and `:resume` (`Work`) — and
  answers nil or a reason; the first reason wins. A new kind of wait is one
  entry here.

  Not entries, deliberately:

    * A pending question. It blocks only the task it was asked about, so the
      agent stays available for everything else (0b324cab).
    * The decline damper (`Work.already_declined?/2`). It is about the offer,
      not the agent: the same agent is offered a *different* offer at once.
  """

  import Ecto.Query

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Analysis
  alias CodeMySpec.Provisioning.RunLock
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @type reason ::
          {:provider_refused, DateTime.t()}
          | {:provisioning, String.t() | nil}
          | :tap_out
          | :analysis_runs

  @type path :: :turn_end | :wake | :resume

  @all [:turn_end, :wake, :resume]

  # Each check and the paths it holds, cheapest first: the row, the registry,
  # then the database. Analysis holds only the turn-end message — it never
  # keeps an agent from work (analysis and requirements are orthogonal).
  @checks [
    provider_refused: @all,
    provisioning: @all,
    tap_out: @all,
    analysis_runs: [:turn_end]
  ]

  @spec reason(Scope.t(), Agent.t(), path()) :: reason() | nil
  def reason(%Scope{} = scope, %Agent{} = agent, path) when path in @all do
    Enum.find_value(@checks, fn {name, paths} ->
      if path in paths, do: check(name, scope, agent)
    end)
  end

  # The provider refused its last turn and named when to come back (044599cc).
  # A turn before then is refused again.
  defp check(:provider_refused, _scope, %{provider_retry_at: %DateTime{} = at}) do
    if DateTime.compare(at, DateTime.utc_now()) == :gt, do: {:provider_refused, at}
  end

  defp check(:provider_refused, _scope, _agent), do: nil

  # A provisioning run it started is in flight; the run messages it on landing
  # (1599c109).
  defp check(:provisioning, _scope, agent) do
    case RunLock.held_by(agent.id) do
      nil -> nil
      run -> {:provisioning, run.label}
    end
  end

  # Holding nothing and waiting on its tap-out; the decision wakes it (070d1bab,
  # fad1a314). An agent still holding a task is not idle on it.
  defp check(:tap_out, _scope, agent) do
    if is_nil(Agent.active_task(agent)) and awaiting_tap_out?(agent), do: :tap_out
  end

  # Analyzer runs it requested or waits on; `AnalysisReport` messages it when
  # each lands or fails. metric_flow 2026-09-27: 5-27 "still waiting" turns an
  # hour without this.
  defp check(:analysis_runs, scope, agent) do
    if Analysis.awaiting_runs?(scope, agent.working_copy_id, agent.id), do: :analysis_runs
  end

  @doc """
  Whether this agent has a tap-out waiting on a person.

  Read off the pending request rather than a blocked task: a tap-out with no
  `task_id` blocks no task (fad1a314). Schemaless because `Notifications`,
  which owns the row, depends on `Agents`.
  """
  @spec awaiting_tap_out?(Agent.t()) :: boolean()
  def awaiting_tap_out?(%Agent{id: agent_id}) do
    from(p in "permission_requests",
      where:
        p.agent_id == type(^agent_id, :binary_id) and p.tool_name == "tap_out" and
          p.status == "pending"
    )
    |> Repo.exists?()
  end
end
