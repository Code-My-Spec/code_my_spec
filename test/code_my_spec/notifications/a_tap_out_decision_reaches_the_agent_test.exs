defmodule CodeMySpec.Notifications.ATapOutDecisionReachesTheAgentTest do
  @moduledoc """
  An agent that asks to leave the loop is told what was decided.

  `tap_out` was built on a Claude Code session: it writes its pending request
  into `session.state` and a waiter polls it. An agent we run has no session to
  write into, so the tool refused it outright — and the stop menu offers
  `tap_out` on every refusal inside the loop, so the one escape it names was
  offered to agents that could not take it.

  The session state was never the interesting part. The permission request row
  *is* the pending state; `session.state` was a second copy for a waiter an
  agent does not have. What an agent needs is the decision delivered back.

  Declined is the case that matters. Approved and the loop ends, which the agent
  notices by not being asked to continue. Declined and it must carry on — and an
  agent that asked to leave and heard nothing cannot tell a refusal from a
  decision nobody has made yet.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Notifications
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

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
        continuous: true,
        working_copy: "/tmp/tapout-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    {:ok, conversation} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    %{scope: scope, agent: agent, conversation: conversation}
  end

  defp ask_to_leave(scope, agent) do
    {:ok, request} =
      Notifications.create_permission_request(scope.user.id, %{
        "agent_id" => agent.id,
        "tool_name" => "tap_out",
        "tool_input" => %{"agent_id" => agent.id}
      })

    request
  end

  test "a declined tap-out tells the agent to carry on", ctx do
    request = ask_to_leave(ctx.scope, ctx.agent)

    {:ok, _} = Notifications.resolve_permission_request(request.id, "deny")

    assert_receive {:agent_dispatch, id, _ref, message}
    assert id == ctx.agent.id
    assert message =~ "declined"
    assert message =~ "Keep going"
  end

  test "an approved tap-out says the loop is done", ctx do
    request = ask_to_leave(ctx.scope, ctx.agent)

    {:ok, _} = Notifications.resolve_permission_request(request.id, "allow")

    assert_receive {:agent_dispatch, _id, _ref, message}
    assert message =~ "approved"
    assert message =~ "loop is done"
  end

  # Saying the loop is done is not ending it. Approving a tap-out left
  # `continuous` set, so the next stop woke the agent again — permission to
  # leave, followed immediately by being asked to carry on.
  test "an approved tap-out actually takes it out of the loop", ctx do
    assert ctx.agent.continuous

    request = ask_to_leave(ctx.scope, ctx.agent)
    {:ok, _} = Notifications.resolve_permission_request(request.id, "allow")

    refute CodeMySpec.Repo.get(CodeMySpec.Agents.Agent, ctx.agent.id).continuous
  end

  # A decline must leave it running. An agent told to keep going and then taken
  # out of the loop is the same failure in the other direction.
  test "a declined tap-out leaves the loop on", ctx do
    request = ask_to_leave(ctx.scope, ctx.agent)
    {:ok, _} = Notifications.resolve_permission_request(request.id, "deny")

    assert CodeMySpec.Repo.get(CodeMySpec.Agents.Agent, ctx.agent.id).continuous
  end

  # A Claude Code request is answered on the SSE connection already waiting on
  # it. Delivering here as well would be a message to nobody.
  test "a request with no agent dispatches nothing", ctx do
    {:ok, request} =
      Notifications.create_permission_request(ctx.scope.user.id, %{
        "tool_name" => "bash",
        "tool_input" => %{"command" => "ls"}
      })

    {:ok, _} = Notifications.resolve_permission_request(request.id, "allow")

    refute_receive {:agent_dispatch, _id, _ref, _message}, 100
  end

  # Any other permission, not just tap-out. An agent told "no" about a tool has
  # to hear it, or it retries the thing it was refused.
  test "a decision about another tool reaches the agent too", ctx do
    {:ok, request} =
      Notifications.create_permission_request(ctx.scope.user.id, %{
        "agent_id" => ctx.agent.id,
        "tool_name" => "bash",
        "tool_input" => %{"command" => "rm -rf /"}
      })

    {:ok, _} = Notifications.resolve_permission_request(request.id, "deny")

    assert_receive {:agent_dispatch, _id, _ref, message}
    assert message =~ "bash"
    assert message =~ "declined"
  end
end
