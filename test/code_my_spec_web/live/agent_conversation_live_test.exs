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

  # The index. One page per project, listing its agent sessions.
  defp path(project), do: "/app/projects/#{project.id}/agent-conversation"

  # One session's transcript. The page is per-session now — it used to show
  # whichever conversation moved most recently, which hid every other agent.
  defp show_path(project, conversation),
    do: "/app/projects/#{project.id}/agent-conversation/#{conversation.id}"

  defp agent_conversation(scope, project, external_id \\ "pi:/tmp/sprite-test") do
    {:ok, conversation} =
      Conversations.find_or_create_session_conversation(
        scope.active_account_id,
        project.id,
        external_id
      )

    conversation
  end

  describe "before any turn has been recorded" do
    test "shows an empty state", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, path(project))

      assert html =~ "No agent has recorded a turn"
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

      {:ok, view, html} = live(conn, show_path(project, conversation))

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
      # The shape the recorder actually writes: the tool, a newline, its arguments.
      # This said `"Bash(mix spex)"`, which no recorded message has ever been —
      # across this project's history the stored shapes are "Tool\njson" (933),
      # a bare name (6), and output misfiled under this role (14). Nothing inline.
      {:ok, _} =
        Conversations.add_agent_message(
          conversation,
          nil,
          "tool",
          "Bash\n{\"command\": \"mix spex\"}"
        )

      {:ok, view, html} = live(conn, show_path(project, conversation))

      assert html =~ "Bash"
      assert html =~ "mix spex"
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

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      assert has_element?(view, "[data-test='message'][data-agent-role='qa']")
      assert has_element?(view, "[data-test='message']:not([data-agent-role='qa'])")
    end

    test "a very long message is a preview you can open, not a wall", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)

      # The shape that prompted this: a sub-agent's work narrated back to its
      # parent as prose rather than as `tool_use` blocks, so the tool-call
      # collapsing never sees it. Measured at 67 kB in the live transcript.
      wall =
        "Called the Read tool with the following input: " <>
          String.duplicate("defmodule Example do\n  def run, do: :ok\nend\n", 400)

      {:ok, _} = Conversations.add_agent_message(conversation, nil, "assistant", wall)

      {:ok, view, html} = live(conn, show_path(project, conversation))

      assert has_element?(view, "[data-test='message'][data-long='true']"),
             "a message past the preview limit has to fold"

      assert has_element?(view, "[data-test='long-message']")

      # Kept, not truncated — the model received it, so it is part of the record.
      assert html =~ "show all #{byte_size(wall)} characters"
      assert String.contains?(html, "def run, do: :ok")
    end

    test "an ordinary message is not folded", %{conn: conn, scope: scope, project: project} do
      conversation = agent_conversation(scope, project)
      {:ok, _} = Conversations.add_agent_message(conversation, nil, "assistant", "short answer")

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      refute has_element?(view, "[data-test='long-message']"),
             "folding every message would put a click in front of every turn"

      assert has_element?(view, "[data-test='message'][data-long='false']")
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

      {:ok, view, html} = live(conn, show_path(project, conversation))
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
