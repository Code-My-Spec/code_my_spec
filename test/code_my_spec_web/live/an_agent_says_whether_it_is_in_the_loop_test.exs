defmodule CodeMySpecWeb.AnAgentSaysWhetherItIsInTheLoopTest do
  @moduledoc """
  Every place a person looks at an agent says whether it is continuous.

  723b929d: metric_flow's main agent sat idle over a ready deploy because its
  continuous flag was off, and graph wakes admit only continuous agents. The
  play/pause icon says what a click would do, not which state the agent is in,
  so nothing on screen showed why it would never be woken.
  """
  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpecSpex.WorkingCopyHelpers
  import Phoenix.LiveViewTest

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpecTest.AgentPresence
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    copy = join_working_copy(context, "/tmp/in-the-loop", "a copy")
    Map.put(context, :copy, copy)
  end

  defp agent(context, role, continuous?) do
    {:ok, agent} =
      AgentsRepository.create_agent(context.scope, %{
        engine: :alloy,
        provider: "anthropic",
        working_copy: "/tmp/in-the-loop",
        role: role,
        continuous: continuous?,
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

  defp loop_badge(continuous?), do: "[data-test='agent-loop'][data-continuous='#{continuous?}']"

  defp play_pause(continuous?),
    do: "[data-test='team-agent-working'][data-working='#{continuous?}']"

  describe "the conversation page" do
    # f096eba2: the header dropped the word ("Continuous"/"Not continuous")
    # and kept only the play/pause icon — the badge moved to the team panel,
    # tested below, which stays visible without needing this one agent's
    # conversation open.
    test "the header's play/pause icon reflects state via data-working, with no loop badge",
         context do
      {_agent, conversation} = agent(context, "coding", false)

      {:ok, view, _html} =
        live(
          context.conn,
          "/app/projects/#{context.scope.active_project_id}/agent-conversation" <>
            "?conversation=#{conversation.id}"
        )

      refute has_element?(view, "header [data-test='agent-loop']"),
             "the header should not render the loop badge/text anymore"

      assert has_element?(
               view,
               "header [data-test='toggle-agent-working'][data-working='false']"
             )

      view |> element("[data-test='toggle-agent-working']") |> render_click()

      assert has_element?(
               view,
               "header [data-test='toggle-agent-working'][data-working='true']"
             )
    end

    test "the team panel marks each agent", context do
      {idle, conversation} = agent(context, "coding", false)
      {working, _} = agent(context, "qa", true)

      {:ok, view, _html} =
        live(
          context.conn,
          "/app/projects/#{context.scope.active_project_id}/agent-conversation" <>
            "?conversation=#{conversation.id}"
        )

      render_hook(view, "viewport", %{"width" => 1200})
      render_hook(view, "toggle_panel", %{"panel" => "activity"})

      assert has_element?(
               view,
               "[data-test='team-agent'][data-agent-id='#{idle.id}'] " <> play_pause(false)
             )

      assert has_element?(
               view,
               "[data-test='team-agent'][data-agent-id='#{working.id}'] " <> play_pause(true)
             )
    end

    # f096eba2: a panel row controls *that* agent, not whichever conversation
    # the header happens to have open.
    test "a panel row's play/pause toggles that agent, not the open conversation's", context do
      {open_agent, open_conversation} = agent(context, "coding", false)
      {other_agent, _other_conversation} = agent(context, "qa", false)

      {:ok, view, _html} =
        live(
          context.conn,
          "/app/projects/#{context.scope.active_project_id}/agent-conversation" <>
            "?conversation=#{open_conversation.id}"
        )

      render_hook(view, "viewport", %{"width" => 1200})
      render_hook(view, "toggle_panel", %{"panel" => "activity"})

      view
      |> element(
        "[data-test='team-agent'][data-agent-id='#{other_agent.id}'] [data-test='team-agent-working']"
      )
      |> render_click()

      assert has_element?(
               view,
               "[data-test='team-agent'][data-agent-id='#{other_agent.id}'] " <> play_pause(true)
             ),
             "the clicked row's own agent should now be continuous"

      assert has_element?(
               view,
               "[data-test='team-agent'][data-agent-id='#{open_agent.id}'] " <> play_pause(false)
             ),
             "the open conversation's agent should be unaffected by a different row's click"

      assert has_element?(
               view,
               "header [data-test='toggle-agent-working'][data-working='false']"
             ),
             "the header still reflects the open conversation's own agent, not the one just toggled"
    end
  end

  test "the working copy's agent list marks each agent", context do
    {idle, _} = agent(context, "coding", false)
    {working, _} = agent(context, "qa", true)

    {:ok, view, _html} =
      live(
        context.conn,
        "/app/projects/#{context.scope.active_project_id}/working-copies/" <>
          context.copy.working_copy_id
      )

    assert has_element?(
             view,
             "[data-test='agent'][data-agent-id='#{idle.id}'] " <> loop_badge(false),
             "Not continuous"
           ),
           "the copy's agent list does not say which agent the graph will not wake"

    assert has_element?(
             view,
             "[data-test='agent'][data-agent-id='#{working.id}'] " <> loop_badge(true),
             "Continuous"
           )
  end
end
