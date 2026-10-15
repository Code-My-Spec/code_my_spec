defmodule CodeMySpec.Agents.AnUndeliveredInstructionReachesMainTest do
  @moduledoc """
  43cdc022: an operator instruction whose delivery fails settles its offer
  `:undelivered`, the same way a decline settles `:declined` -- but only the
  decline was ever named to main. An agent that never saw the instruction and
  one that saw and ignored it read the same from main's side, and the
  operator was left repeating an instruction a dropped delivery, not a
  refusal, had already answered.

  Story 1080's rule 31a6413f already promises an offer that was never
  delivered settles as `undelivered`, never as `ignored` -- that half of the
  escalation here (`CodeMySpec.Agents.Offers.undelivered/1`, exercised at the
  turn end that settles the offer, same as the sibling held-back test drives
  it) is untouched. The gap this closes is naming it to main at all.
  """

  use CodeMySpecSpex.Case, async: true

  alias CmsHarness.Project.ChannelClient
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.OfferMessage
  alias CodeMySpec.Conversations
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
        working_copy: "/tmp/undelivered-instruction-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    _main = Fixtures.running_agent(ctx.scope, role: "main", continuous: true)

    Map.put(ctx, :coder, coder)
  end

  test "an instruction offer that settles undelivered is named to main", ctx do
    id = ctx.coder.id
    text = "Operator: you're back on. Two-line replies. #{System.unique_integer([:positive])}"

    offer = undelivered_instruction_offer(ctx, text)

    :ok = end_turn(ctx, id)

    offer = Repo.get!(Offer, offer.id)
    assert offer.status == :undelivered, "the fixture did not settle the way production does"

    sent = Fixtures.messages_to_agent(ctx.scope, main_id(ctx))

    escalation =
      Enum.find(sent, &(&1 =~ "instruction to the coding agent #{id} was never delivered"))

    assert escalation,
           "main was never told the instruction's delivery failed:\n#{Enum.join(sent, "\n---\n")}"

    assert escalation =~ text, "the escalation does not carry the instruction's own text"
  end

  test "an undelivered instruction already named to main is not named twice", ctx do
    id = ctx.coder.id
    _offer = undelivered_instruction_offer(ctx, "first attempt")

    :ok = end_turn(ctx, id)
    first_count = length(Fixtures.messages_to_agent(ctx.scope, main_id(ctx)))

    :ok = end_turn(ctx, id)

    assert length(Fixtures.messages_to_agent(ctx.scope, main_id(ctx))) == first_count,
           "an already-reported undelivered instruction was escalated again"
  end

  defp undelivered_instruction_offer(ctx, text) do
    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        ctx.coder.id
      )

    {:ok, message} =
      Conversations.add_message(conversation, :operator, text, "operator", [],
        delivery: :failed,
        broadcast: false
      )

    offer =
      %Offer{}
      |> Offer.changeset(%{
        account_id: ctx.scope.active_account_id,
        project_id: ctx.scope.active_project_id,
        agent_id: ctx.coder.id,
        working_copy_id: ctx.scope.active_working_copy_id,
        kind: :instruction,
        subject_type: "message",
        subject_key: "test-#{System.unique_integer([:positive])}",
        attempt: 1,
        status: :open,
        inserted_at: DateTime.add(DateTime.utc_now(), -60, :second),
        template_version: "instruction/1"
      })
      |> Repo.insert!()

    %OfferMessage{}
    |> OfferMessage.changeset(%{offer_id: offer.id, message_id: message.id})
    |> Repo.insert!()

    offer
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
