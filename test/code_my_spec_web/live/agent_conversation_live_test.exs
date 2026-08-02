defmodule CodeMySpecWeb.AgentConversationLiveTest do
  @moduledoc """
  `AgentConversationLive` is the read-only, per-project window onto a
  background sprite's agent conversation: it renders whatever
  `CodeMySpec.Conversations` already knows about a project's agent session and
  streams new turns in live. It never composes a reply.
  """

  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CodeMySpec.Conversations

  setup [:register_log_in_setup_account]

  defp setup_project(%{scope: scope, account: account} = context) do
    project =
      CodeMySpec.ProjectsFixtures.project_fixture(scope,
        account_id: account.id,
        name: "sprite-project"
      )

    Map.put(context, :project, project)
  end

  setup :setup_project

  defp path(project), do: "/app/projects/#{project.name}/agent-conversation"

  defp agent_conversation(scope, project, external_id \\ "pi:/tmp/sprite-test") do
    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        project.id,
        external_id
      )

    conversation
  end

  describe "before any turn has been recorded" do
    test "shows an empty state", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, path(project))

      assert html =~ "No agent activity recorded"
    end
  end

  describe "rendering recorded turns" do
    test "shows the request and the response with their roles", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)
      {:ok, _} = Conversations.add_message(conversation, :user, "count the open problems")

      {:ok, _} =
        Conversations.add_agent_message(
          conversation,
          nil,
          "assistant",
          "there are 3 open problems"
        )

      {:ok, view, html} = live(conn, path(project))

      assert html =~ "count the open problems"
      assert has_element?(view, "[data-test='message'][data-role='user']")
      assert has_element?(view, "[data-test='message'][data-role='assistant']")
    end

    test "a tool call renders distinctly and is never blank", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)
      # A turn made entirely of tool calls records an empty assistant line
      # alongside the tool call — the empty line must not render as anything.
      {:ok, _} = Conversations.add_agent_message(conversation, nil, "assistant", "")
      {:ok, _} = Conversations.add_agent_message(conversation, nil, "tool", "Bash(mix spex)")

      {:ok, view, html} = live(conn, path(project))

      assert html =~ "Bash(mix spex)"
      assert has_element?(view, "[data-test='tool-call']")
      refute has_element?(view, "[data-test='empty-turn']")
    end

    test "a sub-agent's turn carries its agent role; the main agent's does not", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)

      {:ok, _} =
        Conversations.add_agent_message(conversation, nil, "assistant", "delegating the QA pass")

      {:ok, _} =
        Conversations.add_agent_message(
          conversation,
          "qa",
          "assistant",
          "walked the signup journey"
        )

      {:ok, view, _html} = live(conn, path(project))

      assert has_element?(view, "[data-test='message'][data-agent-role='qa']")
      assert has_element?(view, "[data-test='message']:not([data-agent-role='qa'])")
    end
  end

  describe "live updates" do
    test "a new turn appears on an already-open conversation without reloading", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)

      {:ok, _} =
        Conversations.add_agent_message(
          conversation,
          nil,
          "assistant",
          "start the first requirement"
        )

      {:ok, view, html} = live(conn, path(project))
      assert html =~ "start the first requirement"

      {:ok, _} =
        Conversations.add_agent_message(
          conversation,
          nil,
          "assistant",
          "move to the next requirement"
        )

      assert render(view) =~ "move to the next requirement"
    end
  end

  describe "project resolution" do
    test "an unknown project name redirects with a flash instead of 404ing", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/app/projects", flash: %{"error" => error}}}} =
               live(conn, "/app/projects/does-not-exist/agent-conversation")

      assert error =~ "not yours"
    end

    test "a project belonging to another account is treated as not found", %{conn: conn} do
      other_scope = CodeMySpec.UsersFixtures.full_scope_fixture()

      other_project =
        CodeMySpec.ProjectsFixtures.project_fixture(other_scope,
          account_id: other_scope.active_account_id,
          name: "someone-elses-project"
        )

      assert {:error, {:live_redirect, %{to: "/app/projects"}}} = live(conn, path(other_project))
    end
  end
end
