defmodule CodeMySpec.Agents.HeldBackFromAnAgentReachesMainTest do
  @moduledoc """
  Story 1080, criterion 2056: an offer held back from an agent reaches main as
  one escalation naming the agent, what it would not take, and its reason.

  Main reassigns, cancels or answers it; "held back" is not the end of the
  offer, only of offering it to that one agent. The count named is the kind's
  own ladder length (2057), not requirement work's three.

  The escalation is written where a held-back rung is written: at the turn end
  that settles the offer (`Agents.record_turn_event/4`), so the tests drive
  that rather than reaching into the private notify.
  """

  use CodeMySpecSpex.Case, async: true

  alias CmsHarness.Project.ChannelClient
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    :ok = Fixtures.install_recording_agent_transport(ctx)

    {:ok, _} = WorkingCopies.designate_main(ctx.scope, ctx.scope.active_working_copy_id)

    {:ok, coder} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/held-back-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    _main = Fixtures.running_agent(ctx.scope, role: "main", continuous: true)

    Map.put(ctx, :coder, coder)
  end

  test "an offer ignored to the end of its ladder is escalated once, naming it", ctx do
    id = ctx.coder.id
    key = "t-#{System.unique_integer([:positive])}"
    ladder = length(Offers.ladders()[{:unblocked, "task"}])

    # An offer reaches `held_back` by being ignored to the end of its ladder,
    # so the earlier rungs are settled ignored offers and the last one is the
    # offer this turn ignores -- written here as the open offer the turn end
    # will settle, so `next_step` is the production path's, not the test's.
    for attempt <- 1..(ladder - 1) do
      %Offer{}
      |> Offer.changeset(%{
        account_id: ctx.scope.active_account_id,
        project_id: ctx.scope.active_project_id,
        agent_id: id,
        working_copy_id: ctx.scope.active_working_copy_id,
        kind: :unblocked,
        subject_type: "task",
        subject_key: key,
        attempt: attempt,
        status: :ignored,
        inserted_at: DateTime.add(DateTime.utc_now(), -60, :second),
        template_version: "test/1"
      })
      |> Repo.insert!()
    end

    offer = settled(ctx, :unblocked, "task", key, ladder, :open)

    :ok = end_turn(ctx, id)

    offer = Repo.get!(Offer, offer.id)

    assert %{held?: true} = Offers.standing(id)[key]

    sent = Fixtures.messages_to_agent(ctx.scope, main_id(ctx))

    escalation = Enum.find(sent, &(&1 =~ "Held back from the coding agent #{id}"))

    assert escalation,
           "main was never told the offer was held back:\n#{Enum.join(sent, "\n---\n")}"

    assert escalation =~ key, "the escalation does not name what the agent would not take"
    assert escalation =~ "offered #{ladder} times", "wrong count for this kind: #{escalation}"
    assert offer.next_step == "held_back"
  end

  test "a refused offer reaches main at the refusal, naming the reason", ctx do
    id = ctx.coder.id
    key = "story:1:component_spec"
    offer = settled(ctx, :work, "requirement", key, 1, :open)

    assert {:ok, _} = Agents.reject_offer(ctx.scope, id, offer.id, "not mine to do")

    # `notify_main/4` delivers from a supervised task, so the message is
    # written before this read only once that task has run.
    :ok = Fixtures.drain_background_work()

    sent = Fixtures.messages_to_agent(ctx.scope, main_id(ctx))
    escalation = Enum.find(sent, &(&1 =~ "Offer declined by agent #{id}"))

    assert escalation, "main was never told:\n#{Enum.join(sent, "\n---\n")}"
    assert escalation =~ "not mine to do", "the refusal reason is missing: #{escalation}"

    # The turn end has nothing left to say: the refusal was reported above, so
    # the escalation does not say it a second time (criteria 1738, 2056).
    :ok = end_turn(ctx, id)
    :ok = Fixtures.drain_background_work()

    assert Fixtures.messages_to_agent(ctx.scope, main_id(ctx)) == sent,
           "main heard about the refusal twice"
  end

  defp settled(ctx, kind, type, key, attempt, status) do
    %Offer{}
    |> Offer.changeset(%{
      account_id: ctx.scope.active_account_id,
      project_id: ctx.scope.active_project_id,
      agent_id: ctx.coder.id,
      working_copy_id: ctx.scope.active_working_copy_id,
      kind: kind,
      subject_type: type,
      subject_key: key,
      attempt: attempt,
      status: status,
      inserted_at: DateTime.add(DateTime.utc_now(), -60, :second),
      template_version: "test/1"
    })
    |> Repo.insert!()
  end

  defp end_turn(ctx, agent_id) do
    start = DateTime.add(DateTime.utc_now(), -30, :second)

    {:ok, _} =
      AgentsRepository.update_agent(ctx.scope, Repo.get!(Agent, agent_id), %{
        turn_started_at: start
      })

    Agents.record_turn_event(
      ctx.scope,
      agent_id,
      ChannelClient.encode_turn_event(
        CodeMySpecSpex.Fixtures.mailbox_turn_end(ctx.scope, agent_id)
      )
    )
  end

  defp main_id(ctx) do
    Agents.main_agent(ctx.scope).id
  end
end
