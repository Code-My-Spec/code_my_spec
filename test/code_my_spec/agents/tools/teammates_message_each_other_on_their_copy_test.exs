defmodule CodeMySpec.Agents.Tools.TeammatesMessageEachOtherOnTheirCopyTest do
  @moduledoc """
  Story 1052 (2026-10-11): coding and QA can message a teammate on their own
  working copy directly; anyone else is reached through a question.

  Before this, coding could not message its QA at all, so main carried every
  "the fix is at commit X" between them.
  """

  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()
    CodeMySpecTest.RecordingAgentTransport.listen(scope)
    %{scope: scope, here: copy(scope), there: copy(scope)}
  end

  defp copy(scope) do
    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        device: CodeMySpec.DevicesFixtures.device_fixture(scope)
      )

    copy.id
  end

  defp agent(scope, role, copy_id) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        status: :running,
        working_copy_id: copy_id,
        working_copy: "/tmp/m-#{System.unique_integer([:positive])}"
      })

    AgentPresence.present(agent)
    agent
  end

  defp send_as(scope, from, to) do
    frame = %Frame{assigns: %{current_scope: scope, agent_id: from.id}}

    reply =
      ToolLibrary.run(
        "message_agent",
        %{agent_id: to.id, message: "fix at abc123"},
        Map.put(frame.assigns, :scope, frame.assigns.current_scope)
      )

    reply
  end

  test "coding and QA carry message_agent" do
    assert "message_agent" in RoleProfile.tools(:coding)
    assert "message_agent" in RoleProfile.tools(:qa)
  end

  test "a coder messages its QA on the same copy", ctx do
    coding = agent(ctx.scope, :coding, ctx.here)
    qa = agent(ctx.scope, :qa, ctx.here)

    reply = send_as(ctx.scope, coding, qa)
    assert match?({:ok, _}, reply), inspect(reply)
  end

  test "a coder cannot message another copy's agent", ctx do
    coding = agent(ctx.scope, :coding, ctx.here)
    other_qa = agent(ctx.scope, :qa, ctx.there)

    assert refused?(send_as(ctx.scope, coding, other_qa))
  end

  test "a coder reaches main through a question, not a message", ctx do
    coding = agent(ctx.scope, :coding, ctx.here)
    main = agent(ctx.scope, :main, ctx.here)

    assert refused?(send_as(ctx.scope, coding, main))
  end

  defp refused?({:error, text}), do: text =~ "only a teammate on your own"
  defp refused?({:ok, _text}), do: false
end
