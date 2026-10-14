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

  alias CmsHarness.Project.ChannelClient
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Mailbox
  alias CodeMySpec.Analysis.HarnessRegistry
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

  # The cockpit, on whichever agent the project opens with.
  defp path(project), do: "/app/projects/#{project.id}/agent-conversation"

  # The cockpit, on one named agent. A query param rather than a path segment:
  # the page is about the project, and which agent you are reading is a
  # selection inside it that can be patched without rebuilding the screen.
  defp show_path(project, conversation),
    do: "#{path(project)}?conversation=#{conversation.id}"

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
    # The cockpit is where somebody lands now, so an empty one has to say which
    # kind of empty it is. A project nobody has onboarded a checkout for has
    # nowhere to run an agent at all, and saying "no activity yet" would send
    # them looking for an agent that could never have started.
    test "a project with no checkout says there is nowhere to run", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, path(project))

      assert html =~ "no main working copy",
             "an empty cockpit that does not say why is indistinguishable from a " <>
               "broken one, and the remedy for this state is a checkout rather than " <>
               "waiting."
    end
  end

  describe "rendering recorded turns" do
    test "routine confirmations collapse while human messages and failures stay visible", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)

      legacy =
        "The reload from your promotion is confirmed: the application at /tmp/app is up and serving abc."

      {:ok, _} = Conversations.add_message(conversation, :operator, legacy, "operator")

      {:ok, _} =
        Conversations.add_message(
          conversation,
          :operator,
          "Please check the deployment",
          "operator"
        )

      {:ok, _} =
        Conversations.add_message(
          conversation,
          :operator,
          "Correction: deployment failed",
          "operator"
        )

      {:ok, view, _} = live(conn, show_path(project, conversation))

      assert has_element?(view, "details[data-test='routine-notice']:not([open])", legacy)
      assert has_element?(view, "[data-test='message']", "Please check the deployment")
      assert has_element?(view, "[data-test='message']", "Correction: deployment failed")
      refute has_element?(view, "[data-test='message']", legacy)
    end

    # 5150cd98: each confirmation was one line, but a landing and its reload
    # still stacked a line apiece and buried the feed.
    test "a run of promotion notices folds into one line", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)

      landed =
        "Your promotion of story 1060 (270fe9b484b2) landed on main in a batch with 3 other candidate(s)."

      reload =
        "The reload from your promotion is confirmed: the application at /tmp/app is up and serving abc."

      for text <- [landed, reload, reload] do
        {:ok, _} = Conversations.add_message(conversation, :operator, text, "operator")
      end

      {:ok, _} = Conversations.add_message(conversation, :operator, "Carry on", "operator")
      {:ok, _} = Conversations.add_message(conversation, :operator, reload, "operator")

      {:ok, view, _} = live(conn, show_path(project, conversation))

      assert has_element?(
               view,
               "details[data-test='routine-notice-run'][data-count='3']:not([open])",
               "Promotion confirmed ×3"
             )

      assert view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("[data-test='routine-notice-run']")
             |> length() == 1

      assert has_element?(view, "[data-test='message']", "Carry on")

      assert has_element?(
               view,
               "#agent-turns > div > details[data-test='routine-notice']",
               reload
             )
    end

    test "a run of pending promotion notices is one row, each still withdrawable", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {agent, conversation} = agent_with_conversation(scope, project)

      for _ <- 1..2 do
        {:ok, message} =
          Conversations.add_message(
            conversation,
            :operator,
            "The reload from your promotion is confirmed: serving abc.",
            "promotion-notice",
            [],
            delivery: :pending,
            delivery_ref: Ecto.UUID.generate()
          )

        Mailbox.admit(agent, message, :operator_message)
      end

      {:ok, view, _} = live(conn, show_path(project, conversation))

      assert has_element?(
               view,
               "[data-test='agent-pending-message'] details[data-test='pending-routine-notice'][data-count='2']",
               "Promotion confirmed ×2"
             )

      doc = view |> render() |> Floki.parse_document!()
      assert doc |> Floki.find("[data-test='agent-pending-message']") |> length() == 1
      assert doc |> Floki.find("[data-test='agent-withdraw-message']") |> length() == 2
    end

    test "a long queued message shows one line, with Read more", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {agent, conversation} = agent_with_conversation(scope, project)

      for text <- ["Short note.", "Stop the spex loop.\nThen merge local main and report."] do
        {:ok, message} =
          Conversations.add_message(conversation, :operator, text, "operator", [],
            delivery: :pending,
            delivery_ref: Ecto.UUID.generate()
          )

        Mailbox.admit(agent, message, :operator_message)
      end

      {:ok, view, _} = live(conn, show_path(project, conversation))

      assert has_element?(view, "[data-test='queued-message-text'].truncate", "Short note.")

      assert has_element?(
               view,
               "[data-test='queued-message-text'].truncate",
               "Then merge local main"
             )

      assert view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("[data-test='queued-message-read-more']")
             |> length() == 1
    end

    test "a pending routine notice stays withdrawable and collapses after delivery", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {agent, conversation} = agent_with_conversation(scope, project)

      {:ok, message} =
        Conversations.add_message(
          conversation,
          :operator,
          "Deployment confirmation details",
          "promotion-notice",
          [],
          delivery: :pending,
          delivery_ref: Ecto.UUID.generate()
        )

      Mailbox.admit(agent, message, :operator_message)

      {:ok, view, _} = live(conn, show_path(project, conversation))

      assert has_element?(view, "details[data-test='pending-routine-notice']:not([open])")
      assert has_element?(view, "[data-test='agent-withdraw-message']")
      assert {:ok, _} = Conversations.set_delivery(message, :delivered)
      refute has_element?(view, "[data-test='agent-pending-message']")

      assert has_element?(
               view,
               "details[data-test='routine-notice']:not([open])",
               "Deployment confirmation details"
             )
    end

    test "unowned historical pending messages have no withdrawal control", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)

      {:ok, _} =
        Conversations.add_message(conversation, :operator, "unknown outcome", "operator", [],
          delivery: :pending,
          delivery_ref: Ecto.UUID.generate()
        )

      {:ok, view, _} = live(conn, show_path(project, conversation))
      assert has_element?(view, "[data-test='agent-pending-message']", "unknown outcome")
      refute has_element?(view, "[data-test='agent-withdraw-message']")
    end

    test "a queued message enters the received transcript only on delivery", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)
      {:ok, message} = Conversations.add_message(conversation, :user, "queued instruction")

      message =
        Repo.update!(
          Ecto.Changeset.change(message, delivery: :pending, delivery_ref: Ecto.UUID.generate())
        )

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      refute has_element?(view, "[data-test='message'][data-role='user']", "queued instruction")
      assert has_element?(view, "[data-test='agent-pending-message']", "queued instruction")
      assert {:ok, _} = Conversations.set_delivery(message, :delivered)
      assert has_element?(view, "[data-test='message'][data-role='user']", "queued instruction")
      refute has_element?(view, "[data-test='agent-pending-message']")
      {:ok, reloaded, _html} = live(conn, show_path(project, conversation))

      assert has_element?(
               reloaded,
               "[data-test='message'][data-role='user']",
               "queued instruction"
             )
    end

    test "a queued answer arriving on an open page appears once and can be withdrawn", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)
      {:ok, view, _html} = live(conn, show_path(project, conversation))

      {:ok, message} =
        Conversations.add_message(conversation, :operator, "Keep existing", "operator", [],
          delivery: :pending,
          delivery_ref: Ecto.UUID.generate()
        )

      assert has_element?(view, "[data-test='agent-pending-message']", "Keep existing")
      send(view.pid, {:new_message, message})

      assert view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("[data-test='agent-pending-message']")
             |> length() == 1

      refute has_element?(view, "[data-test='message'][data-role='operator']", "Keep existing")
      assert {:ok, _} = Conversations.set_delivery(message, :withdrawn)
      refute has_element?(view, "[data-test='agent-pending-message']")
      refute render(view) =~ "Keep existing"
    end

    test "failed delivery remains auditable without appearing received", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)
      {:ok, message} = Conversations.add_message(conversation, :user, "undelivered instruction")

      message =
        Repo.update!(
          Ecto.Changeset.change(message, delivery: :pending, delivery_ref: Ecto.UUID.generate())
        )

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      assert {:ok, _} = Conversations.set_delivery(message, :failed)

      refute has_element?(
               view,
               "[data-test='message'][data-role='user']",
               "undelivered instruction"
             )

      assert Repo.reload!(message).delivery == :failed
      {:ok, reloaded, _html} = live(conn, show_path(project, conversation))

      refute has_element?(
               reloaded,
               "[data-test='message'][data-role='user']",
               "undelivered instruction"
             )
    end

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

    test "a very long message renders in full, not folded", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)
      tail = "the last line of a long message"
      wall = String.duplicate("defmodule Example do\n  def run, do: :ok\nend\n", 400) <> tail

      {:ok, _} = Conversations.add_agent_message(conversation, nil, "assistant", wall)

      {:ok, view, html} = live(conn, show_path(project, conversation))

      refute has_element?(view, "[data-test='message'] details")
      assert html =~ tail
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

    # The two tests that used to sit here asserted the agents index's rows —
    # "/tmp/copy-alpha · coding" and a Claude Code lane's external id, read off
    # a list page that no longer exists. Telling two lanes apart is still the
    # claim; the surface that makes it is the cockpit's team panel, which names
    # each agent's role under its checkout's heading and carries
    # `data-test="team-agent"` with the agent's id. Story 1018's criterion 2824
    # is what holds that now.
  end

  describe "the shape this page used to have" do
    # Web Push sent conversation links with the id in the path, and the ones
    # already delivered outlive the change. A notification that 404s costs more
    # than the navigation moving it into the query string saved.
    test "an old conversation link lands on the same conversation", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/app/projects/#{project.id}/agent-conversation/#{conversation.id}")

      assert to == show_path(project, conversation),
             "an old link resolved somewhere other than the conversation it names"
    end
  end

  describe "project resolution" do
    test "an unknown project name redirects with a flash instead of 404ing", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/app/projects", flash: %{"error" => error}}}} =
               live(conn, "/app/projects/does-not-exist/agent-conversation")

      # `PortableHost` refuses this for every `/app/projects/:project_id/...`
      # route now, so the wording is the host's rather than this view's — see
      # `d500df3b`. Named as an account problem because the id is usually real.
      assert error =~ "not in the account you are in"
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

  describe "what the agent is writing" do
    alias CodeMySpec.Conversations.Drafts

    test "shows the draft as it grows and drops it when the turn settles", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {_agent, conversation} = agent_with_conversation(scope, project)
      {:ok, view, _html} = live(conn, show_path(project, conversation))

      refute has_element?(view, "#agent-writing")

      Drafts.put(conversation.id, "Plums are")
      assert view |> element("#agent-writing") |> render() =~ "Plums are"

      Drafts.put(conversation.id, "Plums are stone fruits.")
      assert view |> element("#agent-writing") |> render() =~ "Plums are stone fruits."

      Drafts.clear(conversation.id)
      refute has_element?(view, "#agent-writing")
    end

    test "completed installation guidance survives reopening after its draft clears", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {agent, conversation} = agent_with_conversation(scope, project)
      {:ok, view, _html} = live(conn, show_path(project, conversation))

      guidance =
        "Install pgvector for your PostgreSQL version, then verify the extension is available."

      Drafts.put(conversation.id, "Install pgvector")
      on_exit(fn -> Drafts.clear(conversation.id) end)
      assert has_element?(view, "#agent-writing", "Install pgvector")

      CodeMySpec.Agents.record_turn_event(scope, agent.id, %{
        "kind" => "message",
        "text" => guidance
      })

      Drafts.clear(conversation.id)
      assert has_element?(view, "[data-test='message'][data-role='assistant']", guidance)
      refute has_element?(view, "#agent-writing")

      {:ok, reopened, _html} = live(conn, show_path(project, conversation))
      assert has_element?(reopened, "[data-test='message'][data-role='assistant']", guidance)
      refute has_element?(reopened, "#agent-writing")
    end

    test "a page opened mid-turn shows the draft without waiting for more", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {_agent, conversation} = agent_with_conversation(scope, project)
      Drafts.put(conversation.id, "Halfway through a sentence")
      on_exit(fn -> Drafts.clear(conversation.id) end)

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      assert view |> element("#agent-writing") |> render() =~ "Halfway through a sentence"
    end

    test "ignores another conversation's draft", %{conn: conn, scope: scope, project: project} do
      {_agent, conversation} = agent_with_conversation(scope, project)
      {:ok, view, _html} = live(conn, show_path(project, conversation))

      send(view.pid, {:agent_draft, Ecto.UUID.generate(), "not yours"})

      refute has_element?(view, "#agent-writing")
    end
  end

  # 39af5611: the stop button became a power switch. Green and labelled "Turn
  # agent off" while on; red and "Turn agent on" while off. f096eba2 moved it
  # off the header entirely and onto each agent's own row in the team panel,
  # so every agent is reachable without opening its conversation.
  describe "the power button, on the team panel" do
    defp panel_power(agent_id),
      do: "[data-test='team-agent'][data-agent-id='#{agent_id}'] [data-test='team-agent-power']"

    defp open_team_panel(view) do
      render_hook(view, "viewport", %{"width" => 1200})
      render_hook(view, "toggle_panel", %{"panel" => "activity"})
    end

    @on_attrs "[data-on='true'][aria-label='Turn agent off'].text-success"
    @off_attrs "[data-on='false'][aria-label='Turn agent on'].text-error"

    test "an agent that is on shows green, and a click turns it off", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {agent, conversation} = agent_with_conversation(scope, project)

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      open_team_panel(view)

      assert has_element?(view, panel_power(agent.id) <> @on_attrs)

      view |> element(panel_power(agent.id)) |> render_click()

      off = Repo.get(Agent, agent.id)
      assert off.status == :stopped
      assert Agent.off?(off)
      assert off.off_by == scope.user.email
      assert has_element?(view, panel_power(agent.id) <> @off_attrs)
      assert render(view) =~ "Agent turned off."
    end

    test "an agent that is off shows red, and a click turns it on", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      CodeMySpec.IntegrationsFixtures.integration_fixture(scope.user, %{provider: :anthropic})

      {agent, conversation} =
        agent_with_conversation(scope, project, %{
          status: :stopped,
          off_at: DateTime.utc_now(),
          off_by: "someone else"
        })

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      open_team_panel(view)

      assert has_element?(view, panel_power(agent.id) <> @off_attrs)

      view |> element(panel_power(agent.id)) |> render_click()

      on = Repo.get(Agent, agent.id)
      refute Agent.off?(on)
      refute on.status == :stopped
      assert has_element?(view, panel_power(agent.id) <> @on_attrs)
      assert render(view) =~ "Agent turned on."
    end

    test "turning an agent off from the panel also updates the open header, when it is the same agent",
         %{conn: conn, scope: scope, project: project} do
      {agent, conversation} = agent_with_conversation(scope, project)

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      open_team_panel(view)

      view |> element(panel_power(agent.id)) |> render_click()

      assert has_element?(
               view,
               "header [data-test='toggle-agent-working']"
             ),
             "the header's own controls should still be there after a panel toggle"
    end

    test "the team panel shows a retired agent's seat as empty, with the Staff action", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {retired, _conversation} =
        agent_with_conversation(scope, project, %{
          status: :stopped,
          retired_at: DateTime.utc_now(),
          retired_by: "someone"
        })

      {:ok, view, _html} = live(conn, path(project))
      render_hook(view, "viewport", %{"width" => 1200})
      # Panels start closed for a fresh user; this opens the team panel.
      render_hook(view, "toggle_panel", %{"panel" => "activity"})

      assert has_element?(view, "[data-test='team-copy']")
      refute has_element?(view, "[data-test='team-agent'][data-agent-id='#{retired.id}']")
      assert has_element?(view, "[data-test='team-empty-seats']", "coding")
      assert has_element?(view, "[data-test='team-empty-seats']", "Staff it")
    end
  end

  describe "what the agent is assigned" do
    test "the header and the team panel link the agent's issue and story", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      project_scope = %{scope | active_project_id: project.id, active_project: project}
      story = CodeMySpec.StoriesFixtures.story_fixture(project_scope, %{title: "Pay by card"})
      issue = CodeMySpec.IssuesFixtures.issue_fixture(project_scope, %{title: "Card form 500s"})

      {agent, conversation} =
        agent_with_conversation(scope, project, %{story_id: story.id, issue_id: issue.id})

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      open_team_panel(view)

      story_path = "/app/projects/#{project.id}/stories/#{story.number}"
      issue_path = "/app/projects/#{project.id}/issues/#{issue.id}"

      assert has_element?(
               view,
               "header a[data-test='assigned-story'][href='#{story_path}']",
               "Pay by card"
             )

      assert has_element?(
               view,
               "header a[data-test='assigned-issue'][href='#{issue_path}']",
               "Card form 500s"
             )

      row = "[data-test='team-agent'][data-agent-id='#{agent.id}']"

      assert has_element?(
               view,
               "#{row} a[data-test='team-agent-story'][href='#{story_path}']",
               "##{story.number}"
             )

      assert has_element?(view, "#{row} a[data-test='team-agent-issue'][href='#{issue_path}']")
    end
  end

  describe "a story's progress pie" do
    test "shows satisfied of total and follows a graph update", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      alias CodeMySpec.Requirements.Node

      project_scope = %{scope | active_project_id: project.id, active_project: project}
      story = CodeMySpec.StoriesFixtures.story_fixture(project_scope)

      [first, _second] =
        for name <- ["spex_written", "qa_passed"] do
          Repo.insert!(%Node{story_id: story.id, name: name, description: name, satisfied: false})
        end

      {agent, conversation} = agent_with_conversation(scope, project, %{story_id: story.id})

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      open_team_panel(view)

      header = "header [data-test='story-progress']"
      row = "[data-test='team-agent'][data-agent-id='#{agent.id}'] [data-test='story-progress']"

      assert has_element?(view, header <> "[data-done='0'][data-total='2']")
      assert has_element?(view, row <> "[data-done='0'][data-total='2']")

      Repo.update!(Ecto.Changeset.change(first, satisfied: true))
      send(view.pid, {:graph_updated, project.id})

      # The graph handler enqueues send_update messages for the components.
      # This render waits for that handler; the assertions then run after
      # its queued component updates, matching the two-hop pattern above.
      render(view)

      assert has_element?(view, header <> "[data-done='1'][data-total='2']")
      assert has_element?(view, row <> "[data-done='1'][data-total='2']")
    end
  end

  describe "the team panel's turn indicator" do
    test "shows while a turn runs and goes when it ends", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {agent, conversation} = agent_with_conversation(scope, project, %{status: :running})

      turn =
        "[data-test='team-agent'][data-agent-id='#{agent.id}'] [data-test='team-agent-turn']"

      scope = %{scope | active_project_id: project.id}

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      open_team_panel(view)
      refute has_element?(view, turn)

      CodeMySpec.Agents.record_turn_event(scope, agent.id, %{"kind" => "turn_started"}, [])
      assert has_element?(view, turn)

      CodeMySpec.Agents.record_turn_event(
        scope,
        agent.id,
        ChannelClient.encode_turn_event(
          CodeMySpecSpex.Fixtures.mailbox_turn_end(scope, agent.id)
        ),
        []
      )

      refute has_element?(view, turn)
    end
  end

  describe "the cockpit header, since f096eba2 dropped its loop badge" do
    test "the header shows play/pause and power but no 'Continuous'/'Not continuous' text", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {_agent, conversation} = agent_with_conversation(scope, project, %{continuous: false})

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      assert has_element?(view, "header [data-test='toggle-agent-working']")

      refute has_element?(view, "header [data-test='agent-loop']"),
             "the header should no longer render the loop badge/text at all"

      assert has_element?(view, "header [data-test='agent-power'][data-on='true']")
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
      do: :ok = HarnessRegistry.register_executor(working_copy_id)

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

    # A pending tap-out used to withhold the wake, so the page had to explain
    # why the button appeared to do nothing. It no longer gates anything
    # globally — a tap-out blocks its own task — and the button no longer sends
    # a wake at all. What it must still do is flip the flag and say plainly that
    # no process was touched.
    test "a pending tap-out no longer gates the button, which says what it did", %{
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

      assert html =~ "no process was started or restarted",
             "the button did something invisible and the page said nothing about it"

      assert Repo.get(Agent, agent.id).continuous,
             "the flag is the part that always lands; it did not"
    end

    # `status: :running` on a row a shared harness restart pulled the rug out
    # from under. Nothing is registered for its working copy.
    #
    # This used to restart the agent in place. Starting and setting continuous
    # were coupled, and decoupling them is the point: the button records
    # standing intent about turns and starts nothing. So the claim is no longer
    # "it restarted" but the honest half that always mattered — the page says
    # what happened instead of pretending the button ran something.
    test "a disconnected working copy is told plainly that nothing was started", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {agent, conversation} =
        agent_with_conversation(scope, project, %{continuous: false, status: :running})

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      html = view |> element("[data-test='toggle-agent-working']") |> render_click()

      assert html =~ "no process was started or restarted",
             "a disconnected working copy must say what happened rather than " <>
               "silently pretending the button started something"

      assert Repo.get(Agent, agent.id).continuous
    end
  end
end
