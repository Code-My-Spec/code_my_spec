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
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Requirements.StoryGraph, as: RequirementStoryGraph
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

    test "a finished delivery's old diagnostic is not listed as waiting", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {agent, conversation} = agent_with_conversation(scope, project)

      {:ok, message} =
        Conversations.add_message(conversation, :operator, "earlier note", "operator", [],
          delivery: :delivered,
          delivery_ref: Ecto.UUID.generate()
        )

      entry = Mailbox.admit(agent, message, :operator_message)

      entry
      |> Ecto.Changeset.change(
        state: :interrupted,
        diagnostic: "Owning engine was replaced. Consumed work may have side effects."
      )
      |> Repo.update!()

      {:ok, view, _} = live(conn, show_path(project, conversation))

      refute has_element?(view, "[data-test='agent-pending-message']")
      refute render(view) =~ "Owning engine was replaced"
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

    test "the same message delivered twice does not duplicate on screen", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)
      {:ok, message} = Conversations.add_agent_message(conversation, nil, "assistant", "hello")

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      # A redelivered broadcast (e.g. after a reconnect) rather than a second
      # write -- `upsert/2` is supposed to replace, not append, when the id
      # already appears.
      send(view.pid, {:new_message, message})

      assert render(view) =~ "hello"
    end

    test "a message that arrives out of order is not duplicated when older turns load", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = agent_conversation(scope, project)
      {:ok, oldest} = Conversations.add_agent_message(conversation, nil, "assistant", "oldest")

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      {:ok, newer} = Conversations.add_agent_message(conversation, nil, "assistant", "newer")
      assert render(view) =~ "newer"

      # A write that lands after `oldest` but is stamped earlier than it --
      # clock skew between writers, or a slow insert finally landing. `upsert/2`
      # appends to the end of `@messages` regardless of its own timestamp, so
      # this message is now both "on screen" (at the tail) and, by its
      # timestamp, exactly what `load_older`'s `before:` cursor asks for.
      late =
        newer
        |> Ecto.Changeset.change(inserted_at: DateTime.add(oldest.inserted_at, -1, :second))
        |> Repo.update!()

      send(view.pid, {:new_message, late})
      assert render(view) =~ "newer"

      html = render_hook(view, "load_older", %{})
      assert html =~ "newer"

      occurrences =
        html
        |> String.split("id=\"turn-group-#{late.id}\"")
        |> length()
        |> Kernel.-(1)

      assert occurrences == 1,
             "expected turn-group-#{late.id} to render once, found #{occurrences} times"
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

      CodeMySpec.Agents.record_turn_event(%{scope | active_project_id: project.id}, agent.id, %{
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
    test "the header and the copy's row open the story and issue in a modal", %{
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
      copy = "[data-test='team-copy'][data-working-copy-id='#{agent.working_copy_id}']"

      assert has_element?(view, "header [data-test='assigned-story']", "Pay by card")
      assert has_element?(view, "header [data-test='assigned-issue']", "Card form 500s")
      refute has_element?(view, "[data-test='team-agent'] [data-test^='team-agent-story']")

      view |> element("#{copy} [data-test='team-copy-story']") |> render_click()

      assert has_element?(view, "[data-test='assigned-modal-story']", "Pay by card")
      assert has_element?(view, "[data-test='assigned-modal-story'] a[href='#{story_path}']")

      render_click(view, "close_assigned", %{})
      refute has_element?(view, "[data-test^='assigned-modal']")

      view |> element("header [data-test='assigned-issue']") |> render_click()

      assert has_element?(view, "[data-test='assigned-modal-issue']", "Card form 500s")
      assert has_element?(view, "[data-test='assigned-modal-issue'] a[href='#{issue_path}']")
    end

    test "a copy with an issue bag shows the bag, not its team's story", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      project_scope = %{scope | active_project_id: project.id, active_project: project}
      story = CodeMySpec.StoriesFixtures.story_fixture(project_scope)
      {agent, conversation} = agent_with_conversation(scope, project, %{story_id: story.id})

      for title <- ["Card form 500s", "Receipt never sent"] do
        issue = CodeMySpec.IssuesFixtures.issue_fixture(project_scope, %{title: title})
        {:ok, issue} = CodeMySpec.Issues.accept_issue(project_scope, issue)

        {:ok, _} =
          CodeMySpec.Issues.set_assigned_working_copy(project_scope, issue, agent.working_copy_id)
      end

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      open_team_panel(view)

      copy = "[data-test='team-copy'][data-working-copy-id='#{agent.working_copy_id}']"
      status = "/app/projects/#{project.id}/working-copies/#{agent.working_copy_id}/status"

      # Assigned is each issue's first milestone of three.
      assert has_element?(
               view,
               "#{copy} a[data-test='team-copy-issues'][href='#{status}']",
               "2 issues"
             )

      assert has_element?(
               view,
               "#{copy} [data-test='team-copy-issue-progress'][data-done='2'][data-total='6']"
             )

      refute has_element?(view, "#{copy} [data-test='team-copy-story']")
    end

    test "a copy with one issue names it and opens it", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      project_scope = %{scope | active_project_id: project.id, active_project: project}
      {agent, conversation} = agent_with_conversation(scope, project)
      issue = CodeMySpec.IssuesFixtures.issue_fixture(project_scope, %{title: "Card form 500s"})
      {:ok, issue} = CodeMySpec.Issues.accept_issue(project_scope, issue)

      {:ok, issue} =
        CodeMySpec.Issues.set_assigned_working_copy(project_scope, issue, agent.working_copy_id)

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      open_team_panel(view)

      copy = "[data-test='team-copy'][data-working-copy-id='#{agent.working_copy_id}']"
      refute has_element?(view, "#{copy} [data-test='team-copy-issues']")

      view
      |> element("#{copy} [data-test='team-copy-issue']", String.slice(issue.id, 0, 8))
      |> render_click()

      assert has_element?(view, "[data-test='assigned-modal-issue']", "Card form 500s")
    end

    test "a copy with nothing assigned shows a greyed pie", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {agent, conversation} = agent_with_conversation(scope, project)

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      open_team_panel(view)

      copy = "[data-test='team-copy'][data-working-copy-id='#{agent.working_copy_id}']"
      assert has_element?(view, "#{copy} [data-test='team-copy-unassigned']")
    end
  end

  describe "the project's own agent" do
    test "a Claude Code main on the main copy gets the timeline with no terminal connected", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {agent, conversation} =
        agent_with_conversation(scope, project, %{role: "main", engine: :claude_code})

      {:ok, _copy} =
        CodeMySpec.Staffing.designate_main(
          %{scope | active_project_id: project.id},
          agent.working_copy_id
        )

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      assert has_element?(view, "[data-test='project-timeline']")
      assert has_element?(view, "[data-test='story-chart']")
      assert has_element?(view, "[data-test='component-bar']")
      assert has_element?(view, "[data-test='issue-bar']")
      assert has_element?(view, "[data-test='architecture-mark'][data-cycles]")

      assert has_element?(
               view,
               "[data-test='story-counts'][data-done][data-backlog][data-retired]"
             )

      view |> element("[data-test='open-graph']") |> render_click()
      render_async(view)

      assert has_element?(view, "[data-test='graph-modal'] #timeline-graph[data-graph]")
      assert has_element?(view, "[data-test='graph-modal'] a[data-test='graph-modal-open']")

      view |> element("[data-test='graph-modal'] .modal-backdrop") |> render_click()
      refute has_element?(view, "[data-test='graph-modal']")

      view
      |> element("[data-test='timeline-step'][data-step='work_dispatched'] a")
      |> render_click()

      render_async(view)

      assert has_element?(
               view,
               "[data-test='graph-modal'] [data-test='node-detail'][data-node='work_dispatched']"
             )
    end

    test "a story's column opens its graph, the stories count its text, and a switch flips them",
         %{
           conn: conn,
           scope: scope,
           project: project
         } do
      project_scope = %{scope | active_project_id: project.id, active_project: project}

      [first, second] =
        for title <- ["Pay by card", "Refund a payment"],
            do: CodeMySpec.StoriesFixtures.story_fixture(project_scope, %{title: title})

      {agent, conversation} =
        agent_with_conversation(scope, project, %{role: "main", engine: :claude_code})

      {:ok, _copy} = CodeMySpec.Staffing.designate_main(project_scope, agent.working_copy_id)

      :ok =
        RequirementGraph.settle(%{project_scope | active_working_copy_id: agent.working_copy_id})

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      view |> element("[data-test='story-column'][data-story-id='#{first.id}']") |> render_click()

      # The column opens its graph; the switch flips to its text and back.
      assert has_element?(view, "[data-test='story-graph-modal']", first.title)

      view
      |> element("[data-test='story-graph-modal'] [data-test='story-view-text']")
      |> render_click()

      refute has_element?(view, "[data-test='story-graph-modal']")
      assert has_element?(view, "[data-test='assigned-modal-story']", first.title)
      assert has_element?(view, "[data-test='chart-story-slider'] input[type='range'][max='1']")
      view |> element("#chart-story-slider") |> render_change(%{"index" => "1"})
      assert has_element?(view, "[data-test='assigned-modal-story']", second.title)

      view
      |> element("[data-test='assigned-modal-story'] [data-test='story-view-graph']")
      |> render_click()

      refute has_element?(view, "[data-test='assigned-modal-story']")
      assert has_element?(view, "[data-test='story-graph-modal']", second.title)
      render_click(view, "close_story_graph", %{})

      # The stories count opens the text, from the chart's first story.
      view |> element("[data-test='story-counts']") |> render_click()
      assert has_element?(view, "[data-test='assigned-modal-story']", first.title)

      render_click(view, "close_assigned", %{})
      view |> element("[data-test='story-column'][data-story-id='#{first.id}']") |> render_click()
      assert has_element?(view, "[data-test='story-graph-modal']", first.title)
      assert has_element?(view, "[data-test='story-graph-slider'] input[type='range'][max='1']")

      # The graph arriving renders the stage drawn, not loading.
      render_async(view)
      refute has_element?(view, "[data-test='story-graph-loading-empty']")

      # A phone's canvas with no size yet reports its viewport as nulls.
      render_hook(view, "lf:viewport_change", %{"x" => nil, "y" => nil, "zoom" => nil})
      assert has_element?(view, "[data-test='story-graph-modal']")

      # Equal progress orders the two by number, so the second is at 1.
      assert has_element?(view, "[data-test='story-graph-slider'] input[value='0']")
      view |> element("#story-graph-slider") |> render_change(%{"index" => "1"})

      assert has_element?(view, "[data-test='story-graph-modal']", second.title)
      render_async(view)
      refute has_element?(view, "[data-test='story-graph-loading']")
    end

    test "the issue counts open the open issues, and one opens in place with the way back", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      project_scope = %{scope | active_project_id: project.id, active_project: project}

      {agent, conversation} =
        agent_with_conversation(scope, project, %{role: "main", engine: :claude_code})

      {:ok, _copy} = CodeMySpec.Staffing.designate_main(project_scope, agent.working_copy_id)

      issue =
        CodeMySpec.IssuesFixtures.issue_fixture(project_scope, %{
          title: "Card form 500s",
          severity: :high
        })

      _low =
        CodeMySpec.IssuesFixtures.issue_fixture(project_scope, %{
          title: "Typo in footer",
          severity: :low
        })

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      view |> element("[data-test='issue-bar']") |> render_click()

      assert has_element?(
               view,
               "[data-test='issues-modal'] [data-test='issue-row']",
               "Card form 500s"
             )

      refute has_element?(view, "[data-test='issues-modal']", "Typo in footer")

      assert has_element?(view, "[data-test='issues-modal'] [data-test='issues-over-time']")
      view |> element("[data-test='issues-modal'] [data-range='7d']") |> render_click()
      assert has_element?(view, "[data-test='issues-modal'] [data-range='7d'].btn-active")

      view |> element("[data-test='issue-row'][data-issue-id='#{issue.id}']") |> render_click()

      assert has_element?(
               view,
               "[data-test='issues-modal'] [data-test='issue-detail']",
               "Card form 500s"
             )

      view |> element("[data-test='issues-modal-back']") |> render_click()
      assert has_element?(view, "[data-test='issues-modal'] [data-test='issue-row']")
    end

    test "a main-role agent on another copy does not", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {_agent, conversation} =
        agent_with_conversation(scope, project, %{role: "main", engine: :claude_code})

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      refute has_element?(view, "[data-test='project-timeline']")
    end
  end

  describe "a copy at a glance" do
    test "a copy's row counts its problems; clicking shows where they are", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {agent, conversation} = agent_with_conversation(scope, project)

      copy_scope = %{
        scope
        | active_project_id: project.id,
          active_working_copy_id: agent.working_copy_id
      }

      {:ok, _} =
        CodeMySpec.Problems.create_problems(copy_scope, [
          %{
            severity: :error,
            source: "exunit",
            source_type: :test,
            file_path: "test/a_test.exs",
            line: 1,
            message: "boom",
            category: "t"
          },
          %{
            severity: :info,
            source: "credo",
            source_type: :static_analysis,
            file_path: "lib/a.ex",
            line: 2,
            message: "meh",
            category: "c"
          }
        ])

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      open_team_panel(view)

      marker =
        "[data-test='team-copy'][data-working-copy-id='#{agent.working_copy_id}'] [data-test='copy-problems-marker']"

      assert has_element?(view, marker <> "[data-total='2'][data-worst='error']")

      view |> element(marker) |> render_click()

      assert has_element?(view, "[data-test='problems-modal'] [data-test='problems-by-file']")

      assert has_element?(
               view,
               "[data-test='problems-modal'] a[data-test='problems-modal-open'][href='/app/projects/#{project.id}/problems?harness=#{agent.working_copy_id}']"
             )

      render_click(view, "close_problems", %{})
      refute has_element?(view, "[data-test='problems-modal']")
    end

    test "clicking a copy opens its facts with the way to its show and status pages", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {agent, conversation} = agent_with_conversation(scope, project)
      copy_id = agent.working_copy_id

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      open_team_panel(view)

      assert has_element?(
               view,
               "[data-test='team-copy'][data-working-copy-id='#{copy_id}'] [data-test='copy-preview-marker'][data-state='unchecked']"
             )

      assert has_element?(
               view,
               "[data-test='team-copy'][data-working-copy-id='#{copy_id}'] [data-test='copy-harness-marker'][data-state='unattached']"
             )

      view
      |> element(
        "[data-test='team-copy'][data-working-copy-id='#{copy_id}'] [data-test='team-copy-open']"
      )
      |> render_click()

      modal = "[data-test='copy-modal']"

      assert has_element?(
               view,
               "#{modal} [data-test='working-copy'][data-working-copy-id='#{copy_id}']"
             )

      assert has_element?(
               view,
               "#{modal} a[data-test='copy-modal-show'][href='/app/projects/#{project.id}/working-copies/#{copy_id}']"
             )

      assert has_element?(
               view,
               "#{modal} a[data-test='copy-modal-status'][href='/app/projects/#{project.id}/working-copies/#{copy_id}/status']"
             )

      render_click(view, "close_copy", %{})
      refute has_element?(view, modal)
    end
  end

  describe "an agent's task" do
    defp active_task(scope, agent, attrs) do
      {:ok, _agent} =
        CodeMySpec.TaskOwner.add_task(
          scope,
          agent,
          Map.merge(
            %{id: Ecto.UUID.generate(), status: :active, started_at: DateTime.utc_now()},
            Map.new(attrs)
          )
        )
    end

    test "clicking it shows the directive the next-task page gives for its requirement", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      project_scope = %{scope | active_project_id: project.id, active_project: project}
      story = CodeMySpec.StoriesFixtures.story_fixture(project_scope, %{title: "Pay by card"})
      {agent, conversation} = agent_with_conversation(scope, project, %{story_id: story.id})

      vantage = %{project_scope | active_working_copy_id: agent.working_copy_id}
      :ok = RequirementGraph.settle(vantage)
      {{nodes, _edges}, _at} = RequirementGraph.cached_graph(vantage)

      node =
        Enum.find(
          nodes,
          &(&1.entity_type == "story" and to_string(&1.entity_id) == to_string(story.id))
        )

      active_task(project_scope, agent, requirement_name: node.name, story_id: story.id)

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      open_team_panel(view)

      view
      |> element(
        "[data-test='team-agent'][data-agent-id='#{agent.id}'] [data-test='team-agent-task']"
      )
      |> render_click()

      render_async(view)

      assert has_element?(view, "[data-test='task-modal']", node.name)
      assert has_element?(view, "[data-test='task-modal-directive']")

      render_click(view, "close_task", %{})
      refute has_element?(view, "[data-test='task-modal']")
    end

    test "a task whose requirement the graph no longer holds says so", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      project_scope = %{scope | active_project_id: project.id, active_project: project}
      {agent, conversation} = agent_with_conversation(scope, project)

      active_task(project_scope, agent, requirement_name: "no_such_requirement")

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      open_team_panel(view)

      view
      |> element(
        "[data-test='team-agent'][data-agent-id='#{agent.id}'] [data-test='team-agent-task']"
      )
      |> render_click()

      render_async(view)
      assert has_element?(view, "[data-test='task-modal-gone']")
    end
  end

  describe "a story's progress pie" do
    # The pie counts the slice the working copy status page draws, so the two
    # cannot disagree: whatever `Requirements.story_graph/2` returns for the
    # story at the agent's copy is what the pie reads.
    defp slice_progress(scope, project, story) do
      scope = %{scope | active_project_id: project.id, active_project: project}
      {:ok, graph} = CodeMySpec.Requirements.story_graph(scope, story.id)
      RequirementStoryGraph.progress(graph)
    end

    test "shows the story slice's satisfied of total and follows a graph update", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      alias CodeMySpec.Requirements.Node
      require Ecto.Query

      project_scope = %{scope | active_project_id: project.id, active_project: project}
      story = CodeMySpec.StoriesFixtures.story_fixture(project_scope)

      {agent, conversation} = agent_with_conversation(scope, project, %{story_id: story.id})

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      open_team_panel(view)

      header = "header [data-test='story-progress']"

      row =
        "[data-test='team-copy'][data-working-copy-id='#{agent.working_copy_id}'] [data-test='story-progress']"

      render_async(view)
      {done, total} = slice_progress(scope, project, story)
      assert has_element?(view, header <> "[data-done='#{done}'][data-total='#{total}']")
      assert has_element?(view, row <> "[data-done='#{done}'][data-total='#{total}']")

      before = {done, total}

      Node
      |> Ecto.Query.where([n], n.story_id == ^story.id and not n.satisfied)
      |> Repo.update_all(set: [satisfied: true])

      send(view.pid, {:graph_updated, project.id})
      render(view)
      render_async(view)

      {done, total} = slice_progress(scope, project, story)
      assert {done, total} != before or total == 0
      assert has_element?(view, header <> "[data-done='#{done}'][data-total='#{total}']")
      assert has_element?(view, row <> "[data-done='#{done}'][data-total='#{total}']")
    end

    test "clicking the pie opens the story's requirements graph", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      project_scope = %{scope | active_project_id: project.id, active_project: project}
      story = CodeMySpec.StoriesFixtures.story_fixture(project_scope, %{title: "Pay by card"})
      {_agent, conversation} = agent_with_conversation(scope, project, %{story_id: story.id})

      {:ok, view, _html} = live(conn, show_path(project, conversation))

      view |> element("header [data-test='story-progress']") |> render_click()

      assert has_element?(view, "[data-test='story-graph-modal']", "Pay by card")

      render_click(view, "close_story_graph", %{})
      refute has_element?(view, "[data-test='story-graph-modal']")
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

  # John, 2026-10-19: the team panel has to say who is internal and who is
  # external, and on what. Alloy agents can run over Claude Code too.
  describe "the team panel's agent kind" do
    test "an Alloy agent reads as internal with its provider, not its model", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {agent, conversation} =
        agent_with_conversation(scope, project, %{provider: "claude-code", model: "sonnet"})

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      open_team_panel(view)

      kind = "[data-test='team-agent'][data-agent-id='#{agent.id}'] [data-test='team-agent-kind']"
      assert has_element?(view, "#{kind}[data-external='false'][data-provider='claude-code'] svg")
      refute has_element?(view, kind, "sonnet")
    end

    test "a terminal session reads as external", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {agent, conversation} =
        agent_with_conversation(scope, project, %{
          engine: :claude_code,
          provider: "claude-code",
          engine_session_id: "cc-#{System.unique_integer([:positive])}"
        })

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      open_team_panel(view)

      kind = "[data-test='team-agent'][data-agent-id='#{agent.id}'] [data-test='team-agent-kind']"
      assert has_element?(view, "#{kind}[data-external='true']")
    end
  end

  describe "the team panel's agent state" do
    test "a starting agent shows the starting mark and no liveness word", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {agent, conversation} = agent_with_conversation(scope, project)

      {:ok, view, _html} = live(conn, show_path(project, conversation))
      open_team_panel(view)

      row = "[data-test='team-agent'][data-agent-id='#{agent.id}']"
      assert has_element?(view, "#{row} [data-test='team-agent-starting']")
      refute has_element?(view, row, "Starting")
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
