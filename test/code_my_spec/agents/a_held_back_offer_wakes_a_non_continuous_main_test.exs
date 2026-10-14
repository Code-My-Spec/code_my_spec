defmodule CodeMySpec.Agents.AHeldBackOfferWakesANonContinuousMainTest do
  @moduledoc """
  Story 1080, criterion 2063: an offer held back from an agent reaches main the
  moment it settles, even when main is not continuous.

  The notice used to be sent as `:teammate_stalled`, which `Wake`'s
  `@not_continuous` table *holds* -- so a non-continuous main had it recorded
  undelivered and never heard it. A held-back or refused offer is main's own
  administrative notice, like `:team_free` and `:own_reply`: relevant to main
  whatever its role, and waking it rather than being held.

  Both ways an offer reaches the end of its ladder are here: ignored to the end
  (offered its ladder's length and not taken) and refused outright.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.{DevicesFixtures, UsersFixtures}

  alias CmsHarness.Project.ChannelClient
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Wake
  alias CodeMySpec.Conversations
  alias CodeMySpec.Repo
  alias CodeMySpec.Staffing
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport
  alias Ecto.Adapters.SQL.Sandbox

  @task "task-#{System.unique_integer([:positive])}"

  setup do
    Sandbox.mode(Repo, {:shared, self()})

    scope = full_scope_fixture()
    RecordingAgentTransport.listen(scope)
    {:ok, _} = Staffing.designate_main(scope, scope.active_working_copy_id)

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    {:ok, coder} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: false,
        status: :running,
        working_copy: "/tmp/held-back-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    AgentPresence.present(coder)

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        coder.id
      )

    # Main is not continuous: the whole point of 2063 is that its notice still
    # arrives, rather than being recorded undelivered.
    {:ok, main} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "main",
        continuous: false,
        status: :running,
        working_copy: "/tmp/main-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    AgentPresence.present(main)

    %{scope: scope, coder: coder, main: main, conversation: conversation}
  end

  defp offer(ctx, kind, subject), do: %Offer{} = Offers.record(nil, ctx.coder, kind, subject)

  defp end_turn(ctx) do
    {:ok, agent} = AgentsRepository.fetch_agent(ctx.scope, ctx.coder.id)

    {:ok, _} =
      AgentsRepository.update_agent(ctx.scope, agent, %{
        turn_started_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

    Agents.record_turn_event(
      ctx.scope,
      ctx.coder.id,
      ChannelClient.encode_turn_event(
        CodeMySpecSpex.Fixtures.mailbox_turn_end(ctx.scope, ctx.coder.id)
      )
    )
  end

  defp told(%Agent{id: id}) do
    assert_receive {:agent_dispatch, ^id, ref, text}, 3_000
    assert is_binary(ref)
    text
  end

  describe "the event a held-back offer is announced with (2063)" do
    test "a non-continuous main is woken by it, where :teammate_stalled is held", ctx do
      assert {:hold, :not_continuous} = Wake.decide(ctx.scope, ctx.main, :teammate_stalled)

      assert :wake == Wake.decide(ctx.scope, ctx.main, :offer_held_back),
             "a held-back offer must wake a non-continuous main, as :team_free does"
    end
  end

  describe "an offer refused outright (2063)" do
    test "a non-continuous main receives it as a delivered message, at the refusal", ctx do
      offer = offer(ctx, :unblocked, {"task", @task})

      assert {:ok, declined} = Agents.reject_offer(ctx.scope, ctx.coder.id, offer.id, "not mine")
      assert declined.next_step == "held_back"

      # Told at the refusal, not at the turn end that follows it: main should
      # not have to wait out a turn to hear a decision the agent just made.
      text = told(ctx.main)
      assert text =~ ctx.coder.id
      assert text =~ @task
      assert text =~ "not mine"

      # And once: the turn-end escalation reads the terminal rung, and this
      # refusal has already been reported (criterion 2056, 1738).
      end_turn(ctx)
      refute_receive {:agent_dispatch, _, _, _}, 300, "main was told about the refusal twice"
    end
  end

  describe "an offer ignored to the end of its ladder (2063)" do
    test "a non-continuous main receives one notice naming how many times", ctx do
      # A released task's ladder is [:remind, :held_back]: its own two rungs, not
      # requirement work's three.
      ladder = Offers.ladder({:unblocked, "task"})
      assert ladder == [:remind, :held_back]

      last =
        Enum.reduce(1..length(ladder), nil, fn _, _ ->
          offered = offer(ctx, :unblocked, {"task", @task})
          end_turn(ctx)
          Repo.get!(Offer, offered.id)
        end)

      assert last.next_step == "held_back"

      text = told(ctx.main)
      assert text =~ ctx.coder.id
      assert text =~ @task
      assert text =~ "offered #{length(ladder)} times and not taken"

      refute_receive {:agent_dispatch, _, _, _},
                     300,
                     "one escalation only: a later turn repeats nothing"
    end
  end
end
