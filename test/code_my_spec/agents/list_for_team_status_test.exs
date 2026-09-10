defmodule CodeMySpec.Agents.ListForTeamStatusTest do
  @moduledoc """
  The team-status panel's own listing, separate from `list_running/1`.

  John, after clicking the new stop button on his own conversation: "it
  completely killed the agent. Like it left the list... I should still be
  able to get back to the agent." `Rows.list/3` fed the panel from
  `list_running/1`, which is `status in [:starting, :running]` by design —
  correct for `main_agent/1`'s occupancy check, wrong for a display that a
  human just interacted with. The instant an agent stops, its row (and the
  transcript link on it) vanished, with nothing in the data actually
  deleted — stopping just isn't the same act as removing the row from a
  view whose job is "what belongs in this slot right now".

  `list_for_team_status/1` is that view: everything running, plus a
  role's most recently stopped agent when nothing has replaced it —
  bounded to one row per `(working_copy_id, role)` slot rather than
  accumulating every agent that copy has ever run.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import Ecto.Query

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Repo

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    %{scope: scope, copy: copy}
  end

  defp agent(scope, copy, attrs) do
    {:ok, agent} =
      AgentsRepository.create_agent(
        scope,
        Map.merge(
          %{
            provider: "anthropic",
            engine: :alloy,
            continuous: false,
            working_copy: "/tmp/team-status-#{System.unique_integer([:positive])}",
            working_copy_id: copy.id
          },
          attrs
        )
      )

    agent
  end

  defp stop(scope, agent) do
    {:ok, stopped} = Agents.stop_agent(scope, agent.id)
    stopped
  end

  # `updated_at` is `:utc_datetime` (second resolution), so agents stopped in
  # the same test — same wall-clock second — tie, and the DB is free to break
  # the tie either way. Stamping distinct timestamps directly is this
  # project's own answer to that, not a sleep between them.
  defp backdate(agent, seconds_ago) do
    at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second) |> DateTime.truncate(:second)

    {1, _} =
      from(a in Agent, where: a.id == ^agent.id) |> Repo.update_all(set: [updated_at: at])

    %{agent | updated_at: at}
  end

  test "a running agent is listed", %{scope: scope, copy: copy} do
    running = agent(scope, copy, %{role: "coding", status: :starting})

    assert Enum.any?(Agents.list_for_team_status(scope), &(&1.id == running.id))
  end

  test "a stopped agent with nothing to replace it is still listed", %{
    scope: scope,
    copy: copy
  } do
    agent = agent(scope, copy, %{role: "coding", status: :starting})
    stopped = stop(scope, agent)

    assert Enum.any?(Agents.list_for_team_status(scope), &(&1.id == stopped.id)),
           "the slot's only agent stopped — dropping the row makes stopping look like deleting"
  end

  test "list_running/1 still excludes it — occupancy checks must not change", %{
    scope: scope,
    copy: copy
  } do
    agent = agent(scope, copy, %{role: "coding", status: :starting})
    stopped = stop(scope, agent)

    refute Enum.any?(Agents.list_running(scope), &(&1.id == stopped.id)),
           "main_agent/1 and every occupancy check read list_running/1 as " <>
             "\"is anything actually running\" — a stopped agent counting as " <>
             "running there would refuse a legitimate restart"
  end

  test "a slot's stopped agent is superseded once a new one starts there", %{
    scope: scope,
    copy: copy
  } do
    first = agent(scope, copy, %{role: "coding", status: :starting})
    stop(scope, first)
    second = agent(scope, copy, %{role: "coding", status: :starting})

    ids = Agents.list_for_team_status(scope) |> Enum.map(& &1.id)

    assert second.id in ids

    refute first.id in ids,
           "the slot has a running agent again — showing the old stopped one beside " <>
             "it is the accumulation this function exists to bound against"
  end

  test "only the most recent of several past agents in one slot is shown", %{
    scope: scope,
    copy: copy
  } do
    oldest =
      agent(scope, copy, %{role: "coding", status: :starting})
      |> then(&stop(scope, &1))
      |> backdate(120)

    _middle =
      agent(scope, copy, %{role: "coding", status: :starting})
      |> then(&stop(scope, &1))
      |> backdate(60)

    newest = agent(scope, copy, %{role: "coding", status: :starting}) |> then(&stop(scope, &1))

    ids = Agents.list_for_team_status(scope) |> Enum.map(& &1.id)

    assert newest.id in ids

    refute oldest.id in ids,
           "every restart mints a new row — three stops in one role's history " <>
             "must not show as three rows, only the current one"
  end

  test "different roles on the same copy are independent slots", %{scope: scope, copy: copy} do
    coding = agent(scope, copy, %{role: "coding", status: :starting}) |> then(&stop(scope, &1))
    qa = agent(scope, copy, %{role: "qa", status: :starting})

    ids = Agents.list_for_team_status(scope) |> Enum.map(& &1.id)

    assert coding.id in ids
    assert qa.id in ids
  end
end
