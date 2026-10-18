defmodule CodeMySpec.Agents.Offers.EveryKindEscalatesOnItsOwnLadderTest do
  @moduledoc """
  Story 1080, criteria 2055-2057: the escalation ladder is data, one per offer
  kind, and a kind's own length is its threshold.

  One @ladders map keyed by `{kind, subject_type}`; every reader takes its rung
  from it. A kind not in the map never escalates, so resume and check-in notices
  are unchanged (1742 now reads from the map rather than from a hard-coded
  `kind: :work` match).

  Two kinds, one ladder each, is what separates this from the special case it
  replaces: a requirement offer still takes three ignored offers to reach its
  own last rung, a denial offer takes one.

  Reaching a kind's own last rung by being ignored sets `held?` (it stops this
  agent being pushed the same work again, criterion 1741) but not `declined?`
  (criterion 2169, product's correction on 3e9a96e9) -- that only an explicit
  decline sets, and only that holds the work back from a pull.
  """

  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Repo
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  describe "the ladder as data (2057)" do
    # A notice's ladder (retry, menu) stops at its detail; one that hands
    # out work ends in held back (story 1080, 2026-10-13).
    test "each kind has its own ladder", _ctx do
      ladders = Offers.ladders()

      for key <- [{:work, "requirement"}, {:unblocked, "task"}, {:denial, "tap_out"}] do
        assert List.last(ladders[key]) == :held_back, "#{inspect(key)}: #{inspect(ladders)}"
      end

      assert ladders[{:retry, "failed_turn"}] == [:detail]
      assert ladders[{:menu, "menu"}] == [:detail]

      assert length(ladders[{:work, "requirement"}]) == 3,
             "requirement work takes three ignored offers (1739-1741)"

      assert ladders[{:unblocked, "task"}] == ladders[{:work, "requirement"}],
             "a released task climbs the work ladder (2173)"

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

    test "a denial offer reaches its one-rung ladder on the first ignore", ctx do
      key = "r-#{System.unique_integer([:positive])}"
      ignored(ctx, :denial, "tap_out", key, 1)

      assert %{ignored: 1, held?: true, declined?: false} = Offers.standing(ctx.agent.id)[key],
             "reaching a ladder's last rung by being ignored stops the push, but is not a decline"
    end

    test "a requirement offer's ignored count climbs toward its three-rung ladder", ctx do
      key = "story:1:component_spec"

      ignored(ctx, :work, "requirement", key, 1)
      assert %{ignored: 1, held?: false} = Offers.standing(ctx.agent.id)[key]

      ignored(ctx, :work, "requirement", key, 2)
      assert %{ignored: 2, held?: false} = Offers.standing(ctx.agent.id)[key]

      ignored(ctx, :work, "requirement", key, 3)

      assert %{ignored: 3, held?: true, declined?: false} = Offers.standing(ctx.agent.id)[key],
             "ignored to the end of its ladder: held back from a push, still not a decline"
    end

    test "an unblocked task offer reaches its three-rung ladder on the third ignore", ctx do
      key = "t-#{System.unique_integer([:positive])}"

      ignored(ctx, :unblocked, "task", key, 1)
      ignored(ctx, :unblocked, "task", key, 2)
      assert %{ignored: 2, held?: false} = Offers.standing(ctx.agent.id)[key]

      ignored(ctx, :unblocked, "task", key, 3)
      assert %{ignored: 3, held?: true, declined?: false} = Offers.standing(ctx.agent.id)[key]
    end

    test "standing/1 reports the laddered kinds, not one hard-coded pair", ctx do
      key = "r-#{System.unique_integer([:positive])}"
      ignored(ctx, :denial, "tap_out", key, 1)

      assert %{ignored: 1} = Offers.standing(ctx.agent.id)[key],
             "a denial offer's standing is not read: standing/1 filters to work offers"
    end

    test "two kinds sharing a subject key combine their ignored count", ctx do
      key = "t-#{System.unique_integer([:positive])}"

      # released_subject/1's own comment: a released task's {"task", id} and
      # a denied tap-out's {"tap_out", blocker_id} are "the same subject the
      # release recorded, so the two supersede each other". standing/1
      # groups purely by subject_key, so their ignored counts are meant to
      # combine into one streak for that one entity, not stay isolated --
      # neither kind's own ignore is a decline, but the combined streak can
      # still reach held? via the shorter kind's own ladder length.
      ignored(ctx, :unblocked, "task", key, 1)
      assert %{ignored: 1, held?: false, declined?: false} = Offers.standing(ctx.agent.id)[key]

      ignored(ctx, :denial, "tap_out", key, 1)

      assert %{ignored: 2, held?: true, declined?: false} = Offers.standing(ctx.agent.id)[key],
             "the combined streak did not reach the tap-out denial's own one-rung ladder"
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
