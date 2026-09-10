defmodule CodeMySpecWeb.AgentConversationLiveTest do
  @moduledoc """
  `AgentConversationLive` is the read-only, per-project window onto a
  background sprite's agent conversation: it renders whatever
  `CodeMySpec.Conversations` already knows about a project's agent session and
  streams new turns in live. It never composes a reply.
  """

  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Analysis
  alias CodeMySpec.Conversations
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies

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

    test "an epic created while the dynamic tab is open switches it to epics, live", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)
      scope = %{scope | active_project_id: project.id, active_project: project}

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      render_hook(view, "viewport", %{"width" => 1440})
      view |> element(~s([data-test="panel-tab-dynamic"])) |> render_click()

      html = render(view)
      assert html =~ ~s(data-dynamic-view="stories")

      {:ok, epic} = CodeMySpec.Epics.create_epic(scope, %{name: "Onboarding polish"})

      # Two hops, two messages: the epic event's own handler calls
      # `ScreenState.show/2`, which broadcasts `:screen_changed` to the same
      # process — a second message this render() has to let through before the
      # switch is visible. The first render() below processes `:epic_created`
      # (and, in doing so, enqueues `:screen_changed` behind it); the second
      # sees `:screen_changed` applied.
      render(view)
      html = render(view)
      assert html =~ ~s(data-dynamic-view="epics")
      assert html =~ epic.name
    end

    test "a second epic appearing while epics are already shown appears without reloading", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)
      scope = %{scope | active_project_id: project.id, active_project: project}
      {:ok, first} = CodeMySpec.Epics.create_epic(scope, %{name: "Already there"})

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      render_hook(view, "viewport", %{"width" => 1440})
      view |> element(~s([data-test="panel-tab-dynamic"])) |> render_click()
      CodeMySpec.ScreenState.show(scope, %{view: "epics"})
      html = render(view)
      assert html =~ first.name

      {:ok, second} = CodeMySpec.Epics.create_epic(scope, %{name: "Just arrived"})

      html = render(view)
      assert html =~ first.name
      assert html =~ second.name
    end

    test "a new story appearing while the stories view is shown appears without reloading", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)
      scope = %{scope | active_project_id: project.id, active_project: project}

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      render_hook(view, "viewport", %{"width" => 1440})
      view |> element(~s([data-test="panel-tab-dynamic"])) |> render_click()

      story = CodeMySpec.StoriesFixtures.story_fixture(scope, %{title: "Freshly asked for"})

      html = render(view)

      assert html =~ story.title,
             "the stories view did not pick up a story created after the panel opened"
    end
  end

  # Two agents on one checkout are two rows, and the page has to say which is
  # which. Issue 27b5350e: the conversation was keyed on `pi:<path>`, so every
  # agent on a copy adopted the same thread — an agent started on a worktree
  # silently picked up one from ten days earlier with two turns already on it.
  #
  # Keying on the agent fixed that and emptied the row's second line, which had
  # been rendering `session_external_id` and so was carrying the checkout by
  # accident. An index of identically-shaped rows with generated names and no
  # distinguishing line is the problem the path was in the key to solve
  # (18f50c87 — three copies, indistinguishable).
  describe "telling two agents apart on the index" do
    defp lane(scope, project, root, role) do
      scope = %{scope | active_project: project, active_project_id: project.id}

      {:ok, agent} =
        AgentsRepository.create_agent(scope, %{
          engine: :alloy,
          provider: "zai",
          working_copy: root,
          role: role,
          working_copy_id: CodeMySpec.WorkingCopies.ensure_default(scope),
          project_id: project.id,
          account_id: scope.active_account_id,
          status: :starting
        })

      {:ok, conversation} =
        Conversations.find_or_create_agent_conversation(
          scope.active_account_id,
          project.id,
          agent.id
        )

      {agent, conversation}
    end

    test "two lanes on one copy get their own conversations", %{scope: scope, project: project} do
      {_a, first} = lane(scope, project, "/tmp/one-copy", "coding")
      {_b, second} = lane(scope, project, "/tmp/one-copy", "qa")

      refute first.id == second.id,
             "both lanes adopted one thread, so their turns interleave with nothing " <>
               "saying who spoke — and stopping one would look like stopping both."
    end

    test "each row names its checkout and role", %{conn: conn, scope: scope, project: project} do
      lane(scope, project, "/tmp/copy-alpha", "coding")
      lane(scope, project, "/tmp/copy-alpha", "qa")

      {:ok, _view, html} = live(conn, path(project))

      assert html =~ "/tmp/copy-alpha · coding"

      assert html =~ "/tmp/copy-alpha · qa",
             "the rows carry generated names and nothing else, so an index of three " <>
               "copies is three identical-looking rows. That is 18f50c87, which is why " <>
               "the checkout was in the conversation key before it moved to the agent."
    end

    test "a Claude Code lane still shows its external id", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      # No agent row of its own — it arrives with an external id and is exactly
      # the caller `find_or_create_session_conversation/3` was split out for.
      agent_conversation(scope, project, "pi:/tmp/claude-code-lane")

      {:ok, _view, html} = live(conn, path(project))

      assert html =~ "pi:/tmp/claude-code-lane",
             "the left join dropped the row that has no agent, or blanked its line."
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

  defp agent_with_conversation(scope, project, attrs \\ %{}) do
    scope = %{scope | active_project_id: project.id}

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, label: "a checkout", device: device_fixture(scope))

    base = %{
      provider: "anthropic",
      engine: :alloy,
      role: "coding",
      continuous: true,
      working_copy: "/tmp/stop-btn-#{System.unique_integer([:positive])}",
      working_copy_id: copy.id
    }

    {:ok, agent} = AgentsRepository.create_agent(scope, Map.merge(base, attrs))

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        project.id,
        agent.id
      )

    {agent, conversation}
  end

  describe "stopping an agent" do
    test "a click ends the agent and confirms it", %{conn: conn, scope: scope, project: project} do
      {agent, conversation} = agent_with_conversation(scope, project)

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      assert has_element?(view, "[data-test='stop-agent']")

      view |> element("[data-test='stop-agent']") |> render_click()

      assert Repo.get(Agent, agent.id).status == :stopped
      assert render(view) =~ "Agent stopped."
    end

    # A conversation with no agent of its own — story 538's "same page also
    # renders a Claude Code session's transcript" shape — has nothing this
    # button could stop.
    test "a conversation with no agent shows no stop control", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      refute has_element?(view, "[data-test='stop-agent']")
    end
  end

  # John, clicking play: "it doesn't deliver the message about existing
  # problems... is that being blocked now?" `set_agent_continuous/3` calls
  # `StopDecision.wake/2`, which goes silent for an agent with a pending
  # question or tap-out — correct for the automatic project-wide fan-out, but
  # a person pressing play deserves to know why nothing arrived rather than
  # watching the button appear to do nothing.
  describe "putting an agent back to work" do
    # What a channel join does, per `Analysis.register_executor/3`'s own
    # test — without this, `working_copy_connected?/1` sees no live registry
    # entry and every one of these takes the restart path instead of the
    # wake path they are actually testing.
    defp connect_working_copy(working_copy_id),
      do: :ok = Analysis.register_executor(working_copy_id)

    test "switching it on delivers nothing more than a plain flash", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {agent, conversation} = agent_with_conversation(scope, project, %{continuous: false})
      connect_working_copy(agent.working_copy_id)

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      html = view |> element("[data-test='toggle-agent-working']") |> render_click()

      refute html =~ "pending question or tap-out",
             "an agent with nothing outstanding was told about a request it does not have"

      refute html =~ "wasn't actually running",
             "a connected working copy should be woken, not restarted"
    end

    test "an agent with a pending tap-out says why nothing was sent", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {agent, conversation} = agent_with_conversation(scope, project, %{continuous: false})
      connect_working_copy(agent.working_copy_id)

      {:ok, _request} =
        CodeMySpec.Notifications.create_permission_request(scope.user.id, %{
          "agent_id" => agent.id,
          "tool_name" => "tap_out",
          "tool_input" => %{"agent_id" => agent.id}
        })

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      html = view |> element("[data-test='toggle-agent-working']") |> render_click()

      assert html =~ "pending question or tap-out",
             "the button did something invisible and the page said nothing about it"

      assert Repo.get(Agent, agent.id).continuous,
             "the flag still has to flip — only the wake message is withheld"
    end

    # The case this whole feature is for: `status: :running` on a row a
    # shared harness restart pulled the rug out from under. Nothing is
    # registered for its working copy, so this must restart it in place
    # rather than nudging a process that is not there — and land on the
    # same conversation, not a new one.
    test "an agent whose working copy is not connected gets restarted, not nudged", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {agent, conversation} =
        agent_with_conversation(scope, project, %{continuous: false, status: :running})

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      html = view |> element("[data-test='toggle-agent-working']") |> render_click()

      assert html =~ "wasn't actually running" or html =~ "restarting it failed",
             "a disconnected working copy must say it restarted (or that restarting " <>
               "failed) rather than silently pretending the button worked"

      assert Repo.get(Agent, agent.id).continuous
    end
  end
end
