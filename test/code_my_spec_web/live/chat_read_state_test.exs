defmodule CodeMySpecWeb.ChatReadStateTest do
  @moduledoc """
  Every chat list shows read/unread per user, opening a chat reads it, and a
  per-chat toggle flips it.
  """
  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpecSpex.WorkingCopyHelpers
  import Phoenix.LiveViewTest

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Reads
  alias CodeMySpecTest.AgentPresence
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  defp unread?(scope, conversation),
    do: scope |> Reads.states([conversation.id]) |> Reads.unread?(conversation.id)

  defp support_chat(scope) do
    {:ok, conversation} =
      Conversations.find_or_create_conversation(
        scope.active_account_id,
        scope.active_project_id,
        "enduser@example.com"
      )

    {:ok, _} = Conversations.add_message(conversation, :user, "hello?")
    conversation
  end

  defp agent(context, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(context.scope, %{
        engine: :alloy,
        provider: "anthropic",
        working_copy: "/tmp/read-state",
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

  defp cockpit(context, conversation) do
    {:ok, view, _html} =
      live(
        context.conn,
        "/app/projects/#{context.scope.active_project_id}/agent-conversation" <>
          "?conversation=#{conversation.id}"
      )

    render_hook(view, "viewport", %{"width" => 1200})
    render_hook(view, "toggle_panel", %{"panel" => "activity"})
    view
  end

  describe "support inbox" do
    test "an unseen chat is marked unread and the toggle flips it", %{conn: conn, scope: scope} do
      conversation = support_chat(scope)
      row = "[data-test='conversation'][phx-value-id='#{conversation.id}']"

      {:ok, view, _html} = live(conn, "/app/projects/#{scope.active_project_id}/inbox")

      assert has_element?(view, "#{row}[data-unread='true'] [data-test='unread-dot']")

      view |> element("#{row} [data-test='toggle-read']") |> render_click()
      assert has_element?(view, "#{row}[data-unread='false']")
      refute unread?(scope, conversation)

      view |> element("#{row} [data-test='toggle-read']") |> render_click()
      assert has_element?(view, "#{row}[data-unread='true']")
      assert unread?(scope, conversation)
    end

    test "opening a chat marks it read", %{conn: conn, scope: scope} do
      conversation = support_chat(scope)
      assert unread?(scope, conversation)

      {:ok, _view, _html} =
        live(conn, "/app/projects/#{scope.active_project_id}/inbox/#{conversation.id}")

      refute unread?(scope, conversation)
    end
  end

  describe "agent sessions" do
    test "the list shows unread and the toggle flips it", %{conn: conn, scope: scope} do
      {:ok, conversation} =
        Conversations.find_or_create_session_conversation(
          scope.active_account_id,
          scope.active_project_id,
          "pi:/tmp/read-state"
        )

      {:ok, _} = Conversations.add_agent_message(conversation, nil, "assistant", "a turn")
      row = "[data-test='agent-conversation'][data-conversation-id='#{conversation.id}']"

      {:ok, view, _html} =
        live(conn, "/app/projects/#{scope.active_project_id}/agent-conversations")

      assert has_element?(view, "#{row}[data-unread='true'] [data-test='unread-dot']")

      view |> element("#{row} [data-test='toggle-read']") |> render_click()
      assert has_element?(view, "#{row}[data-unread='false']")

      view |> element("#{row} [data-test='toggle-read']") |> render_click()
      assert has_element?(view, "#{row}[data-unread='true']")
    end
  end

  describe "cockpit activity panel" do
    setup context do
      copy = join_working_copy(context, "/tmp/read-state", "a copy")
      Map.put(context, :copy, copy)
    end

    test "unread marks, live arrival, and opening", context do
      {_open_agent, open_chat} = agent(context, "coding")
      {other, other_chat} = agent(context, "qa")
      {:ok, _} = Conversations.add_agent_message(open_chat, nil, "assistant", "on screen")

      view = cockpit(context, open_chat)
      row = "[data-test='team-agent'][data-agent-id='#{other.id}']"

      refute unread?(context.scope, open_chat), "the chat on screen is being read"
      assert has_element?(view, "#{row} a[data-unread='false']")

      {:ok, _} = Conversations.add_agent_message(other_chat, nil, "assistant", "elsewhere")
      assert has_element?(view, "#{row} a[data-unread='true'] [data-test='unread-dot']")

      view |> element("#{row} a[data-unread]") |> render_click()
      assert has_element?(view, "#{row} a[data-unread='false']")
      refute unread?(context.scope, other_chat)

      {:ok, _} = Conversations.add_agent_message(other_chat, nil, "assistant", "while open")
      _ = render(view)
      refute unread?(context.scope, other_chat), "a message arriving on screen is seen"
    end
  end
end
