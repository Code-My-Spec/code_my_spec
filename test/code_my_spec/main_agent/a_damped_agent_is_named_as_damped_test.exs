defmodule CodeMySpec.Agents.Main.ADampedAgentIsNamedAsDampedTest do
  @moduledoc """
  35e80d6d — a damped agent read as plain idle.

  metric_flow's coder declined story 33's `bdd_specs_passing` five times, and
  `Work` stopped offering it for ten minutes. `list_agent_work` and `check_in`
  showed nothing about that, so the main agent could not tell it was waiting
  out a damper rather than out of work. John: nothing re-offers at expiry; the
  main agent handles it on its wake, and needs to see it.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Main.AgentWork
  alias CodeMySpec.Agents.Work

  @until ~U[2026-09-30 08:59:23Z]

  defp damped do
    struct(AgentWork,
      agent_status: :running,
      role: :coding,
      continuous?: true,
      damped: %{count: 5, requirement: "bdd_specs_passing", until: @until}
    )
  end

  test "the line names the damper, the requirement and when it lifts" do
    line = AgentWork.unclaimed_work(damped())

    refute line =~ "STALLED"
    assert line =~ "damped after 5 declines of bdd_specs_passing until 2026-09-30T08:59:23Z"
    assert line =~ "message_agent"
  end

  describe "Work.damped/3" do
    setup do
      %{scope: full_scope_fixture()}
    end

    defp story_33, do: %{entity_type: "story", entity_id: 33, name: "bdd_specs_passing"}

    defp agent(attrs),
      do: struct(Agent, Map.merge(%{role: :coding, id: Ecto.UUID.generate()}, attrs))

    test "an agent past the repeat limit on the current offer is damped", %{scope: scope} do
      at = DateTime.utc_now()
      fingerprint = Work.offer_fingerprint(scope, agent(%{}), [story_33()])

      assert %{count: 5, requirement: "bdd_specs_passing", until: until} =
               Work.damped(
                 scope,
                 agent(%{
                   declined_offer: fingerprint,
                   declined_offer_count: 5,
                   declined_offer_at: at
                 }),
                 [story_33()]
               )

      assert DateTime.diff(until, at) == 600
    end

    test "below the limit, expired, or on a different offer it is not", %{scope: scope} do
      fp = Work.offer_fingerprint(scope, agent(%{}), [story_33()])
      now = DateTime.utc_now()
      old = DateTime.add(now, -601, :second)

      assert nil ==
               Work.damped(
                 scope,
                 agent(%{declined_offer: fp, declined_offer_count: 4, declined_offer_at: now}),
                 [story_33()]
               )

      assert nil ==
               Work.damped(
                 scope,
                 agent(%{declined_offer: fp, declined_offer_count: 5, declined_offer_at: old}),
                 [story_33()]
               )

      assert nil ==
               Work.damped(
                 scope,
                 agent(%{
                   declined_offer: "other",
                   declined_offer_count: 5,
                   declined_offer_at: now
                 }),
                 [story_33()]
               )
    end
  end
end
