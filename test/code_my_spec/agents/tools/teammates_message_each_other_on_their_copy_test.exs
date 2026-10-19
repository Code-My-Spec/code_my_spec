defmodule CodeMySpec.Agents.Tools.TeammatesMessageEachOtherOnTheirCopyTest do
  @moduledoc """
  Story 1052 (2026-10-11): coding and QA can message a teammate on their own
  working copy directly; anyone else is reached through a question.

  Before this, coding could not message its QA at all, so main carried every
  "the fix is at commit X" between them.

  Issue 0ae29c2a (2026-10-19): main is the one exception to "anyone else" --
  an agent told to report to main had no id for it (main's id changes across
  restarts) and no route to it off its own copy. John's decision: message_agent
  reaches main from any copy, by id or by the role name "main". The copy
  restriction stays for product and for every other copy's coding/QA.
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

  defp send_as(scope, from, to), do: send_to_id(scope, from, to.id)

  defp send_to_id(scope, from, to_id) do
    frame = %Frame{assigns: %{current_scope: scope, agent_id: from.id}}

    ToolLibrary.run(
      "message_agent",
      %{agent_id: to_id, message: "fix at abc123"},
      Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
    )
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

  test "a coder on main's own copy can message main", ctx do
    coding = agent(ctx.scope, :coding, ctx.here)
    main = agent(ctx.scope, :main, ctx.here)

    assert match?({:ok, _}, send_as(ctx.scope, coding, main)), "main is reachable, same copy or not"
  end

  test "a coder on a different copy can still message main", ctx do
    coding = agent(ctx.scope, :coding, ctx.here)
    main = agent(ctx.scope, :main, ctx.there)

    reply = send_as(ctx.scope, coding, main)

    assert match?({:ok, _}, reply), inspect(reply)
  end

  test "a coder can address main by role instead of its id", ctx do
    coding = agent(ctx.scope, :coding, ctx.here)
    _main = agent(ctx.scope, :main, ctx.there)

    {:ok, _copy} = CodeMySpec.WorkingCopies.designate_main(ctx.scope, ctx.there)

    reply = send_to_id(ctx.scope, coding, "main")

    assert match?({:ok, _}, reply), inspect(reply)
  end

  defp refused?({:error, text}), do: text =~ "only a teammate on your own"
  defp refused?({:ok, _text}), do: false
end
