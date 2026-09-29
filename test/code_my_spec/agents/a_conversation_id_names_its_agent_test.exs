defmodule CodeMySpec.Agents.AConversationIdNamesItsAgentTest do
  @moduledoc """
  Issue aeb22e38: the cockpit URL carries `?conversation=<id>`. The main agent
  passed that id to `read_agent_conversation`, got not-found, and told the user
  the agent was in a different project.

  A conversation id in this scope names its agent. One outside it is not found,
  and not-found says so without inventing a project mismatch.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IntegrationsFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.McpServers.Agents.Tools.MessageAgent
  alias CodeMySpec.McpServers.Agents.Tools.TurnOffAgent
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpec.Repo
  alias CodeMySpecTest.RecordingAgentTransport

  @plain_not_found "No agent or conversation with that id exists here"
  @project_mismatch ~r/(another|different|other) project/i

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

    {scope, agent, conversation} = agent_with_conversation("the coding agent's own words")

    %{
      scope: scope,
      agent: agent,
      conversation: conversation,
      frame: %Frame{assigns: %{current_scope: scope}}
    }
  end

  defp agent_with_conversation(said) do
    scope = full_scope_fixture()
    integration_fixture(scope.user, %{provider: :anthropic})

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
        status: :running,
        continuous: false,
        working_copy: "/tmp/conv-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    {:ok, _} = Conversations.add_agent_message(conversation, "coding", "assistant", said)

    {scope, agent, conversation}
  end

  defp text(response) do
    response |> Response.to_protocol() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")
  end

  test "read_agent_conversation given a conversation id reads that agent's conversation", ctx do
    {:reply, response, _} =
      ReadAgentConversation.execute(%{agent_id: ctx.conversation.id}, ctx.frame)

    refute response.isError, text(response)
    assert text(response) =~ "the coding agent's own words"
  end

  test "turn_off_agent given a conversation id turns off its agent", ctx do
    {:reply, response, _} = TurnOffAgent.execute(%{agent_id: ctx.conversation.id}, ctx.frame)

    refute response.isError, text(response)
    assert Agent.off?(Repo.get(Agent, ctx.agent.id))
  end

  test "message_agent given a conversation id reaches its agent", ctx do
    agent_id = ctx.agent.id

    {:reply, response, _} =
      MessageAgent.execute(%{agent_id: ctx.conversation.id, message: "carry on"}, ctx.frame)

    refute response.isError, text(response)
    assert_received {:agent_message, ^agent_id, "carry on"}
  end

  test "a conversation from another account is not found", ctx do
    {_other_scope, other_agent, other_conversation} = agent_with_conversation("not yours")

    {:reply, read, _} =
      ReadAgentConversation.execute(%{agent_id: other_conversation.id}, ctx.frame)

    assert read.isError
    refute text(read) =~ "not yours"

    {:reply, off, _} = TurnOffAgent.execute(%{agent_id: other_conversation.id}, ctx.frame)

    assert off.isError
    refute Agent.off?(Repo.get(Agent, other_agent.id))
  end

  test "not-found says plainly that nothing has that id, not that it is elsewhere", ctx do
    missing = Ecto.UUID.generate()

    {:reply, read, _} = ReadAgentConversation.execute(%{agent_id: missing}, ctx.frame)
    {:reply, off, _} = TurnOffAgent.execute(%{agent_id: missing}, ctx.frame)

    for response <- [read, off] do
      assert response.isError
      assert text(response) =~ @plain_not_found
      refute text(response) =~ @project_mismatch
    end
  end
end
