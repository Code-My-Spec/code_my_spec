defmodule CodeMySpec.Agents.ADeniedTapOutIsNeverRecordedAsAnOfferTest do
  @moduledoc """
  a1c5e9a7 (criterion 2178). A denied tap-out reaches the agent as a notice. When
  the agent could not take a turn for it, the notice used to be recorded as an
  offer of kind `:denial`, so whether one existed depended on whether the agent's
  open work offer had settled by then (about one run in three). It is delivered
  to the agent's thread and nothing is recorded; the work offer is what asks it
  to act.
  """
  use CodeMySpecSpex.Case, async: false

  import Ecto.Query

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Events
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Repo
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    RecordingAgentTransport.listen(ctx)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/denied-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    {:ok, _conversation} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        agent.id
      )

    # Mid-turn: it cannot take a turn for the notice.
    :ok =
      CodeMySpec.Agents.record_turn_event(ctx.scope, agent.id, %{"kind" => "turn_started"})

    %{agent: Repo.get!(Agent, agent.id)}
  end

  test "an agent that cannot take a turn for the denial has it on its thread, not as an offer",
       ctx do
    meta = %{
      scope: ctx.scope,
      agent: ctx.agent,
      notice: "Your request to leave the loop was declined.",
      subject: {"tap_out", Ecto.UUID.generate()},
      working_copy_id: ctx.scope.active_working_copy_id
    }

    :ok = Events.handle_event([:code_my_spec, :notifications, :tap_out_denied], %{}, meta, nil)

    denials =
      Repo.all(from(o in Offer, where: o.agent_id == ^ctx.agent.id and o.kind == :denial))

    assert denials == [], "a denied tap-out was recorded as an offer: #{inspect(denials)}"
  end
end
