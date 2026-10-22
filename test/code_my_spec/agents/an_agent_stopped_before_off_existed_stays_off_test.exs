defmodule CodeMySpec.Agents.AnAgentStoppedBeforeOffExistedStaysOffTest do
  @moduledoc """
  2026-10-05, v2.0.372: phase 2 made `off_at` and `retired_at` the only
  turned-off states. Agents stopped before `off_at` existed had neither, read as
  on duty, and every harness join restored them: about 190 old agents came up
  and spent money. Nothing in the suite seeded a row from before `off_at`.

  The migration turns those legacy stops off. A `:reaped` agent went away while
  on duty and is still restored.
  """

  use CodeMySpecTest.DataCase, async: false

  # Replays a Postgres migration (priv/repo/migrations): Postgres only.
  @moduletag :postgres

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies
  alias Ecto.Adapters.SQL.Sandbox

  @version 20_261_005_130_000
  @migration "priv/repo/migrations/20261005130000_an_agent_stopped_before_off_existed_is_off.exs"

  defp agent(scope, role) do
    {:ok, copy} = WorkingCopies.issue(scope, nil, label: role, device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, "/legacy/#{role}")

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        working_copy: copy.root,
        working_copy_id: copy.id
      })

    agent
  end

  # A row as the code before 2026-09-28 left it: stopped, and nothing more.
  defp stopped(agent, reason) do
    import Ecto.Query, only: [from: 2]

    Repo.update_all(
      from(a in "agents", where: a.id == type(^agent.id, :binary_id)),
      set: [status: "stopped", stopped_reason: reason, off_at: nil]
    )

    agent
  end

  defp on_duty(scope), do: scope |> Agents.list_on_duty() |> MapSet.new(& &1.id)

  test "a legacy stop is off afterwards, and a reaped agent is still restored" do
    scope = full_scope_fixture()
    before_reasons = stopped(agent(scope, "main"), nil)
    turned_off = stopped(agent(scope, "coding"), "stopped")
    reaped = stopped(agent(scope, "qa"), "reaped")
    running = agent(scope, "product")

    assert MapSet.member?(on_duty(scope), before_reasons.id),
           "the regression itself: a legacy stop reads as on duty"

    # Already applied to this database; run it again inside the sandbox.
    Sandbox.mode(Repo, {:shared, self()})
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@version])
    [{module, _}] = Code.require_file(@migration)
    assert :ok = Ecto.Migrator.up(Repo, @version, module, log: false, migration_lock: false)

    duty = on_duty(scope)
    refute MapSet.member?(duty, before_reasons.id), "a stop from before stopped_reason restored"
    refute MapSet.member?(duty, turned_off.id), "a turn-off from before off_at restored"
    assert MapSet.member?(duty, reaped.id), "a reaped agent lost its restore"
    assert MapSet.member?(duty, running.id)
  end
end
