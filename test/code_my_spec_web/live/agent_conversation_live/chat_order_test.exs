defmodule CodeMySpecWeb.AgentConversationLive.ChatOrderTest do
  @moduledoc """
  The cockpit's activity panel lists each copy's agents by their chat's latest
  message, newest on top.
  """
  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpecSpex.WorkingCopyHelpers
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Repo
  alias CodeMySpecTest.AgentPresence
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    copy = join_working_copy(context, "/tmp/chat-order", "a copy")
    Map.put(context, :copy, copy)
  end

  defp agent(context, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(context.scope, %{
        engine: :alloy,
        provider: "anthropic",
        working_copy: "/tmp/chat-order",
        role: role,
        continuous: false,
        status: :running,
        working_copy_id: context.copy.working_copy_id
      })

    AgentPresence.present(agent)

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        context.scope.active_account_id,
        context.scope.active_project_id,
        agent.id
      )

    {agent, conversation}
  end

  defp said(conversation, seconds_ago) do
    {:ok, %Message{id: id}} =
      Conversations.add_agent_message(conversation, nil, "assistant", "a turn")

    time = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
    Repo.update_all(from(m in Message, where: m.id == ^id), set: [inserted_at: time])
  end

  defp panel_agent_ids(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("[data-test='team-agent']")
    |> Enum.flat_map(&Floki.attribute(&1, "data-agent-id"))
  end

  test "agents are ordered by their chat's latest message", context do
    # Role order would be coding, product, qa; message order says otherwise.
    {coding, coding_chat} = agent(context, "coding")
    {qa, qa_chat} = agent(context, "qa")
    {product, product_chat} = agent(context, "product")

    said(coding_chat, 3600)
    said(qa_chat, 10)
    said(product_chat, 600)

    {:ok, view, _html} =
      live(
        context.conn,
        "/app/projects/#{context.scope.active_project_id}/agent-conversation" <>
          "?conversation=#{coding_chat.id}"
      )

    render_hook(view, "viewport", %{"width" => 1200})
    render_hook(view, "toggle_panel", %{"panel" => "activity"})

    ours = [qa.id, product.id, coding.id]
    assert Enum.filter(panel_agent_ids(view), &(&1 in ours)) == ours
  end
end
