defmodule CodeMySpec.Agents.Offers.EveryKindEscalatesOnItsOwnLadderTest do
  @moduledoc """
  Story 1080, criteria 2055-2057: the escalation ladder is data, one per offer
  kind, and a kind's own length is its threshold.

  One @ladders map keyed by `{kind, subject_type}`; every reader takes its rung
  from it. A kind not in the map never escalates, so resume and check-in notices
  are unchanged (1742 now reads from the map rather than from a hard-coded
  `kind: :work` match).

  Two kinds, one ladder each, is what separates this from the special case it
  replaces: a requirement offer still takes three ignored offers to be held
  back, a denial offer takes one. Held back is always the last rung.
  """

  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Repo
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok = Fixtures.install_recording_agent_transport()
    :ok
  end

  describe "the ladder as data (2057)" do
    test "each kind has its own ladder, ending in held back", _ctx do
      ladders = Offers.ladders()

      assert Enum.all?(ladders, fn {_key, steps} -> List.last(steps) == :held_back end),
             "every ladder ends in held_back: #{inspect(ladders)}"

      assert length(ladders[{:work, "requirement"}]) == 3,
             "requirement work takes three ignored offers (1739-1741)"

      assert length(ladders[{:unblocked, "task"}]) == 2,
             "a released task is reminded once, then held back"

      assert length(ladders[{:denial, "tap_out"}]) == 1,
             "a declined tap-out notice is held back after one rung"
    end

    test "a kind with no ladder never escalates", _ctx do
      assert Offers.ladder({:resume, "task"}) == nil
      assert Offers.ladder({:check_in, "cadence"}) == nil
      assert Offers.ladder({:instruction, "message"}) == nil
    end
  end

  describe "the threshold is the ladder's length" do
    setup ctx do
      {:ok, agent} =
        AgentsRepository.create_agent(ctx.scope, %{
          provider: "anthropic",
          engine: :alloy,
          role: "coding",
          continuous: true,
          status: :running,
          working_copy: "/tmp/ladder-#{System.unique_integer([:positive])}",
          working_copy_id: ctx.scope.active_working_copy_id
        })

      %{agent: agent}
    end

    test "a denial offer is held back after its one rung", ctx do
      key = "r-#{System.unique_integer([:positive])}"
      ignored(ctx, :denial, "tap_out", key, 1)

      assert %{held?: true} = Offers.standing(ctx.agent.id)[key]
    end

    test "a requirement offer is not held back until its third", ctx do
      key = "story:1:component_spec"

      ignored(ctx, :work, "requirement", key, 1)
      assert %{ignored: 1, held?: false} = Offers.standing(ctx.agent.id)[key]

      ignored(ctx, :work, "requirement", key, 2)
      assert %{ignored: 2, held?: false} = Offers.standing(ctx.agent.id)[key]

      ignored(ctx, :work, "requirement", key, 3)
      assert %{ignored: 3, held?: true} = Offers.standing(ctx.agent.id)[key]
    end

    test "an unblocked task offer is held back after its second", ctx do
      key = "t-#{System.unique_integer([:positive])}"

      ignored(ctx, :unblocked, "task", key, 1)
      assert %{ignored: 1, held?: false} = Offers.standing(ctx.agent.id)[key]

      ignored(ctx, :unblocked, "task", key, 2)
      assert %{held?: true} = Offers.standing(ctx.agent.id)[key]
    end

    test "standing/1 reports the laddered kinds, not one hard-coded pair", ctx do
      key = "r-#{System.unique_integer([:positive])}"
      ignored(ctx, :denial, "tap_out", key, 1)

      assert %{held?: true} = Offers.standing(ctx.agent.id)[key],
             "a denial offer's standing is not read: standing/1 filters to work offers"
    end

    test "two kinds under one subject key count on their own ladders", ctx do
      key = "t-#{System.unique_integer([:positive])}"

      # One ignored notification of a released task: its ladder is two, so it is
      # not held back yet. The tap-out notice sharing the key is ignored once and
      # its ladder is one, so it is. The shorter ladder must not be borrowed by
      # the longer subject, nor the longer by the shorter.
      ignored(ctx, :unblocked, "task", key, 1)

      assert %{ignored: 1, held?: false} = Offers.standing(ctx.agent.id)[key]

      ignored(ctx, :denial, "tap_out", key, 1)

      assert %{held?: true} = Offers.standing(ctx.agent.id)[key],
             "the denial notice's one rung did not hold its own subject back"
    end
  end

  # An offer already settled as ignored, at the attempt the rung implies.
  defp ignored(ctx, kind, type, key, attempt) do
    %Offer{}
    |> Offer.changeset(%{
      account_id: ctx.scope.active_account_id,
      project_id: ctx.scope.active_project_id,
      agent_id: ctx.agent.id,
      working_copy_id: ctx.scope.active_working_copy_id,
      kind: kind,
      subject_type: type,
      subject_key: key,
      attempt: attempt,
      status: :ignored,
      outcome_at: DateTime.add(DateTime.utc_now(), attempt, :second),
      template_version: "test/1"
    })
    |> Repo.insert!()
  end
end
