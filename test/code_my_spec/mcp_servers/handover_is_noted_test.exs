defmodule CodeMySpec.McpServers.HandoverIsNotedTest do
  @moduledoc """
  Giving an agent work, and finishing work for it, land on its thread.

  Story 985's other two kinds. The stop decision was cracked by driving
  `Stop.decide/2` directly rather than through a spex, and this is the same move
  for the same reason: a spex that records nothing tells you the transcript is
  empty and not which of four things did not happen.
  """

  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.ConnTest

  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Conversation
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    scope = full_scope_fixture()
    integration_fixture(scope.user, %{provider: :anthropic})

    {:ok, copy} = CodeMySpec.WorkingCopies.fetch(scope.active_working_copy_id)
    root = CodeMySpec.TempFile.dir("handover")
    File.mkdir_p!(root)

    copy |> Ecto.Changeset.change(root: root, main: true) |> CodeMySpec.Repo.update!()
    scope = %{scope | cwd: root}

    {:ok, agent} =
      Agents.start_agent(scope, %{
        provider: "anthropic",
        role: "coding",
        engine: :alloy,
        working_copy: root
      })

    # `start_task` needs a session on this server. The same hook the harness
    # fires, so the session is a real one rather than a row shaped like one.
    session_id = "handover-#{System.unique_integer([:positive])}"

    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("x-harness-id", scope.active_working_copy_id)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/api/hooks/session-start", %{
      "session_id" => session_id
    })

    %{scope: scope, agent: agent, session_id: session_id}
  end

  defp actions(agent) do
    case CodeMySpec.Repo.get_by(Conversation, agent_id: agent.id) do
      nil ->
        []

      conversation ->
        conversation |> Conversations.list_messages() |> Enum.filter(&(&1.role == :orchestrator))
    end
  end

  defp text(message) do
    Enum.find_value(message.content, fn
      %{"type" => "text", "text" => t} -> t
      _ -> nil
    end)
  end

  test "the main agent is found from a scope built like the tool's", %{
    scope: scope,
    agent: agent
  } do
    # The premise every one of these rests on, asserted rather than assumed —
    # this is the thing that was nil in the spex for three rounds, and it fails
    # silently by design because an orchestrator acting on an unwatched agent is
    # not an error.
    assert %{id: found} = Agents.main_agent(scope)
    assert found == agent.id
  end

  test "starting a task on a requirement is recorded as a hand-over", %{
    scope: scope,
    agent: agent,
    session_id: session_id
  } do
    frame = %Frame{assigns: %{current_scope: scope}}

    {:reply, response, _frame} =
      StartTask.execute(
        %{
          requirement_name: "stories_exist",
          entity_type: "project",
          entity_id: scope.active_project_id,
          session_id: session_id
        },
        frame
      )

    refute response.isError, "start_task refused: #{inspect(response)}"

    assert [action] = actions(agent),
           "a requirement was handed over and the conversation says nothing. The agent " <>
             "picking up new work is the visible half; what gave it that work is the " <>
             "half a reader needs."

    assert text(action) =~ "stories_exist"
  end
end
