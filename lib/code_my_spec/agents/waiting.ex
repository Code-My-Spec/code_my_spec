defmodule CodeMySpec.Agents.Waiting do
  @moduledoc """
  Why an agent is legitimately waiting, or nil.

  An agent waiting on something that will reach it when it lands is neither
  nudged at turn end (`StopDecision`) nor offered a turn (`Work`): either one
  only buys a "still waiting" turn. Each entry in `@checks` names the paths it
  holds — `:turn_end` (`StopDecision`), `:offer` (a work offer), `:wake` (any
  other event that starts a turn) and `:resume` (`Work`), `:cadence` (main's
  check-in turn) — and answers nil or a reason; the first reason wins. A new
  kind of wait is one entry here.

  An agent's own pending question holds the paths its role's
  `RoleProfile.waiting_on` names: main's only the nudge.

  Not entries, deliberately:

    * Any other role's pending question. It blocks only the task it was asked
      about, so the agent stays available for everything else (0b324cab,
      story 1080).
    * A tap-out naming a task. It blocks only that task (story 1080).
    * The decline damper (`Work.already_declined?/2`). It is about the offer,
      not the agent: the same agent is offered a *different* offer at once.
  """

  import Ecto.Query

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Analysis
  alias CodeMySpec.PromotionQueue.Waits
  alias CodeMySpec.Provisioning.RunLock
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @type reason ::
          {:provider_refused, DateTime.t()}
          | {:provisioning, String.t() | nil}
          | :tap_out
          | :analysis_runs
          | :promotion
          | :question_pending

  @type path :: :turn_end | :offer | :wake | :resume | :cadence

  @all [:turn_end, :offer, :wake, :resume, :cadence]

  # Each check and the paths it holds, cheapest first: the row, the registry,
  # then the database. Analysis holds the turn-end message and main's check-in
  # turn — never work (analysis and requirements are orthogonal). An open
  # question of its own holds what the role's `RoleProfile.waiting_on` says.
  @checks [
    provider_refused: @all,
    provisioning: @all,
    tap_out: @all,
    analysis_runs: [:turn_end, :cadence],
    promotion: @all,
    question_pending: @all
  ]

  @spec reason(Scope.t(), Agent.t(), path()) :: reason() | nil
  def reason(%Scope{} = scope, %Agent{} = agent, path) when path in @all do
    Enum.find_value(@checks, fn {name, paths} ->
      if path in paths, do: check(name, scope, agent, path)
    end)
  end

  # Waiting on the answer to its own question; the answer wakes it. Main's
  # event wakes (a teammate stalls, a step lands, a teammate asks) still reach
  # it. metric_flow 2026-10-01: main was nudged turn after turn while it waited.
  defp check(:question_pending, _scope, %{role: role} = agent, path) do
    if RoleProfile.waits_on?(role, :question_pending, path) and awaiting_question?(agent),
      do: :question_pending
  end

  defp check(name, scope, agent, _path), do: check(name, scope, agent)

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

  # Holding nothing and waiting on a tap-out naming no task; the decision wakes
  # it (070d1bab, fad1a314). An agent still holding a task is not idle on it.
  defp check(:tap_out, _scope, agent) do
    if is_nil(Agent.active_task(agent)) and awaiting_tap_out?(agent), do: :tap_out
  end

  # The promotion it asked for is in the queue; the queue messages it when the
  # batch lands or the candidate is ejected. An entry already resolved is the
  # agent's own turn to take.
  #
  # `@all`, like `provisioning`: the task stays open until the landing, so no
  # path here has anything useful to say about it.
  defp check(:promotion, _scope, agent) do
    case Waits.awaited_by(agent.id) do
      nil -> nil
      entry -> {:promotion, entry.id}
    end
  end

  # Analyzer runs it requested or waits on; `AnalysisReport` messages it when
  # each lands or fails. metric_flow 2026-09-27: 5-27 "still waiting" turns an
  # hour without this.
  defp check(:analysis_runs, scope, agent) do
    if Analysis.awaiting_runs?(scope, agent.working_copy_id, agent.id), do: :analysis_runs
  end

  # Schemaless for the reason `awaiting_tap_out?/1` is. Whoever holds it — the
  # user, or main for product's — except the agent itself: a question held by
  # its own role is one it is answering, not waiting on.
  defp awaiting_question?(%Agent{id: agent_id, role: role}) do
    own = own_holder(role)

    from(q in "question_requests",
      where:
        q.agent_id == type(^agent_id, :binary_id) and q.status == "pending" and
          q.holder != ^own
    )
    |> Repo.exists?()
  end

  defp own_holder(:main), do: "main_agent"
  defp own_holder(:product), do: "product_agent"
  defp own_holder(_role), do: ""

  @doc """
  Whether this agent has a tap-out naming no task waiting on a person.

  Read off the pending request rather than a blocked task: a tap-out with no
  `task_id` blocks no task (fad1a314). One naming a task holds only that task
  (story 1080). Schemaless because `Notifications`, which owns the row, depends
  on `Agents`.
  """
  @spec awaiting_tap_out?(Agent.t()) :: boolean()
  def awaiting_tap_out?(%Agent{id: agent_id}) do
    from(p in "permission_requests",
      where:
        p.agent_id == type(^agent_id, :binary_id) and p.tool_name == "tap_out" and
          p.status == "pending" and is_nil(p.task_id)
    )
    |> Repo.exists?()
  end
end
