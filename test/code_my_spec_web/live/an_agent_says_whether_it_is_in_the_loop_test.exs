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

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        context.scope.active_account_id,
        context.scope.active_project_id,
        agent.id
      )

    {agent, conversation}
  end

  defp loop_badge(continuous?), do: "[data-test='agent-loop'][data-continuous='#{continuous?}']"

  describe "the conversation page" do
    test "the header says an agent is not continuous, and flips when put to work", context do
      {_agent, conversation} = agent(context, "coding", false)

      {:ok, view, _html} =
        live(
          context.conn,
          "/app/projects/#{context.scope.active_project_id}/agent-conversation" <>
            "?conversation=#{conversation.id}"
        )

      assert has_element?(view, "header " <> loop_badge(false), "Not continuous"),
             "the header does not say this agent is out of the loop"

      view |> element("[data-test='toggle-agent-working']") |> render_click()

      assert has_element?(view, "header " <> loop_badge(true), "Continuous")
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

      assert has_element?(view, "[data-test='team-agent']" <> " " <> loop_badge(false)),
             "the team panel does not say which agent is out of the loop"

      assert has_element?(
               view,
               "[data-test='team-agent'][data-agent-id='#{idle.id}'] " <> loop_badge(false)
             )

      assert has_element?(
               view,
               "[data-test='team-agent'][data-agent-id='#{working.id}'] " <> loop_badge(true)
             )
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
