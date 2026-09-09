defmodule CodeMySpec.Agents.AStepThatSaidNothingIsNotAStepTest do
  @moduledoc """
  A turn event with no text writes no message.

  `Conversations.parts_for("")` answers `[]`, so a textless event became a
  message whose entire content was an empty list. They arrive constantly — a
  single turn produces dozens — and each one was a row, a broadcast, and a line
  in the transcript that renders as the agent having spoken and said nothing.

  The cost was diagnosis, not storage. Measured 2026-09-08: a coding agent
  showed 99 empty messages against 0 substantive ones, and I read that as "the
  model is returning nothing" and spent most of a day inside the provider —
  through a Codex credential rotation, a provider switch, and Alloy's response
  parsing — looking for a fault that was never there. The transcript was
  reporting bookkeeping as speech.

  A turn's actual text is announced by `CmsHarness.Agents.Engine`, which has its
  own clause for a turn that finished with nothing to say. This is the step
  channel, and a step with no text has nothing to tell anybody.
  """
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: false,
        working_copy: "/tmp/empty-step-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    %{scope: scope, agent: agent, conversation: conversation}
  end

  defp messages(conversation) do
    conversation
    |> Conversations.list_messages()
    |> Enum.filter(&(&1.role == :assistant))
  end

  test "an event with empty text writes nothing", ctx do
    Agents.record_turn_event(ctx.scope, ctx.agent.id, %{"kind" => "step", "text" => ""})

    assert messages(ctx.conversation) == []
  end

  test "an event with only whitespace writes nothing", ctx do
    Agents.record_turn_event(ctx.scope, ctx.agent.id, %{"kind" => "step", "text" => "  \n "})

    assert messages(ctx.conversation) == []
  end

  test "an event carrying no text key at all writes nothing", ctx do
    Agents.record_turn_event(ctx.scope, ctx.agent.id, %{"kind" => "step"})

    assert messages(ctx.conversation) == [],
           "an event with no text was inspected into the transcript as if it were prose"
  end

  # The shape that got through the first pass. `is_binary/1` sent it to the
  # catch-all, `parts_for(nil)` answered `[]`, and the empty rows came straight
  # back — 45 on one agent in ten minutes, after the fix that was meant to end
  # them.
  test "an event whose text is nil writes nothing", ctx do
    Agents.record_turn_event(ctx.scope, ctx.agent.id, %{"kind" => "step", "text" => nil})

    assert messages(ctx.conversation) == []
  end

  # The half that must keep working: a step that said something is still a step.
  test "an event with text is written", ctx do
    Agents.record_turn_event(ctx.scope, ctx.agent.id, %{
      "kind" => "step",
      "text" => "Reading world_server.ex"
    })

    assert [message] = messages(ctx.conversation)
    assert message.content != []
  end
end
