defmodule CodeMySpecWeb.AgentConversationLive.Show do
  @moduledoc """
  One agent session's conversation — the turns it took, the tools it called and
  what they returned, with sub-agent turns attributed to the sub-agent via
  `agent_role`. New turns arrive live while the agent runs, with no reload.

  The only place a person types at an agent; other pages link here rather than
  grow a second transcript. The composer appears only when this
  conversation's own agent can take a message (`talkable?/2`): a box over a
  stopped agent would swallow the text.

  One page is one conversation, named by `?conversation=`; none means the
  project's main agent. `Index` lists them. Separate from `InboxLive`: agent
  conversations never appear in `Conversations.list_conversations/1` or count
  toward `Conversations.unread_count/1`.

  An empty transcript means "nothing yet" for an agent conversation (the agent
  streams its own steps) and "turns were not recorded" only for a recorded lane
  with no agent (`emptiness/2`).

  See knowledge/web, "Agent conversation".
  """

  use CodeMySpecWeb, :live_view

  import CodeMySpecWeb.Markdown, only: [md_html: 1]
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Drafts
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Conversations.Reads
  alias CodeMySpec.Epics
  alias CodeMySpec.Issues
  alias CodeMySpec.Notifications
  alias CodeMySpec.Problems
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.Bands
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.StoryGraph, as: RequirementStoryGraph
  alias CodeMySpec.ScreenState
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Utils
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces.PreviewAddress
  alias CodeMySpecWeb.ChatComponents
  alias CodeMySpecWeb.MainAgentConversation
  alias CodeMySpecWeb.PermissionComponents
  alias CodeMySpecWeb.ProblemCharts
  alias CodeMySpecWeb.ProjectTimeline
  alias CodeMySpecWeb.StoryProgress
  alias CodeMySpecWeb.TaskComponents
  alias CodeMySpecWeb.WorkingCopyLive.Components.Copy, as: CopyComponents
  alias CodeMySpecWeb.WorkingCopyLive.Components.StoryGraph, as: StoryGraphComponents
  alias CodeMySpecWeb.WorkingCopyLive.Liveness
  alias CodeMySpecWeb.WorkingCopyLive.Rows
  alias CodeMySpecWeb.WorkingCopyLive.StoryGraph, as: WorkingCopyStoryGraph
  alias CodeMySpecWeb.WorkingCopyLive.StoryGraphLayout
  alias LiveFlow.Changes.NodeChange
  alias Phoenix.LiveView.JS

  import CodeMySpecWeb.ConversationPanels, only: [panels: 1]

  @impl true
  # Defaults here, not on the params path, whose error branch assigns almost
  # nothing; a missing key would crash the render.
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, analysis_running: [], agent_writing: nil)}

  # One page of turns (`Conversations`' default page size); the loader compares
  # against it to decide whether more sit above.
  @page 50

  defp messages_for(nil), do: []
  defp messages_for(conversation), do: Conversations.list_messages(conversation, limit: @page)

  # `PortableHost` assigns `:project` on `handle_params`, so this cannot run in
  # `mount`. The first clause redirects the old path-style conversation link
  # (push notifications, bookmarks) to the canonical query-string address.
  @impl true
  def handle_params(%{"conversation_id" => id, "project_id" => project_id}, _uri, socket) do
    {:noreply,
     push_navigate(socket,
       to: ~p"/app/projects/#{project_id}/agent-conversation?#{[conversation: id]}"
     )}
  end

  def handle_params(params, _uri, socket) do
    case socket.assigns[:project] do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That project is not yours, or does not exist.")
         |> push_navigate(to: ~p"/app/projects")}

      project ->
        {:noreply, mount_conversation(socket, project, params["conversation"])}
    end
  end

  defp mount_conversation(socket, project, conversation_id) do
    scope = with_active_project(socket.assigns.current_scope, project)

    # The project's main agent, resolved once per project (`ensure/1` can start
    # one). Keyed per project, not per socket: this LiveView survives navigating
    # between projects.
    socket = assign_main(socket, project, scope)

    conversation = resolve_conversation(scope, conversation_id, socket.assigns.main)
    messages = messages_for(conversation)

    socket = follow_conversation(socket, conversation)

    # Project-wide subscriptions, taken once per connected mount (this runs on
    # every patch).
    if connected?(socket) && !socket.assigns[:watching_project?] do
      # Questions from other copies, for the activity tab. The list topic: the
      # badge topic is halted by `NotificationsHook`, so a clause here would
      # never run.
      case user_id_of(scope) do
        nil ->
          :ok

        user_id ->
          Notifications.subscribe_notifications_list(user_id)
      end

      # This person's screen for this project; per person, not per project.
      ScreenState.subscribe(scope)

      # The team-status panel: every working copy on the project, live.
      Agents.subscribe(scope)
      Agents.subscribe_presence(scope)

      # Analyzer runs in progress, so an idle transcript still shows work. Local
      # and remote runs broadcast here in the same shape.
      Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "analysis:#{scope.active_project_id}")

      # The dynamic panel's content, live. An epic event also switches the panel
      # to the epic view, as `show_in_panel` would.
      Epics.subscribe(scope)
      Stories.subscribe_stories(scope)

      # Story progress pies, which change when the graph is recomputed.
      GraphInputs.subscribe(scope.active_project_id)

      # Every message in the account, for the activity panel's read marks.
      Phoenix.PubSub.subscribe(
        CodeMySpec.PubSub,
        Conversations.inbox_topic(scope.active_account_id)
      )
    end

    mark_seen(socket, scope, conversation)

    # Computed once; `team_status/3` reuses it.
    waiting = waiting_for(scope, conversation)

    socket
    |> assign(:current_scope, scope)
    |> assign(:assigned_modal, nil)
    |> assign(:copy_modal_id, nil)
    |> assign(:task_modal, nil)
    |> assign(:problems_modal, nil)
    |> assign(:graph_modal, nil)
    |> assign(:project, project)
    |> assign(:desktop_setup_results, CodeMySpecWeb.AppLive.DesktopSetupResults.load(project.id))
    |> assign(:conversation, conversation)
    # True once the subscriptions above have run.
    |> assign(:watching_project?, connected?(socket))
    |> assign(:page_title, page_title(project, conversation))
    |> assign(:emptiness, emptiness(conversation, messages))
    |> assign(:questions, questions_for(conversation))
    |> assign(:permissions, permissions_for(conversation))
    |> assign(:analysis_running_since, analysis_running_since(scope, conversation))
    |> assign(:analysis_running, running_analysis(scope, conversation))
    |> assign(:talkable?, talkable?(scope, conversation))
    |> assign(:working?, working?(scope, conversation))
    |> assign(:on?, on?(scope, conversation))
    |> assign(:retired?, retired?(scope, conversation))
    |> assign(:assigned, assigned_to(scope, conversation))
    |> assign(:main_agent?, main_agent?(scope, conversation))
    |> assign(:pending, pending_for(conversation))
    |> assign(:undelivered, undelivered_for(conversation))
    |> assign(:waiting, waiting)
    |> assign(:copies, team_status(scope, project, waiting))
    |> with_chat_states()
    |> assign_new(:firing?, fn -> false end)
    # Screen state uses `assign_new`: this runs on every PubSub update, and
    # `assign/3` would undo what the person just did. `:screen`, not `:layout`
    # (reserved by Phoenix). Narrow until the client reports: wide on a phone
    # overflows, narrow on a desk is merely narrow.
    |> assign_new(:screen, fn -> :narrow end)
    # Seeded from the stored screen, then owned by the socket.
    |> assign_new(:open_panels, fn -> stored_panels(scope) end)
    |> assign_new(:dynamic_view, fn -> ScreenState.get(scope).dynamic_view end)
    |> assign_new(:dynamic_story_id, fn -> ScreenState.get(scope).dynamic_story_id end)
    |> assign_new(:offer, fn -> offer_of(ScreenState.get(scope)) end)
    # `assign`, not `assign_new`: a preview that comes up should appear live.
    |> assign_preview(scope)
    |> assign_new(:draft, fn -> "" end)
    |> assign_more_above(messages, @page)
    |> assign_turns(messages)
    |> assign_dynamic()
  end

  # Keyed on the project it was resolved for, so navigating to another asks again.
  defp assign_main(socket, project, scope) do
    socket
    |> assign_new(:main_for, fn -> project.id end)
    |> then(&main_for_this_project(&1, project, scope))
  end

  defp main_for_this_project(%{assigns: %{main_for: id}} = socket, %{id: id}, scope),
    do: assign_new(socket, :main, fn -> MainAgentConversation.ensure(scope) end)

  defp main_for_this_project(socket, project, scope) do
    socket
    |> assign(:main_for, project.id)
    |> assign(:main, MainAgentConversation.ensure(scope))
  end

  # No `?conversation=` opens the main agent's. A named one that does not
  # resolve is nil, never a substitute.
  # See knowledge/web, "Agent conversation".
  defp resolve_conversation(_scope, nil, main), do: main_conversation(main)

  defp resolve_conversation(scope, conversation_id, _main),
    do: Conversations.get_agent_conversation_by_id(scope, conversation_id)

  defp main_conversation({:ok, _agent, conversation}), do: conversation
  defp main_conversation(_error), do: nil

  defp main_copy_id({:ok, agent, _conversation}), do: agent.working_copy_id
  defp main_copy_id(_error), do: nil

  # Working once its process is alive (`Agents.Presence`); until then, getting
  # ready.
  defp main_summary({:ok, agent, _conversation}) do
    if Agents.present?(agent.project_id, agent),
      do: "Working on your project. Its steps appear below as it takes them.",
      else: "Getting ready. It will start work as soon as its machine picks it up."
  end

  defp main_summary(_error), do: ""

  # Subscribe to the conversation on screen and unsubscribe from the previous
  # one: switching is a patch, and a leaked topic appends another agent's turns
  # here.
  defp follow_conversation(socket, conversation) do
    previous = socket.assigns[:conversation]

    case {connected?(socket), previous, conversation} do
      {false, _, _} ->
        socket

      # Same conversation re-resolved; resubscribing would double every turn.
      {true, %{id: id}, %{id: id}} ->
        socket

      {true, previous, conversation} ->
        previous && Conversations.unsubscribe_conversation(previous.id)
        previous && Drafts.unsubscribe(previous.id)
        conversation && Conversations.subscribe_conversation(conversation.id)
        # Subscribed before reading, so a draft that moves on in between
        # arrives rather than being missed.
        conversation && Drafts.subscribe(conversation.id)

        # The draft belongs to the agent, not the screen: clear it on switch.
        socket
        |> assign(:draft, "")
        |> assign(:agent_writing, conversation && Drafts.get(conversation.id))
    end
  end

  # The preview address comes off the main working copy (none, no preview); its
  # state is asked for, not inferred from the address.
  defp assign_preview(socket, scope) do
    src = WorkingCopies.preview_url(scope)
    status = WorkingCopies.preview_status(scope)

    socket
    |> assign(:preview_src, src)
    |> assign(:preview_state, preview_state(src, status))
    |> assign(
      :preview_extra_frame_origins,
      PreviewAddress.extra_frame_origins(scope.active_project)
    )
  end

  # Never reported is `:starting`, not `:running`: framing a URL before anything
  # answers shows a blank pane or Cloudflare's error page, which reads as broken.
  defp preview_state(nil, _status), do: :absent
  defp preview_state(_src, "serving"), do: :running
  defp preview_state(_src, "erroring"), do: :broken
  defp preview_state(_src, "down"), do: :down
  defp preview_state(_src, _never_reported), do: :starting

  # Stored as strings, atoms in the socket.
  defp stored_panels(scope) do
    scope
    |> ScreenState.get()
    |> Map.get(:open_panels, [])
    |> Enum.map(&to_panel/1)
    |> Enum.reject(&is_nil/1)
  end

  defp to_panel("preview"), do: :preview
  defp to_panel("dynamic"), do: :dynamic
  defp to_panel("activity"), do: :activity
  defp to_panel(_other), do: nil

  # The view the agent offered, or nil.
  defp offer_of(%{offered_view: nil}), do: nil
  defp offer_of(%{offered_view: view, offered_story_id: id}), do: %{view: view, story_id: id}
  defp offer_of(_screen), do: nil

  # Saved on every change. Failure is silent: losing a layout is better than
  # crashing the conversation beside it.
  defp remember(socket) do
    ScreenState.put(socket.assigns.current_scope, %{
      open_panels: Enum.map(socket.assigns.open_panels, &to_string/1),
      dynamic_view: socket.assigns.dynamic_view,
      dynamic_story_id: socket.assigns.dynamic_story_id
    })

    socket
  end

  defp take_offer(%{assigns: %{offer: nil}} = socket), do: socket

  defp take_offer(%{assigns: %{offer: offer}} = socket) do
    socket
    |> assign(:dynamic_view, offer.view)
    |> assign(:dynamic_story_id, offer.story_id)
    |> assign(:offer, nil)
    |> assign_dynamic()
  end

  defp assign_dynamic(socket) do
    scope = socket.assigns.current_scope

    case socket.assigns.dynamic_view do
      "story" ->
        story =
          socket.assigns.dynamic_story_id &&
            Stories.get_story(scope, socket.assigns.dynamic_story_id)

        socket
        |> assign(:dynamic_stories, [])
        |> assign(:dynamic_story, story)
        |> assign(:dynamic_epics, [])

      "epics" ->
        socket
        |> assign(:dynamic_stories, [])
        |> assign(:dynamic_story, nil)
        |> assign(:dynamic_epics, safe_epics(scope))

      _ ->
        socket
        |> assign(:dynamic_stories, safe_stories(scope))
        |> assign(:dynamic_story, nil)
        |> assign(:dynamic_epics, [])
    end
  end

  # A panel that cannot list should not take the transcript down with it.
  defp safe_epics(scope) do
    Utils.rescued("AgentConversationLive.safe_epics", [], fn -> Epics.list_epics(scope) end)
  end

  defp safe_stories(scope) do
    Utils.rescued("AgentConversationLive.safe_stories", [], fn -> Stories.list_stories(scope) end)
  end

  # Why this transcript is empty. `:gap` (turns lost) only for recorded lanes,
  # keyed by session; `:nothing_yet` for an agent that has not taken a step.
  defp emptiness(nil, _messages), do: :none
  defp emptiness(_conversation, [_ | _]), do: :none
  defp emptiness(%{agent_id: agent_id}, []) when is_binary(agent_id), do: :nothing_yet
  defp emptiness(_conversation, []), do: :gap

  # Whether this agent keeps going when its turn ends: the play control, per
  # agent (the working copy page moves every role at once).
  defp working?(scope, %{agent_id: agent_id}) when is_binary(agent_id) do
    match?({:ok, %{continuous: true}}, Agents.fetch_agent(scope, agent_id))
  end

  defp working?(_scope, _conversation), do: false

  # On is intent (neither off nor retired), not whether the process is up.
  defp on?(scope, %{agent_id: agent_id}) when is_binary(agent_id) do
    match?({:ok, %Agent{off_at: nil, retired_at: nil}}, Agents.fetch_agent(scope, agent_id))
  end

  defp on?(_scope, _conversation), do: false

  defp assigned_to(scope, %{agent_id: agent_id}) when is_binary(agent_id) do
    case Agents.fetch_agent(scope, agent_id) do
      {:ok, agent} -> assignments(scope, agent)
      _ -> []
    end
  end

  defp assigned_to(_scope, _conversation), do: []

  # The issue first: it takes priority over the story in dispatch.
  defp assignments(scope, %Agent{} = agent) do
    Enum.reject([assigned_issue(scope, agent), assigned_story(scope, agent)], &is_nil/1)
  end

  defp assigned_modal(scope, "story", number) do
    case Stories.get_story_by_number(scope, number) do
      nil ->
        nil

      story ->
        %{
          kind: :story,
          story: story,
          path: ~p"/app/projects/#{scope.active_project_id}/stories/#{story.number}"
        }
    end
  end

  defp assigned_modal(scope, "issue", id) do
    case Issues.get_issue(scope, id) do
      nil ->
        nil

      issue ->
        %{
          kind: :issue,
          issue: issue,
          path: ~p"/app/projects/#{scope.active_project_id}/issues/#{issue.id}"
        }
    end
  end

  defp assigned_modal(_scope, _kind, _key), do: nil

  defp assigned_issue(_scope, %Agent{issue_id: nil}), do: nil

  defp assigned_issue(scope, %Agent{issue_id: id}) do
    case Issues.get_issue(scope, id) do
      nil ->
        nil

      issue ->
        %{
          kind: :issue,
          ref: String.slice(issue.id, 0, 8),
          key: issue.id,
          title: issue.title,
          path: ~p"/app/projects/#{scope.active_project_id}/issues/#{issue.id}"
        }
    end
  end

  # Every pie on the page: the header's, and one per copy holding a story.
  defp story_progress_ids(assigns) do
    header = if Enum.any?(assigns.assigned, &(&1.kind == :story)), do: ["story-progress-header"]

    rows =
      for %{assignment: %{kind: :story}} = copy <- assigns.copies,
          do: "story-progress-copy-#{copy.row.harness.id}"

    List.wrap(header) ++ rows
  end

  defp assigned_story(scope, %Agent{story_id: id}), do: story_assignment(scope, id)

  defp story_assignment(_scope, nil), do: nil

  defp story_assignment(scope, id) do
    case Stories.get_story(scope, id) do
      nil ->
        nil

      story ->
        %{
          kind: :story,
          story_id: story.id,
          working_copy_id: story.working_copy_id,
          ref: "##{story.number}",
          key: story.number,
          title: story.title,
          path: ~p"/app/projects/#{scope.active_project_id}/stories/#{story.number}"
        }
    end
  end

  # A retired agent has no power button: it can never be turned on again.
  defp retired?(scope, %{agent_id: agent_id}) when is_binary(agent_id) do
    match?({:ok, %Agent{retired_at: %DateTime{}}}, Agents.fetch_agent(scope, agent_id))
  end

  defp retired?(_scope, _conversation), do: false

  defp flip_power(scope, agent_id, true, params),
    do:
      Agents.turn_off_agent(scope, agent_id,
        by: Agents.actor(scope),
        reason: params["reason"]
      )

  defp flip_power(scope, agent_id, false, _params), do: Agents.turn_on_agent(scope, agent_id)

  defp power_flash({:ok, _agent}, _was, true), do: {:info, "Agent turned on."}
  defp power_flash({:ok, _agent}, _was, false), do: {:info, "Agent turned off."}

  defp power_flash(_error, same, same),
    do: {:error, "That agent could not be switched. Try again."}

  defp power_flash(_error, _was, true),
    do: {:error, "Agent turned on, but it could not start yet."}

  defp power_flash(_error, _was, false),
    do: {:error, "Agent turned off, but its machine could not be reached to end it."}

  # Keeps the header's controls in step when the team panel toggled this
  # conversation's agent.
  defp sync_header_state(socket, agent) do
    conversation = socket.assigns.conversation

    if conversation && conversation.agent_id == agent.id do
      socket
      |> assign(:working?, agent.continuous == true)
      |> assign(:on?, is_nil(agent.off_at))
      |> assign(:retired?, not is_nil(agent.retired_at))
    else
      socket
    end
  end

  # Answerable when this conversation's own agent is neither off nor retired.
  # Reachability is not asked: a message to an unreachable machine must be
  # accepted and reported undelivered, which needs the box.
  defp talkable?(_scope, nil), do: false

  defp talkable?(scope, %{agent_id: agent_id}) when is_binary(agent_id) do
    match?(
      {:ok, agent} when agent.off_at == nil and agent.retired_at == nil,
      Agents.fetch_agent(scope, agent_id)
    )
  end

  defp talkable?(_scope, _conversation), do: false

  # Whether this thread is the project's own agent: the main role on the main
  # copy, on duty, whatever its engine. Not `Agents.main_agent/1`, which also
  # asks whether a terminal agent's process is connected — the right question
  # for who to dispatch to, and the wrong one for what this page shows: a Claude
  # Code main with its terminal closed is still the project's agent.
  defp main_agent?(scope, %{agent_id: agent_id}) when is_binary(agent_id) do
    with %{id: copy_id} <- WorkingCopies.main(scope),
         {:ok, %Agent{role: :main, working_copy_id: ^copy_id, off_at: nil, retired_at: nil}} <-
           Agents.fetch_agent(scope, agent_id) do
      true
    else
      _ -> false
    end
  end

  defp main_agent?(_scope, _conversation), do: false

  # Messages still waiting to be handed over, read from the record so they
  # survive a reload.
  defp pending_for(nil), do: []
  defp pending_for(conversation), do: Agents.Mailbox.waiting_messages(conversation)

  defp undelivered_for(nil), do: []
  defp undelivered_for(conversation), do: Agents.Mailbox.undelivered_messages(conversation)

  # Each pending row, with the run of promotion notices it folds (empty when it
  # is not one). A run is one row; each notice in it can still be taken back.
  defp pending_runs(pending) do
    pending
    |> Enum.chunk_by(&ChatComponents.routine_notice?/1)
    |> Enum.flat_map(fn [first | _] = run ->
      if ChatComponents.routine_notice?(first),
        do: [{first, run}],
        else: Enum.map(run, &{&1, []})
    end)
  end

  attr :message, :any, required: true

  defp withdraw_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="withdraw_message"
      phx-value-ref={@message.delivery_ref}
      data-test="agent-withdraw-message"
      class="btn btn-xs btn-ghost"
    >
      Take it back
    </button>
    """
  end

  attr :message, :any, required: true

  # One line until asked: a brief can run to a screen, and the queue sits above
  # the composer. Toggled client-side so a patch does not fold it back up.
  defp queued_text(assigns) do
    assigns =
      assign(assigns,
        id: "queued-#{assigns.message.delivery_ref}",
        text: Message.text(assigns.message)
      )

    ~H"""
    <div class="flex min-w-0 flex-1 items-baseline gap-2">
      <span id={@id} data-test="queued-message-text" class="min-w-0 flex-1 truncate">
        {@text}
      </span>
      <button
        :if={long?(@text)}
        type="button"
        data-test="queued-message-read-more"
        class="link link-hover shrink-0 opacity-70"
        phx-click={
          JS.toggle_class("truncate whitespace-pre-wrap break-words", to: "##{@id}")
          |> JS.toggle(to: "##{@id}-more")
          |> JS.toggle(to: "##{@id}-less")
        }
      >
        <span id={"#{@id}-more"}>Read more</span>
        <span id={"#{@id}-less"} class="hidden">Show less</span>
      </button>
    </div>
    """
  end

  defp long?(text), do: String.contains?(text, "\n") or String.length(text) > 100

  attr :message, :any, required: true

  # Stops a busy agent's turn so this is its next message.
  defp send_now_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="send_now"
      phx-value-ref={@message.delivery_ref}
      data-test="agent-send-now"
      class="btn btn-xs btn-ghost"
    >
      Send now
    </button>
    """
  end

  defp page_title(project, nil), do: "#{project.name} · Agent conversation"

  defp page_title(project, conversation),
    do: "#{project.name} · #{Conversations.display_name(conversation)}"

  # The id stays visible beside the name: the name is a handle someone chose,
  # and the session id is what appears in the logs you would go read next.
  defp short_session(%{session_external_id: id}) when is_binary(id) do
    case String.split(id, "-") do
      [first | _] when byte_size(first) == 8 -> first
      _ -> String.slice(id, 0, 16)
    end
  end

  defp short_session(_), do: ""

  # Both fields together: conversation lookups scope on `active_project_id`,
  # and a stale one would read another project's turns.
  defp with_active_project(scope, project),
    do: %{scope | active_project: project, active_project_id: project.id}

  @impl true
  def handle_event("set_read", %{"id" => id, "read" => read}, socket) do
    Reads.set_read(socket.assigns.current_scope, id, read == "true")
    {:noreply, with_chat_states(socket)}
  end

  # A story's pie opens the requirements graph the working copy status page
  # draws, built the same way, over the cockpit. From the timeline's stories
  # chart it also carries the chart's stories, in its order, for the slider.
  def handle_event("show_story_graph", %{"story-id" => story_id} = params, socket) do
    scope = %{socket.assigns.current_scope | active_working_copy_id: blank_nil(params["copy-id"])}

    case Stories.get_story(scope, story_id) do
      nil ->
        {:noreply, socket}

      story ->
        slider = if params["from"] == "chart", do: chart_stories(socket)
        {:noreply, open_story_graph(socket, scope, story, slider)}
    end
  end

  # The slider moved: the same modal, the story at that position.
  def handle_event("slide_story", %{"index" => index}, socket) do
    with %{slider: [_ | _] = stories} <- socket.assigns[:graph_modal],
         {i, ""} <- Integer.parse(index),
         %{id: id, working_copy_id: copy_id} <- Enum.at(stories, i),
         scope = %{socket.assigns.current_scope | active_working_copy_id: copy_id},
         %Story{} = story <- Stories.get_story(scope, id) do
      {:noreply, open_story_graph(socket, scope, story, stories)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_story_graph", _params, socket),
    do: {:noreply, assign(socket, :graph_modal, nil)}

  # The modal's canvas follows the status page: the hook measures each card,
  # then the graph is arranged with those sizes and fitted. Fitting before the
  # cards were measured gave a zero-size view (scale 0).
  def handle_event("lf:request_layout", _params, socket), do: {:noreply, arrange_graph(socket)}

  def handle_event("lf:node_change", %{"changes" => changes}, socket) do
    case socket.assigns[:graph_modal] do
      %{flow: flow} = modal when not is_nil(flow) ->
        changes = Enum.filter(changes, &(&1["type"] in ["position", "dimensions", "select"]))
        modal = %{modal | flow: NodeChange.apply_changes(flow, changes)}
        socket = assign(socket, :graph_modal, modal)
        {:noreply, if(modal[:needs_layout], do: arrange_graph(socket), else: socket)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("lf:viewport_change", params, socket) do
    case socket.assigns[:graph_modal] do
      %{flow: flow} = modal when not is_nil(flow) ->
        {:noreply,
         assign(socket, :graph_modal, %{
           modal
           | flow: LiveFlow.State.update_viewport(flow, params)
         })}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("lf:" <> _event, _params, socket), do: {:noreply, socket}

  # A story or issue opens over the cockpit rather than navigating away from it.
  def handle_event("show_assigned", %{"kind" => kind, "key" => key}, socket) do
    {:noreply, assign(socket, :assigned_modal, assigned_modal(socket.assigns.scope, kind, key))}
  end

  def handle_event("close_assigned", _params, socket),
    do: {:noreply, assign(socket, :assigned_modal, nil)}

  def handle_event("show_copy", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :copy_modal_id, id)}

  def handle_event("close_copy", _params, socket),
    do: {:noreply, assign(socket, :copy_modal_id, nil)}

  # The agent's active tasks as it was handed them, read off the LiveView
  # process: the directive is a graph read at the agent's copy.
  def handle_event("show_task", %{"agent-id" => agent_id}, socket) do
    scope = socket.assigns.current_scope

    case Agents.fetch_agent(scope, agent_id) do
      {:ok, agent} ->
        tasks = Enum.filter(agent.tasks || [], &(&1.status == :active))
        vantage = %{scope | active_working_copy_id: agent.working_copy_id}

        {:noreply,
         socket
         |> assign(:task_modal, %{title: task_title(agent, tasks), directive: :loading})
         |> start_async(:task_modal, fn -> task_directive(vantage, tasks) end)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_task", _params, socket),
    do: {:noreply, assign(socket, :task_modal, nil)}

  # Only a copy on this project: the id arrives from the client.
  def handle_event("show_problems", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.copies, &(&1.row.harness.id == id)) do
      nil ->
        {:noreply, socket}

      copy ->
        scope = %{socket.assigns.current_scope | active_working_copy_id: id}

        {:noreply,
         assign(socket, :problems_modal, %{
           counts: Problems.top_files(scope, 10),
           copy_name: copy.row.heading,
           href: ~p"/app/projects/#{socket.assigns.project.id}/problems?harness=#{id}"
         })}
    end
  end

  def handle_event("close_problems", _params, socket),
    do: {:noreply, assign(socket, :problems_modal, nil)}

  # The team panel's row for any agent; the header's clause below acts on this
  # conversation's.
  def handle_event("toggle_agent_working", %{"agent-id" => agent_id}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, current} <- Agents.fetch_agent(scope, agent_id),
         {:ok, agent, outcome} <-
           Agents.set_agent_continuous(scope, agent_id, current.continuous != true) do
      {:noreply,
       socket
       |> sync_header_state(agent)
       |> refresh_team_status()
       |> flash_for_continuous_outcome(agent, outcome)}
    else
      _ -> {:noreply, put_flash(socket, :error, "That agent could not be changed. Try again.")}
    end
  end

  # Put this agent to work or let it stop. Switching on also wakes it (nothing
  # polls); `Agents.set_agent_continuous/3` owns both halves.
  def handle_event("toggle_agent_working", _params, socket) do
    scope = socket.assigns.current_scope
    agent_id = socket.assigns.conversation && socket.assigns.conversation.agent_id

    # The direction comes from the row, never from a possibly stale assign.
    # See knowledge/web, "Lessons".
    with agent_id when is_binary(agent_id) <- agent_id,
         {:ok, current} <- Agents.fetch_agent(scope, agent_id),
         {:ok, agent, outcome} <-
           Agents.set_agent_continuous(scope, agent_id, current.continuous != true) do
      {:noreply,
       socket
       |> assign(:working?, agent.continuous == true)
       |> refresh_team_status()
       |> flash_for_continuous_outcome(agent, outcome)}
    else
      _ -> {:noreply, put_flash(socket, :error, "That agent could not be changed. Try again.")}
    end
  end

  # The team panel's row for any agent, as with `toggle_agent_working`.
  def handle_event("toggle_agent_power", %{"agent-id" => agent_id} = params, socket) do
    scope = socket.assigns.current_scope

    case Agents.fetch_agent(scope, agent_id) do
      {:ok, current} ->
        was_on? = is_nil(current.off_at)
        result = flip_power(scope, agent_id, was_on?, params)

        socket =
          case result do
            {:ok, agent} -> socket |> sync_header_state(agent) |> refresh_team_status()
            _ -> refresh_team_status(socket)
          end

        now_on? = match?({:ok, %{off_at: nil}}, result)
        {kind, text} = power_flash(result, was_on?, now_on?)
        {:noreply, put_flash(socket, kind, text)}

      _ ->
        {:noreply, put_flash(socket, :error, "That agent could not be changed. Try again.")}
    end
  end

  # The header's power button: on turns it off, off turns it on, through the
  # same `Agents` functions the tools use. No confirm; `reason` is optional.
  def handle_event("toggle_agent_power", params, socket) do
    scope = socket.assigns.current_scope
    agent_id = socket.assigns.conversation && socket.assigns.conversation.agent_id

    if is_binary(agent_id) do
      was_on? = socket.assigns.on?
      result = flip_power(scope, agent_id, was_on?, params)
      conversation = socket.assigns.conversation

      # Re-read: intent can land even when the process could not be reached.
      socket =
        socket
        |> assign(:on?, on?(scope, conversation))
        |> assign(:talkable?, talkable?(scope, conversation))
        |> refresh_team_status()

      {kind, text} = power_flash(result, was_on?, socket.assigns.on?)
      {:noreply, put_flash(socket, kind, text)}
    else
      {:noreply, socket}
    end
  end

  # Arms the in-page confirmation rather than acting immediately -- firing
  # retires the agent for good, unlike the power button beside it, which
  # only ever stops and starts the same one.
  def handle_event("fire_agent", _params, socket) do
    {:noreply, assign(socket, :firing?, true)}
  end

  def handle_event("cancel_fire_agent", _params, socket) do
    {:noreply, assign(socket, :firing?, false)}
  end

  def handle_event("confirm_fire_agent", _params, socket) do
    scope = socket.assigns.current_scope
    agent_id = socket.assigns.conversation && socket.assigns.conversation.agent_id

    if is_binary(agent_id) do
      result = Agents.retire_agent(scope, agent_id, by: Agents.actor(scope))

      socket = assign(socket, :firing?, false)

      case result do
        {:ok, agent} ->
          {:noreply,
           socket
           |> sync_header_state(agent)
           |> refresh_team_status()
           |> put_flash(:info, "Agent fired.")}

        {:ok, agent, {:unreachable, _machine}} ->
          {:noreply,
           socket
           |> sync_header_state(agent)
           |> refresh_team_status()
           |> put_flash(
             :info,
             "Agent fired; its machine could not be reached to end the process."
           )}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "That agent could not be fired. Try again.")}
      end
    else
      {:noreply, assign(socket, :firing?, false)}
    end
  end

  def handle_event("send_message", _params, %{assigns: %{talkable?: false}} = socket) do
    # A hidden control is still reachable. Nothing is recorded: the transcript
    # must not claim an absent agent was told something.
    {:noreply, put_flash(socket, :error, "That agent is not running, so nothing was sent.")}
  end

  def handle_event("send_message", %{"message" => message}, socket) do
    # Sending is the one moment the draft clears. `dispatch_message` records the
    # message with its delivery outcome; nothing is written here first.
    socket = assign(socket, :draft, "")

    socket.assigns.current_scope
    |> Agents.dispatch_message(socket.assigns.conversation.agent_id, message, :operator_message)
    |> sent(socket)
  end

  # Takes back a waiting message. Asked of the machine, not cleared locally: the
  # operator must not believe the agent will not see something it will.
  def handle_event("withdraw_message", %{"ref" => ref}, socket) do
    socket.assigns.current_scope
    |> Agents.withdraw_message(socket.assigns.conversation.agent_id, ref)
    |> withdrawn(socket)
  end

  def handle_event("send_now", %{"ref" => ref}, socket) do
    case Agents.send_now(socket.assigns.current_scope, socket.assigns.conversation.agent_id, ref) do
      {:ok, {:not_interruptible, _entry}} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Sent. A terminal session reads it at its next tool call — it can't be interrupted."
         )
         |> assign(:pending, pending_for(socket.assigns.conversation))
         |> assign(:undelivered, undelivered_for(socket.assigns.conversation))}

      {:ok, _entry} ->
        {:noreply,
         socket
         |> assign(:pending, pending_for(socket.assigns.conversation))
         |> assign(:undelivered, undelivered_for(socket.assigns.conversation))}

      {:error, :already_delivered} ->
        {:noreply,
         socket
         |> put_flash(:info, "The agent already has that message.")
         |> assign(:pending, pending_for(socket.assigns.conversation))
         |> assign(:undelivered, undelivered_for(socket.assigns.conversation))}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "That message could not be sent now (#{inspect(reason)}).")}
    end
  end

  # Answers a question beside the work that prompted it.
  def handle_event("answer_question", params, socket) do
    # By the form's own request id, never "the first pending" one.
    case Enum.find(socket.assigns.questions, &(&1.id == params["request_id"])) do
      nil ->
        {:noreply, put_flash(socket, :error, "That question is no longer here.")}

      request ->
        answers = Notifications.collect_answers(request.questions, params)

        {kind, message} =
          ChatComponents.answer_flash(
            Notifications.answer_question_request(request.id, answers,
              answered_by_user_id: socket.assigns.current_scope.user.id
            )
          )

        # Re-fold too: the run was split for the form, which is now gone.
        {:noreply,
         socket
         |> put_flash(kind, message)
         |> assign(:questions, questions_for(socket.assigns.conversation))
         |> assign_turns(socket.assigns.messages)}
    end
  end

  # A permission/tap-out request, resolved by id: several can be pending on one
  # agent.
  def handle_event("approve_permission", %{"id" => id}, socket) do
    resolve_permission(socket, id, "allow")
  end

  def handle_event("deny_permission", %{"id" => id}, socket) do
    resolve_permission(socket, id, "deny")
  end

  # The client reports its width: "a phone shows one panel" is server state, not
  # a media query. `is_number`: `innerWidth` is fractional under browser zoom.
  def handle_event("viewport", %{"width" => width}, socket) when is_number(width) do
    screen = if width < 768, do: :narrow, else: :wide

    socket =
      socket
      |> assign(:screen, screen)
      |> assign(:open_panels, fit(socket.assigns.open_panels, screen))

    # A wide screen that loads with an offer waiting takes it now; the first
    # paint came before the width was known.
    case {screen, socket.assigns.offer} do
      {:wide, offer} when not is_nil(offer) ->
        ScreenState.take(socket.assigns.current_scope)
        {:noreply, take_offer(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_panel", %{"panel" => name}, socket) do
    panel = String.to_existing_atom(name)
    open = socket.assigns.open_panels

    open =
      if panel in open do
        List.delete(open, panel)
      else
        # Narrow holds one panel; two push the conversation off screen.
        case socket.assigns.screen do
          :narrow -> [panel]
          :wide -> open ++ [panel]
        end
      end

    socket = assign(socket, :open_panels, open)

    # Opening the dynamic tab also accepts the agent's offer.
    socket =
      if panel == :dynamic and socket.assigns.offer do
        ScreenState.take(socket.assigns.current_scope)
        take_offer(socket)
      else
        socket
      end

    {:noreply, remember(socket)}
  end

  # Swaps what the one dynamic tab shows; it never becomes another tab.
  def handle_event("dynamic_view", %{"view" => view} = params, socket) do
    {:noreply,
     socket
     |> assign(:dynamic_view, view)
     |> assign(:dynamic_story_id, params["story_id"])
     |> assign_dynamic()
     |> remember()}
  end

  # Kept so the composer survives patches it did not cause (panel toggles).
  def handle_event("draft", %{"message" => message}, socket) do
    {:noreply, assign(socket, :draft, message)}
  end

  # Older turns when the operator reaches the top. Prepends and re-folds the
  # whole list: an older page can join a run already on screen.
  def handle_event("load_older", _params, %{assigns: %{conversation: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("load_older", _params, socket) do
    case socket.assigns.messages do
      [] ->
        {:noreply, socket}

      [oldest | _] ->
        older =
          Conversations.list_messages(socket.assigns.conversation,
            limit: @page,
            before: oldest.inserted_at
          )

        {:noreply,
         socket
         |> assign_more_above(older, @page)
         |> assign_turns(older ++ socket.assigns.messages)}
    end
  end

  defp resolve_permission(socket, id, decision) do
    case Enum.find(socket.assigns.permissions, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      _request ->
        _ =
          Notifications.resolve_permission_request(id, decision, nil,
            answered_by_user_id: socket.assigns.current_scope.user.id
          )

        {:noreply, assign(socket, :permissions, permissions_for(socket.assigns.conversation))}
    end
  end

  # Distinct flashes: switching on with work requests a turn; without, nothing
  # happens yet.
  defp flash_for_continuous_outcome(socket, %Agent{}, :enabled_and_turn_requested) do
    put_flash(
      socket,
      :info,
      "Continuous enabled, and it had work — a turn has been requested; no process was started or restarted."
    )
  end

  defp flash_for_continuous_outcome(socket, %Agent{}, :enabled_without_work) do
    put_flash(
      socket,
      :info,
      "Continuous enabled. Nothing to do right now, so no turn was requested and no process was started or restarted — it will be offered one when that changes."
    )
  end

  defp flash_for_continuous_outcome(socket, %Agent{}, :enabled) do
    put_flash(
      socket,
      :info,
      "Continuous enabled. The agent will take work when runnable; no process was started or restarted."
    )
  end

  defp flash_for_continuous_outcome(socket, %Agent{}, :paused), do: socket

  # A narrow screen holds one panel: a stored layout resolves deterministically
  # (preview if open, else the first).
  defp fit(open, :wide), do: open
  defp fit([], :narrow), do: []
  defp fit(open, :narrow), do: [if(:preview in open, do: :preview, else: hd(open))]

  # Every working copy, its agents, and which have a question waiting. Built on
  # `Rows.list/3` so there is one reading of "what is a working copy".
  defp team_status(scope, project, waiting) do
    now = DateTime.utc_now()
    pending_sessions = MapSet.new(waiting, & &1.session_external_id)

    # Stopped agents stay listed here (this page can stop them); the working
    # copy pages do not pass this.
    problems =
      scope
      |> Problems.counts_by_working_copy()
      |> Enum.group_by(&elem(&1, 0), fn {_copy, source, severity, n} -> {source, severity, n} end)

    scope
    |> Rows.list(project, now, include_stopped?: true)
    |> Enum.map(&copy_status(&1, scope, now, pending_sessions, problems))
  end

  defp copy_status(row, scope, now, pending_sessions, problems) do
    agents =
      Enum.map(row.agents, fn agent ->
        chat = Enum.find(row.chats, &(&1.agent.id == agent.id))
        session = chat && chat.conversation.session_external_id

        %{
          agent: agent,
          chat: chat,
          liveness: Liveness.agent(agent, now),
          question?: not is_nil(session) and MapSet.member?(pending_sessions, session),
          task_label: task_label(scope, agent.id)
        }
      end)
      |> latest_chat_first()

    %{
      row: row,
      agents: agents,
      assignment: copy_assignment(scope, row.harness.id),
      problems: Map.get(problems, row.harness.id, []),
      question?: Enum.any?(agents, & &1.question?),
      empty_seats: empty_seats(row)
    }
  end

  # Work is assigned to the copy and blown through to its agents: its issue
  # bag, which dispatch takes first, or else its team's story.
  defp copy_assignment(scope, copy_id) do
    case Agents.assigned_issues(scope, copy_id) do
      [] -> story_assignment(scope, WorkingCopies.team_story_id(copy_id))
      issues -> issue_bag(issues)
    end
  end

  defp issue_bag(issues) do
    nodes = Requirements.issue_bag_graph(issues).nodes

    %{
      kind: :issues,
      issues: issues,
      progress: {Enum.count(nodes, & &1.satisfied), length(nodes)}
    }
  end

  # Agents whose chat moved most recently on top; agents with no chat last, in
  # the role order `Rows` gave them.
  defp latest_chat_first(agents) do
    Enum.sort_by(agents, &last_message_at/1, &newer_or_equal?/2)
  end

  defp last_message_at(%{chat: %{last_message_at: %DateTime{} = at}}), do: at
  defp last_message_at(_agent), do: nil

  defp newer_or_equal?(_a, nil), do: true
  defp newer_or_equal?(nil, _b), do: false
  defp newer_or_equal?(a, b), do: DateTime.compare(a, b) != :lt

  defp mark_seen(socket, scope, %{id: id}) do
    if connected?(socket), do: Reads.set_read(scope, id, true)
  end

  defp mark_seen(_socket, _scope, nil), do: nil

  # Each panel chat's read mark and latest message, from one query, re-sorted.
  defp with_chat_states(%{assigns: %{copies: copies, current_scope: scope}} = socket)
       when is_list(copies) do
    ids = for copy <- copies, %{chat: %{conversation: %{id: id}}} <- copy.agents, do: id
    states = Reads.states(scope, ids)

    assign(socket, :copies, Enum.map(copies, &apply_chat_states(&1, states)))
  end

  defp with_chat_states(socket), do: socket

  defp apply_chat_states(copy, states) do
    agents =
      copy.agents
      |> Enum.map(&apply_chat_state(&1, states))
      |> latest_chat_first()

    %{copy | agents: agents}
  end

  defp apply_chat_state(%{chat: %{conversation: %{id: id}} = chat} = agent, states) do
    case Map.fetch(states, id) do
      {:ok, %{unread?: unread?, last_message_at: at}} ->
        %{agent | chat: %{chat | last_message_at: at || chat.last_message_at}}
        |> Map.put(:unread?, unread?)

      :error ->
        Map.put(agent, :unread?, false)
    end
  end

  defp apply_chat_state(agent, _states), do: Map.put(agent, :unread?, false)

  # A seat whose agent retired is empty and offers staffing. Each copy's seats
  # are its home roles: main and product on the main copy.
  defp empty_seats(row), do: Agents.empty_seats(row.agents, Agents.home_roles(row.harness))

  # One task names itself; more name only the count.
  defp task_title(agent, [task]), do: "#{agent.role} · #{task.requirement_name}"
  defp task_title(agent, tasks), do: "#{agent.role} · #{length(tasks)} tasks"

  defp task_directive(scope, tasks) do
    case tasks |> Enum.map(&Requirements.task_directive(scope, &1)) |> Enum.reject(&is_nil/1) do
      [] -> nil
      directives -> Enum.join(directives, "\n\n---\n\n")
    end
  end

  defp task_label(scope, agent_id) do
    with {:ok, agent} <- Agents.fetch_agent(scope, agent_id),
         [_ | _] = tasks <- Enum.filter(agent.tasks || [], &(&1.status == :active)) do
      case tasks do
        [task] -> task.requirement_name || "1 task"
        tasks -> "#{length(tasks)} tasks"
      end
    else
      _ -> nil
    end
  end

  # What is waiting on this person anywhere on the project, minus what this
  # thread shows inline.
  defp waiting_for(scope, conversation) do
    case user_id_of(scope) do
      nil ->
        []

      user_id ->
        mine = conversation && conversation.session_external_id

        user_id
        |> Notifications.list_pending_question_requests_for_user()
        |> Enum.reject(&elsewhere?(&1, mine))
    end
  end

  # Either field may be the populated one, depending on how the scope was built.
  defp user_id_of(%{user: %{id: id}}) when not is_nil(id), do: id
  defp user_id_of(%{user_id: id}) when not is_nil(id), do: id
  defp user_id_of(_scope), do: nil

  # A conversation with no session id owns nothing (`nil == nil` is no match).
  defp elsewhere?(_request, nil), do: false
  defp elsewhere?(%{session_external_id: same}, same), do: true
  defp elsewhere?(_request, _mine), do: false

  # Only pending questions render as cards; answered ones stay as their tool call
  # blocks. `QuestionLive.Show` still renders the answered state.
  defp pending(questions), do: Enum.filter(questions, &(&1.status == "pending"))

  # Questions anchored at any message in this group (a group's id is only its
  # first message's).
  defp questions_at(questions, item) do
    ids = MapSet.new(item.messages, & &1.id)

    questions
    |> pending()
    |> Enum.filter(&MapSet.member?(ids, &1.conversation_message_id))
  end

  # Pending questions whose anchor is not on this page.
  defp unanchored_questions(questions, items) do
    shown = items |> Enum.flat_map(& &1.messages) |> MapSet.new(& &1.id)

    questions
    |> pending()
    |> Enum.reject(&MapSet.member?(shown, &1.conversation_message_id))
  end

  # Permission requests have no message anchor, so all pending ones go here.
  defp unanchored_permissions(permissions), do: pending(permissions)

  defp analysis_label([one]), do: "Running #{one}…"

  defp analysis_label(sources),
    do: "Running #{Enum.join(sources, ", ")}…"

  defp waiting_label(questions) do
    case length(pending(questions)) do
      1 -> "A question is waiting on you"
      n -> "#{n} questions are waiting on you"
    end
  end

  # Analyzers mid-run on this agent's checkout, oldest first. Scoped to the
  # copy: an unscoped read answers for every copy of the project.
  defp analysis_running_since(scope, conversation) do
    scope |> at_agents_copy(conversation) |> RunsRepository.running_since()
  end

  defp running_analysis(scope, conversation) do
    scope
    |> at_agents_copy(conversation)
    |> RunsRepository.running_since()
    |> sources_in_order()
  end

  # Accumulated from events (each names its source, status, `started_at` and
  # copy), seeded once at mount. Events about another copy are dropped.
  defp apply_analysis_event(socket, %{working_copy_id: copy} = payload) do
    agents_copy =
      socket.assigns.current_scope
      |> at_agents_copy(socket.assigns.conversation)
      |> Map.get(:active_working_copy_id)

    if copy == agents_copy do
      since = move(socket.assigns[:analysis_running_since] || %{}, payload)

      socket
      |> assign(:analysis_running_since, since)
      |> assign(:analysis_running, sources_in_order(since))
    else
      socket
    end
  end

  defp apply_analysis_event(socket, _payload), do: socket

  defp move(since, %{status: :running, source: source, started_at: started_at}),
    do: Map.put(since, source, started_at)

  defp move(since, %{source: source}), do: Map.delete(since, source)

  defp sources_in_order(since) do
    since
    |> Enum.sort_by(fn {_source, started_at} -> started_at end, DateTime)
    |> Enum.map(fn {source, _started_at} -> to_string(source) end)
  end

  # A conversation with no agent has no checkout: the project-wide answer.
  defp at_agents_copy(scope, %{agent_id: agent_id}) when is_binary(agent_id) do
    case Agents.fetch_agent(scope, agent_id) do
      {:ok, %{working_copy_id: copy_id}} when is_binary(copy_id) ->
        %{scope | active_working_copy_id: copy_id}

      _ ->
        scope
    end
  end

  defp at_agents_copy(scope, _conversation), do: scope

  defp questions_for(nil), do: []

  # By agent for an agent's conversation, by session otherwise; never both.
  defp questions_for(%{agent_id: agent_id}) when is_binary(agent_id),
    do: Notifications.list_question_requests_for_agent(agent_id)

  defp questions_for(conversation),
    do: Notifications.list_question_requests_for_session(conversation.session_external_id)

  defp permissions_for(nil), do: []

  # Same split as `questions_for/1`.
  defp permissions_for(%{agent_id: agent_id}) when is_binary(agent_id),
    do: Notifications.list_permission_requests_for_agent(agent_id)

  # A conversation with no agent asked no permissions.
  defp permissions_for(_conversation), do: []

  # A plain assign, not a stream: folding and nesting a result in its call need
  # neighbours, and `stream_insert/3` cannot regroup. One page, so re-folding on
  # each arrival is cheap.
  # See knowledge/web, "Transcripts".
  defp assign_turns(socket, messages) do
    # A message can reach this list twice: `load_older` prepends a fresh page
    # without checking what is already loaded, and a message whose own
    # `inserted_at` sorts earlier than the page's current oldest (clock skew
    # between writers, or a slow insert landing late) is still appended to
    # the *end* by `upsert/2` when it arrives live, not re-sorted into place.
    # `before:` then asks for exactly that timestamp again. Kept by id, first
    # occurrence: `older ++ messages` puts the correctly-ordered copy first.
    messages = Enum.uniq_by(messages, & &1.id)

    # Pending messages belong in the queue; failed and withdrawn attempts
    # remain audit records, not things the agent has received.
    messages = Enum.filter(messages, &(Map.get(&1, :delivery) in [nil, :delivered]))

    # Break runs at pending questions so each renders where it was asked. Read
    # from the socket: questions change on their own.
    breaks =
      socket.assigns
      |> Map.get(:questions, [])
      |> pending()
      |> MapSet.new(& &1.conversation_message_id)

    {items, results} = ChatComponents.group_turns(messages, breaks)

    socket
    |> assign(:messages, messages)
    |> assign(:items, items)
    |> assign(:results, results)
  end

  # Replace a message already on screen where it stands: a loaded one can still
  # arrive as a broadcast, and a queued one arrives again when delivered.
  defp upsert(messages, %{id: id} = message) do
    if Enum.any?(messages, &(&1.id == id)),
      do: Enum.map(messages, &if(&1.id == id, do: message, else: &1)),
      else: messages ++ [message]
  end

  # A full page back means there is probably more.
  defp assign_more_above(socket, fetched, limit),
    do: assign(socket, :more_above?, length(fetched) >= limit)

  # Nothing appended on success: the message arrives back via `handle_info/2`.
  defp sent({:ok, :started, _message}, socket), do: {:noreply, socket}

  defp sent({:ok, :queued, _message}, socket),
    do:
      {:noreply,
       socket
       |> assign(:pending, pending_for(socket.assigns.conversation))
       |> assign(:undelivered, undelivered_for(socket.assigns.conversation))}

  # Named reasons: each sends the person somewhere different.
  defp sent({:error, reason}, socket),
    do: {:noreply, put_flash(socket, :error, undelivered(reason))}

  # Not a fault: the free allowance on our credential is used up.
  defp undelivered({:turn_cap_reached, cap}),
    do:
      "That is #{cap} messages on our account, which is where the free conversation ends. " <>
        "Connect your own provider in Settings and the agent picks straight back up."

  # No harness holds the copy: either its machine is off or its channel was
  # refused (the server only sees `unauthorized`), so both are named.
  defp undelivered(:harness_not_connected),
    do:
      "That message could not be delivered: nothing here is holding that working " <>
        "copy. Either its machine is not running, or its channel was refused — a " <>
        "copy on a new project usually has no deploy key of its own yet."

  defp undelivered(:not_running),
    do: "That message could not be delivered: the agent is no longer running."

  defp undelivered(reason),
    do: "That message could not be delivered (#{inspect(reason)})."

  defp withdrawn({:ok, message}, socket),
    do: {:noreply, assign(socket, :pending, drop_ref(socket, message.delivery_ref))}

  # The turn ended while the operator reached for the control; say so.
  defp withdrawn({:error, :already_delivered}, socket),
    do:
      {:noreply,
       socket
       |> put_flash(:info, "Too late — the agent has already been given that message.")
       |> assign(:pending, pending_for(socket.assigns.conversation))
       |> assign(:undelivered, undelivered_for(socket.assigns.conversation))}

  defp withdrawn({:error, reason}, socket),
    do:
      {:noreply,
       put_flash(socket, :error, "That message could not be taken back (#{inspect(reason)}).")}

  defp mailbox_label("send_now"), do: "sending now — stopping its turn"
  defp mailbox_label(nil), do: "queued"
  defp mailbox_label(state), do: state

  defp drop_ref(socket, ref), do: Enum.reject(socket.assigns.pending, &(&1.delivery_ref == ref))

  @impl true
  def handle_async(
        :graph_modal,
        {:ok, {flow, progress}},
        %{assigns: %{graph_modal: modal}} = socket
      )
      when is_map(modal) do
    {:noreply,
     socket
     |> assign(
       :graph_modal,
       Map.merge(modal, %{flow: flow, progress: progress, needs_layout: true, loading: false})
     )}
  end

  def handle_async(:graph_modal, {:exit, _reason}, %{assigns: %{graph_modal: modal}} = socket)
      when is_map(modal) do
    {:noreply,
     assign(socket, :graph_modal, %{
       modal
       | error: "Could not load this story’s requirements.",
         loading: false
     })}
  end

  def handle_async(:graph_modal, _result, socket), do: {:noreply, socket}

  def handle_async(:task_modal, {:ok, directive}, %{assigns: %{task_modal: modal}} = socket)
      when is_map(modal),
      do: {:noreply, assign(socket, :task_modal, %{modal | directive: directive})}

  def handle_async(:task_modal, _result, %{assigns: %{task_modal: modal}} = socket)
      when is_map(modal),
      do: {:noreply, assign(socket, :task_modal, %{modal | directive: nil})}

  def handle_async(:task_modal, _result, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:analysis, payload}, socket) do
    {:noreply, apply_analysis_event(socket, payload)}
  end

  # Any chat in the account moved: mark the one on screen read and refresh the
  # panel's read marks.
  def handle_info({:inbox_updated, conversation_id}, socket) do
    conversation = socket.assigns[:conversation]

    if match?(%{id: ^conversation_id}, conversation),
      do: mark_seen(socket, socket.assigns.current_scope, conversation)

    {:noreply, with_chat_states(socket)}
  end

  def handle_info({:new_message, message}, socket) do
    {:noreply,
     socket
     |> assign(:pending, pending_for(socket.assigns.conversation))
     |> assign(:undelivered, undelivered_for(socket.assigns.conversation))
     |> assign_turns(upsert(socket.assigns.messages, message))}
  end

  # The agent's draft so far, or nil once said, for the conversation on screen.
  def handle_info({:agent_draft, conversation_id, text}, socket) do
    case socket.assigns[:conversation] do
      %{id: ^conversation_id} -> {:noreply, assign(socket, :agent_writing, text)}
      _ -> {:noreply, socket}
    end
  end

  # A waiting message settled (picked up or taken back).
  def handle_info({:message_updated, message}, socket) do
    {:noreply,
     socket
     |> assign(:pending, pending_for(socket.assigns.conversation))
     |> assign(:undelivered, undelivered_for(socket.assigns.conversation))
     |> assign_turns(upsert(socket.assigns.messages, message))}
  end

  # Above the catch-all: a clause below it compiles and never runs.
  # An agent's offer is taken at once on a wide screen; a narrow one waits for a
  # tap rather than evict the open panel.
  def handle_info({:screen_changed, screen}, socket) do
    socket = assign(socket, :offer, offer_of(screen))

    case {socket.assigns.screen, socket.assigns.offer} do
      {_screen, nil} ->
        {:noreply, socket}

      {:wide, _offer} ->
        ScreenState.take(socket.assigns.current_scope)
        {:noreply, take_offer(socket)}

      {:narrow, _offer} ->
        {:noreply, socket}
    end
  end

  def handle_info({:notifications_changed}, socket) do
    {:noreply, refresh_team_status(socket)}
  end

  # An epic change refreshes the epics view, or offers it via `ScreenState.show/2`
  # (same offer/take path as `show_in_panel`).
  def handle_info({event, _epic_payload}, socket)
      when event in [:epic_created, :epic_updated, :epic_deleted, :epic_stories_released] do
    if socket.assigns.dynamic_view == "epics" do
      {:noreply, assign_dynamic(socket)}
    else
      {:ok, _screen} = ScreenState.show(socket.assigns.current_scope, %{view: "epics"})
      {:noreply, socket}
    end
  end

  # Refreshes a showing stories view for this project only (the topic is
  # account-wide). No offer: stories is the default view.
  def handle_info({event, %Story{project_id: project_id}}, socket)
      when event in [:created, :updated, :deleted] do
    socket =
      if project_id == socket.assigns.project.id and
           socket.assigns.dynamic_view in ["stories", "story"] do
        assign_dynamic(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  # Presence diffs and agent/session news redraw the team-status panel.
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: handle_info({:agent_started, nil}, socket)

  def handle_info({event, _payload}, socket)
      when event in [
             :agents_reported,
             :agent_started,
             :agent_stopped,
             :agent_turn,
             :session_changed
           ] do
    # The power button follows a turn-off or turn-on made anywhere else.
    scope = socket.assigns.current_scope
    conversation = socket.assigns[:conversation]

    {:noreply,
     socket
     |> assign(:on?, on?(scope, conversation))
     |> assign(:retired?, retired?(scope, conversation))
     |> assign(:assigned, assigned_to(scope, conversation))
     |> assign(:talkable?, talkable?(scope, conversation))
     |> refresh_team_status()}
  end

  def handle_info({:graph_updated, _project_id}, socket) do
    for id <- story_progress_ids(socket.assigns),
        do: send_update(StoryProgress, id: id, refresh: true)

    if socket.assigns.main_agent?,
      do: send_update(ProjectTimeline, id: "project-timeline", refresh: true)

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh_team_status(socket) do
    scope = socket.assigns.current_scope
    waiting = waiting_for(scope, socket.assigns.conversation)

    socket
    |> assign(:waiting, waiting)
    |> assign(:copies, team_status(scope, socket.assigns.project, waiting))
    |> with_chat_states()
    |> refresh_main(scope)
  end

  # Re-resolves `@main` on agent news, so "Getting ready" turns into the running
  # header without a reload. `ensure/1` is idempotent and cheap.
  defp refresh_main(socket, scope) do
    case MainAgentConversation.ensure(scope) do
      {:ok, _agent, _conversation} = main -> assign(socket, :main, main)
      {:error, _reason} -> socket
    end
  end

  # -- Render -----------------------------------------------------------------

  attr :item, :map, required: true

  # The story or issue an agent holds, over the cockpit.
  defp assigned_modal(assigns) do
    ~H"""
    <div
      id="assigned-modal"
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      data-test={"assigned-modal-#{@item.kind}"}
      phx-window-keydown="close_assigned"
      phx-key="Escape"
    >
      <div class="modal-box max-w-2xl max-h-[85dvh] overflow-y-auto">
        <button
          type="button"
          phx-click="close_assigned"
          class="btn btn-ghost btn-sm btn-circle absolute right-2 top-2"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
        <.assigned_body item={@item} />
        <div class="modal-action">
          <.link navigate={@item.path} class="btn btn-sm btn-ghost">
            View full {if @item.kind == :issue, do: "issue", else: "story"}
            <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </.link>
        </div>
      </div>
      <button type="button" class="modal-backdrop" phx-click="close_assigned" aria-label="Close"></button>
    </div>
    """
  end

  attr :item, :map, required: true

  defp assigned_body(%{item: %{kind: :story}} = assigns) do
    ~H"""
    <p class="text-xs uppercase tracking-wide opacity-60">Story {@item.story.number}</p>
    <h2 class="mt-1 pr-8 text-lg font-semibold text-balance">{@item.story.title}</h2>
    <div class="prose prose-sm mt-3 max-w-none prose-p:my-1.5 prose-ul:my-1.5 prose-ol:my-1.5 prose-pre:my-2 prose-headings:mt-4 prose-headings:mb-1">
      {md_html(@item.story.description)}
    </div>
    <h3 class="mt-5 text-sm font-semibold">Acceptance criteria</h3>
    <p :if={@item.story.criteria == []} class="mt-1 text-sm italic opacity-60">None yet.</p>
    <ul class="mt-2 space-y-1.5 text-sm">
      <li :for={c <- @item.story.criteria} class="flex gap-2">
        <.icon
          name={if c.verified, do: "hero-check-circle", else: "hero-minus-circle"}
          class={
            if c.verified,
              do: "mt-0.5 size-4 shrink-0 text-success",
              else: "mt-0.5 size-4 shrink-0 opacity-40"
          }
        />
        <span>{c.description}</span>
      </li>
    </ul>
    """
  end

  defp assigned_body(%{item: %{kind: :issue}} = assigns) do
    ~H"""
    <p class="text-xs uppercase tracking-wide opacity-60">
      Issue {String.slice(@item.issue.id, 0, 8)}
    </p>
    <h2 class="mt-1 pr-8 text-lg font-semibold text-balance">{@item.issue.title}</h2>
    <div class="mt-2 flex flex-wrap gap-2">
      <span class="badge badge-sm">{@item.issue.severity}</span>
      <span class="badge badge-sm badge-ghost">{@item.issue.status}</span>
    </div>
    <div class="prose prose-sm mt-3 max-w-none prose-p:my-1.5 prose-ul:my-1.5 prose-ol:my-1.5 prose-pre:my-2 prose-headings:mt-4 prose-headings:mb-1">
      {md_html(@item.issue.description)}
    </div>
    <div :if={@item.issue.resolution} class="mt-4">
      <h3 class="text-sm font-semibold">Resolution</h3>
      <div class="prose prose-sm mt-1 max-w-none prose-p:my-1.5 prose-ul:my-1.5 prose-ol:my-1.5 prose-pre:my-2 prose-headings:mt-4 prose-headings:mb-1">
        {md_html(@item.issue.resolution)}
      </div>
    </div>
    """
  end

  attr :modal, :map, required: true
  attr :project_id, :string, required: true

  # The requirements graph behind a story's pie, on the status page's own canvas.
  defp graph_modal(assigns) do
    ~H"""
    <div
      id="story-graph-modal"
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      data-test="story-graph-modal"
      phx-window-keydown="close_story_graph"
      phx-key="Escape"
    >
      <div class="modal-box w-11/12 max-w-6xl space-y-3">
        <button
          type="button"
          phx-click="close_story_graph"
          class="btn btn-ghost btn-sm btn-circle absolute right-2 top-2"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
        <div class="flex items-baseline gap-x-3 pr-8">
          <h2 class="min-w-0 truncate text-lg font-semibold">
            Story {@modal.story.number} · {@modal.story.title}
          </h2>
          <span :if={@modal[:progress]} class="text-sm opacity-70" data-test="story-graph-progress">
            {elem(@modal.progress, 0)} of {elem(@modal.progress, 1)} requirements satisfied
          </span>
          <button :if={@modal.flow} phx-click="lf:request_layout" class="btn btn-ghost btn-xs ml-auto">
            Arrange
          </button>
        </div>
        <%!-- The story itself, held to two lines so sliding between stories does
        not move everything under it. --%>
        <p data-test="story-graph-description" class="line-clamp-2 min-h-10 text-sm opacity-70">
          {@modal.story.description}
        </p>
        <form
          :if={@modal[:slider]}
          id="story-graph-slider"
          phx-change="slide_story"
          data-test="story-graph-slider"
          class="flex items-center gap-3"
        >
          <input
            type="range"
            name="index"
            min="0"
            max={length(@modal.slider) - 1}
            value={@modal.index}
            phx-debounce="500"
            class="range range-xs flex-1"
            aria-label="Step through the stories"
          />
          <span class="shrink-0 font-mono text-xs tabular-nums opacity-60">
            {(@modal.index || 0) + 1} / {length(@modal.slider)}
          </span>
        </form>
        <%!-- One fixed-height stage for every state, so loading, empty and
        drawn are the same size and the modal holds still while sliding. --%>
        <div class="relative flex flex-col" style="height: 65vh; min-height: 420px">
          <div
            :if={is_nil(@modal.flow) || @modal.error || map_size(@modal.flow.nodes) == 0}
            class="flex flex-1 items-center justify-center"
          >
            <p :if={@modal.error} role="alert" class="text-error">{@modal.error}</p>
            <span
              :if={is_nil(@modal.flow) and is_nil(@modal.error)}
              data-test="story-graph-loading-empty"
              class="loading loading-spinner loading-md opacity-60"
              aria-label="Loading requirements"
            ></span>
            <p :if={@modal.flow && map_size(@modal.flow.nodes) == 0} class="text-sm opacity-60">
              No published requirements for this story at this working copy.
            </p>
          </div>
          <div
            :if={@modal[:loading] && @modal.flow}
            data-test="story-graph-loading"
            class="pointer-events-none absolute inset-0 z-10 flex items-center justify-center bg-base-100/30"
          >
            <span class="loading loading-spinner loading-md opacity-70" aria-label="Loading"></span>
          </div>
          <StoryGraphComponents.canvas
            :if={@modal.flow && map_size(@modal.flow.nodes) > 0}
            flow={@modal.flow}
            id="story-graph-modal-flow"
            class={if @modal[:needs_layout], do: "flex-1 invisible", else: "flex-1"}
            style="height: 100%"
          />
        </div>
        <div :if={@modal.copy_id} class="flex justify-end">
          <.link
            navigate={~p"/app/projects/#{@project_id}/working-copies/#{@modal.copy_id}/status"}
            class="btn btn-sm btn-ghost"
          >
            Working copy status <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </.link>
        </div>
      </div>
      <button type="button" class="modal-backdrop" phx-click="close_story_graph" aria-label="Close"></button>
    </div>
    """
  end

  defp open_story_graph(socket, scope, story, slider) do
    socket
    |> assign(:graph_modal, %{
      story: story,
      copy_id: scope.active_working_copy_id,
      # Sliding keeps the last story's graph on the canvas until this one is
      # in, so the stage never empties between stories.
      flow: slider && socket.assigns[:graph_modal] && socket.assigns.graph_modal.flow,
      loading: true,
      error: nil,
      slider: slider,
      index: slider && Enum.find_index(slider, &(&1.id == story.id))
    })
    |> start_async(:graph_modal, fn ->
      {:ok, graph} = RequirementStoryGraph.read(scope, story.id)

      {WorkingCopyStoryGraph.build(graph), RequirementStoryGraph.progress(graph)}
    end)
  end

  defp chart_stories(socket),
    do: Bands.read(socket.assigns.current_scope).stories

  defp arrange_graph(socket) do
    case socket.assigns[:graph_modal] do
      %{flow: flow} = modal when not is_nil(flow) ->
        modal = Map.merge(modal, %{flow: StoryGraphLayout.arrange(flow), needs_layout: false})

        socket
        |> assign(:graph_modal, modal)
        |> push_event("lf:fit_view", %{padding: 0.1, duration: 0})

      _ ->
        socket
    end
  end

  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      <CodeMySpecWeb.AppLive.DesktopSetupResults.results snapshot={@desktop_setup_results} />
      <%!-- Only here, and only for the project's own agent.
      John, seeing it on every page: "it should only show up on the chat for
      the main agent on the main checkout." The timeline describes the whole
      project, and this is the one conversation that is about the whole project
      — on a working-copy agent's thread it would be describing something that
      agent is not doing. --%>
      <ProjectTimeline.project_timeline
        :if={@main_agent?}
        scope={@current_scope}
        project={@project}
      />

      <%!-- Order in the markup, not only in CSS. "Beside, with the conversation
      on the left" and "above the conversation" are the same two elements in two
      orders, and `flex-col-reverse` would put the panels on top while leaving
      the chat first in the document — which is a different thing for anyone
      reading the page rather than looking at it. --%>
      <%!-- No `max-w-*` on the wide side. This is the one screen a founder is
      meant to live on while an agent works — John: "it should be full width."
      The transcript inside it is held to a 48rem reading column instead, so
      the pane can be wide without lines that are. --%>
      <div
        id="conversation-layout"
        phx-hook="Viewport"
        data-test="conversation-layout"
        data-layout={to_string(@screen)}
        class={[
          "mx-auto flex min-h-0 w-full flex-1",
          @screen == :wide && "gap-0",
          @screen == :narrow && "max-w-3xl flex-col gap-4"
        ]}
      >
        <.panels
          :if={@screen == :narrow}
          scope={@current_scope}
          screen={@screen}
          open={@open_panels}
          dynamic_view={@dynamic_view}
          dynamic_stories={@dynamic_stories}
          dynamic_story={@dynamic_story}
          dynamic_epics={@dynamic_epics}
          offer={@offer}
          waiting={@waiting}
          copies={@copies}
          project_id={@project.id}
          conversation_id={@conversation && @conversation.id}
          preview_src={@preview_src}
          preview_state={@preview_state}
          extra_frame_origins={@preview_extra_frame_origins}
        />

        <.conversation_column
          :if={@screen == :narrow}
          current_scope={@current_scope}
          project={@project}
          conversation={@conversation}
          emptiness={@emptiness}
          questions={@questions}
          permissions={@permissions}
          items={@items}
          results={@results}
          more_above?={@more_above?}
          pending={@pending}
          undelivered={@undelivered}
          talkable?={@talkable?}
          analysis_running={@analysis_running}
          working?={@working?}
          on?={@on?}
          retired?={@retired?}
          firing?={@firing?}
          assigned={@assigned}
          draft={@draft}
          agent_writing={@agent_writing}
          main_agent?={@main_agent?}
          main={@main}
        />

        <%!-- `auto_save` persists a person's drag to local storage keyed by
        this group's own `id`, restoring it on the next visit — the same
        "how wide I like to work" preference `PanelResize` used to hand-roll
        against a CSS var on `<html>`. `gap-0` above on the layout: the group
        already inserts its own resizer as a real flex child between the two
        panes, so a `gap` here would double the space between them. --%>
        <LivePane.group
          :if={@screen == :wide}
          id="conversation-panes"
          auto_save={true}
          class="min-h-0 w-full flex-1"
        >
          <%!-- `self-stretch` on every direct child of a `LivePane.group`:
          the component hardcodes `items-center` regardless of direction, so
          without it a pane sizes to its own content along the cross axis
          (height, here) instead of filling the row — the same "the panel
          grew instead of scrolling" bug the old `min-h-0` chain existed to
          prevent. --%>
          <LivePane.pane
            group_id="conversation-panes"
            id="conversation-pane"
            min_size={40}
            class="flex min-h-0 min-w-0 flex-col self-stretch"
          >
            <.conversation_column
              current_scope={@current_scope}
              project={@project}
              conversation={@conversation}
              emptiness={@emptiness}
              questions={@questions}
              permissions={@permissions}
              items={@items}
              results={@results}
              more_above?={@more_above?}
              pending={@pending}
              undelivered={@undelivered}
              talkable?={@talkable?}
              analysis_running={@analysis_running}
              working?={@working?}
              on?={@on?}
              retired?={@retired?}
              firing?={@firing?}
              assigned={@assigned}
              draft={@draft}
              agent_writing={@agent_writing}
              main_agent?={@main_agent?}
              main={@main}
            />
          </LivePane.pane>

          <LivePane.resizer
            group_id="conversation-panes"
            id="conversation-panes-resizer"
            class="group flex w-3 shrink-0 cursor-col-resize select-none items-stretch justify-center self-stretch"
          >
            <span class="w-0.5 rounded-full bg-base-300 transition-colors group-hover:bg-primary/60 group-active:bg-primary"></span>
          </LivePane.resizer>

          <LivePane.pane
            group_id="conversation-panes"
            id="conversation-panels"
            data-test="conversation-panels"
            min_size={15}
            max_size={50}
            starting_size={25}
            class="flex min-h-0 min-w-64 flex-col self-stretch"
          >
            <.panels
              scope={@current_scope}
              screen={:wide}
              open={@open_panels}
              dynamic_view={@dynamic_view}
              dynamic_stories={@dynamic_stories}
              dynamic_story={@dynamic_story}
              dynamic_epics={@dynamic_epics}
              offer={@offer}
              waiting={@waiting}
              copies={@copies}
              project_id={@project.id}
              conversation_id={@conversation && @conversation.id}
              preview_src={@preview_src}
              preview_state={@preview_state}
              extra_frame_origins={@preview_extra_frame_origins}
            />
          </LivePane.pane>
        </LivePane.group>
      </div>
      <.assigned_modal :if={assigns[:assigned_modal]} item={@assigned_modal} />
      <TaskComponents.modal
        :if={@task_modal}
        title={@task_modal.title}
        directive={@task_modal.directive}
        project_id={@project.id}
        on_close="close_task"
      />
      <ProblemCharts.modal
        :if={@problems_modal}
        counts={@problems_modal.counts}
        copy_name={@problems_modal.copy_name}
        href={@problems_modal.href}
        on_close="close_problems"
      />
      <CopyComponents.modal
        :for={copy <- @copies}
        :if={copy.row.harness.id == @copy_modal_id}
        row={copy.row}
        project_id={@project.id}
        on_close="close_copy"
      />
      <.graph_modal :if={assigns[:graph_modal]} modal={@graph_modal} project_id={@project.id} />
    </Layouts.app>
    """
  end

  attr :project, :any, required: true
  attr :conversation, :any, required: true
  attr :emptiness, :atom, required: true
  attr :questions, :list, required: true
  attr :permissions, :list, required: true
  attr :items, :list, required: true
  attr :results, :any, required: true
  attr :more_above?, :boolean, required: true
  attr :pending, :list, required: true
  attr :undelivered, :list, default: []
  attr :talkable?, :boolean, required: true

  attr :current_scope, :any, required: true
  attr :analysis_running, :list, required: true
  # State attrs are required, not defaulted: the column renders twice (narrow
  # and wide), and a defaulted one drew the wrong control state.
  attr :working?, :boolean, required: true
  attr :on?, :boolean, required: true
  attr :retired?, :boolean, required: true
  attr :firing?, :boolean, required: true
  attr :assigned, :list, required: true
  attr :draft, :string, required: true

  attr :agent_writing, :string,
    default: nil,
    doc: "what the agent is writing, before it is a message"

  # Whether this is the project's own agent and, when there is none, why.
  attr :main_agent?, :boolean, required: true
  attr :main, :any, required: true

  # Transcript, composer and header, shared by the wide (`LivePane.pane`) and
  # narrow layouts.
  defp conversation_column(assigns) do
    ~H"""
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Composer">
      export default {
        mounted() {
          this.fit();
          this.el.addEventListener("input", () => this.fit());
          this.el.addEventListener("keydown", (e) => {
            if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
              e.preventDefault();
              if (this.el.value.trim() !== "") this.el.form.requestSubmit();
            }
          });
        },
        updated() { this.fit(); },
        fit() {
          this.el.style.height = "auto";
          this.el.style.height = this.el.scrollHeight + "px";
        }
      }
    </script>
    <div
      data-test="agent-conversation"
      data-project-id={@project.id}
      class="flex min-h-0 min-w-0 flex-1 flex-col"
    >
      <%!-- Which checkout the agent is in, on the page rather than inferred
      from elsewhere: "the agent runs in the copy you designated" is a claim a
      reader should be able to check without going and looking somewhere else.
      It was on the agents index's main card, and this is the page that landed
      people now. --%>
      <header
        data-test={@main_agent? && "main-agent"}
        data-agent-id={@main_agent? && @conversation.agent_id}
        data-working-copy-id={@main_agent? && main_copy_id(@main)}
        class="flex shrink-0 items-center gap-2 border-b border-base-300 pb-3"
      >
        <.icon name="hero-cpu-chip" class="size-5 shrink-0" />
        <div class="flex min-w-0 flex-col">
          <div class="flex min-w-0 items-baseline gap-2">
            <h1 class="min-w-0 shrink-0 truncate text-lg font-semibold">
              {@conversation && Conversations.display_name(@conversation)}
            </h1>
            <button
              :for={item <- @assigned}
              type="button"
              phx-click="show_assigned"
              phx-value-kind={item.kind}
              phx-value-key={item.key}
              data-test={"assigned-#{item.kind}"}
              title={item.title}
              class="link link-hover min-w-0 truncate text-left text-xs opacity-70"
            >
              {if item.kind == :issue, do: "Issue", else: "Story"} {item.ref} · {item.title}
            </button>
            <.live_component
              :for={item <- @assigned}
              :if={item.kind == :story}
              module={StoryProgress}
              id="story-progress-header"
              scope={@current_scope}
              story_id={item.story_id}
              working_copy_id={item.working_copy_id}
            />
          </div>
          <%!-- Where the project is, in the words somebody who does not read
          code would use. Deliberately not a status line assembled from row
          counts: the agent is what will write this, and a summary built out of
          numbers here would have to be unbuilt when it does. Paths, module
          names and commands are the vocabulary this agent exists to translate
          out of, so they must not appear. --%>
          <p
            :if={@main_agent?}
            data-test="project-summary"
            class="min-w-0 truncate text-xs opacity-60"
          >
            {main_summary(@main)}
          </p>
        </div>
        <span :if={@conversation} class="shrink-0 font-mono text-xs opacity-40">
          {short_session(@conversation)}
        </span>

        <%!-- Story 538's R13, at the grain somebody is actually looking at.
        The working copy page moves all three roles together, which is right
        for staffing an epic and wrong when you have one agent's conversation
        open and want that one to carry on. --%>
        <button
          :if={@conversation && @conversation.agent_id}
          type="button"
          phx-click="toggle_agent_working"
          data-test="toggle-agent-working"
          data-working={to_string(@working?)}
          class="btn btn-ghost btn-sm btn-square ml-auto shrink-0"
          title={
            if @working?,
              do: "Let this agent stop after its current turn",
              else: "Put this agent to work — it picks its own next task"
          }
        >
          <.icon name={if @working?, do: "hero-pause", else: "hero-play"} class="size-4" />
        </button>

        <%!-- The power button (39af5611): green while on, red while off, and
        the label says what a click does, so colour is never the only signal.
        Off is a real shutdown; only this or `turn_on_agent` brings it back. --%>
        <span
          :if={@conversation && @conversation.agent_id && @retired?}
          data-test="agent-retired"
          class="badge badge-ghost badge-sm shrink-0"
        >
          Retired
        </span>
        <button
          :if={@conversation && @conversation.agent_id && not @retired?}
          type="button"
          phx-click="toggle_agent_power"
          data-test="agent-power"
          data-on={to_string(@on?)}
          class={[
            "btn btn-ghost btn-sm btn-square shrink-0",
            if(@on?, do: "text-success", else: "text-error")
          ]}
          aria-label={if @on?, do: "Turn agent off", else: "Turn agent on"}
          aria-pressed={to_string(@on?)}
          title={if @on?, do: "On — turn this agent off", else: "Off — turn this agent on"}
        >
          <.icon name="hero-power" class="size-4" />
        </button>

        <button
          :if={@conversation && @conversation.agent_id && not @retired? && not @firing?}
          type="button"
          phx-click="fire_agent"
          data-test="fire-agent"
          class="btn btn-ghost btn-sm btn-square shrink-0 text-error"
          title="Fire this agent: retires it for good"
        >
          <.icon name="hero-fire" class="size-4" />
        </button>

        <div
          :if={@conversation && @conversation.agent_id && @firing?}
          class="flex shrink-0 items-center gap-2 text-xs"
        >
          <span class="opacity-70" data-test="fire-agent-confirm-text">
            Fire {@conversation && Conversations.display_name(@conversation)}? This cannot be undone.
          </span>
          <button
            type="button"
            phx-click="confirm_fire_agent"
            data-test="confirm-fire-agent"
            class="btn btn-error btn-xs"
          >
            Fire
          </button>
          <button
            type="button"
            phx-click="cancel_fire_agent"
            data-test="cancel-fire-agent"
            class="btn btn-ghost btn-xs"
          >
            Cancel
          </button>
        </div>
      </header>

      <%!-- `overflow-anchor` is what keeps your place when older turns are
          prepended: without it the browser holds the scroll *offset*, so
          inserting above jumps you backwards by exactly the height added.
          `StickToBottom` opens at the newest turn and follows it only while
          you are already down there. --%>
      <%!-- The id carries the conversation so switching agents remounts this
      element rather than patching it. `StickToBottom` pins on `mounted` and
      otherwise only reacts to `updated`, where it holds whatever
      `wasAtBottom` was — so a patched-in-place transcript would open the next
      agent at the scroll offset you left the last one at, halfway up a
      conversation you have never read. --%>
      <div
        id={"agent-scroll-#{(@conversation && @conversation.id) || "empty"}"}
        data-test="conversation-scroll"
        phx-hook="StickToBottom"
        class="min-h-0 flex-1 overflow-y-auto py-6 px-[max(1rem,calc((100%-48rem)/2))]"
        style="overflow-anchor: auto"
      >
        <%!-- Two failures, two remedies, and telling them apart is the whole
        value of saying anything. Nowhere to run is `mix cms.new` or designating
        a checkout you already have; nothing to run on is connecting a provider.
        A single "unavailable" would send half the people who read it to the
        wrong place. Carried over from the agents index, which used to be where
        somebody landed and so used to be where this was said. --%>
        <p
          :if={match?({:error, :no_main_working_copy}, @main)}
          data-test="no-main-working-copy"
          class="rounded-box border border-warning/40 bg-warning/10 p-4 text-sm"
        >
          This project has no main working copy yet, so there is nowhere for its
          agent to run. Run <code>mix cms.new</code> to make one, or open a
          checkout you already have and make it the main copy.
        </p>

        <p
          :if={match?({:error, :not_connected}, @main)}
          data-test="no-provider"
          class="rounded-box border border-warning/40 bg-warning/10 p-4 text-sm"
        >
          This project has a main working copy but no provider connected, so its
          agent has nothing to run on. Connect one and it will come up.
        </p>

        <p
          :if={@conversation == nil and match?({:ok, _, _}, @main)}
          data-test="agent-conversation-empty"
          class="py-8 text-center opacity-60"
        >
          No agent activity recorded for this project yet.
        </p>

        <p
          :if={@emptiness == :nothing_yet}
          data-test="nothing-recorded-yet"
          class="rounded-box border border-base-300 p-3 text-sm opacity-70"
        >
          Nothing recorded yet. Steps appear here as the agent takes them.
        </p>

        <p
          :if={@emptiness == :gap}
          data-test="recording-gap"
          class="rounded-box border border-warning/40 bg-warning/10 p-3 text-sm"
        >
          Turns were taken but not recorded. What follows is incomplete —
          treat gaps as missing evidence, not as an idle sprite.
        </p>

        <%!-- A pointer, not a second copy of the form. The questions render in
        the transcript at the turn that asked them; this only exists so an
        unanswered one is findable when it is forty turns up. Two live forms for
        one pending question means whichever submits first makes the other look
        broken. --%>
        <div
          :if={pending(@questions) != []}
          data-test="questions-waiting"
          class="mb-4 flex items-center gap-3 rounded-box border border-warning/40 bg-warning/10 p-3 text-sm"
        >
          <.icon name="hero-chat-bubble-left-right" class="size-4 text-warning" />
          <span>{waiting_label(@questions)}</span>
          <a
            href={"#question-#{hd(pending(@questions)).id}"}
            class="link link-primary ml-auto text-xs"
          >
            Jump to it
          </a>
        </div>

        <div
          id="agent-turns"
          class="space-y-6"
          phx-viewport-top={@more_above? && "load_older"}
          data-more-above={to_string(@more_above?)}
        >
          <p :if={@more_above?} data-test="loading-older" class="py-2 text-center text-xs opacity-40">
            loading earlier turns…
          </p>
          <div :for={item <- @items} id={"turn-group-#{item.id}"} class="space-y-3">
            <ChatComponents.turn_item
              id={"turn-#{item.id}"}
              item={item}
              own_role={:user}
              results={@results}
            />
            <%!-- Beside the work that prompted it. An answered one keeps
            rendering here with what was said, because in a transcript the
            answer is part of the record rather than a modal that closes. --%>
            <ChatComponents.question
              :for={request <- questions_at(@questions, item)}
              id={"question-#{request.id}"}
              request={request}
              on_submit="answer_question"
            />
          </div>

          <%!-- Anything whose anchor is not on this page: rows written before
          the anchor existed, and questions whose turn has scrolled above the
          window. Bottom of the chat is right for a pending one — it is the
          newest thing — and the best available guess for an old answered one. --%>
          <ChatComponents.question
            :for={request <- unanchored_questions(@questions, @items)}
            id={"question-#{request.id}"}
            request={request}
            on_submit="answer_question"
          />

          <%!-- No anchor field exists on a permission request, so every one of
          these lands here rather than beside a specific turn — same bucket an
          unanchored question falls into, for the same reason: the bottom of
          the chat is right for a pending one and the best available guess for
          a resolved one. --%>
          <PermissionComponents.permission_request
            :for={request <- unanchored_permissions(@permissions)}
            id={"permission-#{request.id}"}
            request={request}
            on_approve="approve_permission"
            on_deny="deny_permission"
          />

          <%!-- The reply as it is written. Replaced by the message itself when
          the turn settles; never stored. --%>
          <ChatComponents.chat_message
            :if={@agent_writing}
            id="agent-writing"
            role={:assistant}
            own_role={:user}
            label="writing…"
            text={@agent_writing}
          />
        </div>
      </div>

      <%!-- What the analyzers are doing, while they are doing it. The agent
      hears about a run when it lands; the person watching would otherwise see
      an idle transcript and no reason for it.

      Below the transcript rather than above it, with the other status strips.
      It was at the top, which is off screen for anyone reading the newest
      turns — a spinner nobody scrolls back to answers the question nobody is
      asking. John, watching a turn end: "I don't see any UI element to indicate
      that the analyzers are running ... I just saw it come back, I think the
      observable element is rendering, but at the top of the chat pane."

      One copy, not two. A status shown in two places disagrees with itself the
      moment one of them patches first, which is the trap the question pointer
      above this file already documents. --%>
      <div
        :if={@analysis_running != []}
        data-test="analysis-running"
        data-sources={Enum.join(@analysis_running, ",")}
        class="flex shrink-0 items-center gap-3 pt-3 text-sm px-[max(1rem,calc((100%-48rem)/2))]"
      >
        <span class="loading loading-spinner loading-xs text-info"></span>
        <span>{analysis_label(@analysis_running)}</span>
        <span class="ml-auto text-xs opacity-60">
          the agent is told when it lands
        </span>
      </div>

      <%!-- Refused outright (criterion 2042): never received, so not in the
      transcript, and not waiting, so not in the queue below. --%>
      <div
        :for={message <- @undelivered}
        data-test="agent-undelivered-message"
        class="flex shrink-0 items-center gap-2 pt-3 text-xs text-error px-[max(1rem,calc((100%-48rem)/2))]"
      >
        <span class="min-w-0 flex-1 truncate">{Message.text(message)}</span>
        <span class="opacity-80">Not delivered{if message.delivery_diagnostic,
          do: ": #{message.delivery_diagnostic}"}</span>
      </div>

      <div
        :for={{message, run} <- pending_runs(@pending)}
        data-test="agent-pending-message"
        class="flex shrink-0 items-center gap-2 pt-3 text-xs px-[max(1rem,calc((100%-48rem)/2))]"
      >
        <%!-- Pending content appears here until delivery moves it into the transcript. --%>
        <details
          :if={run != []}
          data-test="pending-routine-notice"
          data-count={length(run)}
          class="min-w-0 flex-1"
        >
          <summary class="cursor-pointer">
            Promotion confirmed{if length(run) > 1, do: " ×#{length(run)}"}
          </summary>
          <div :for={notice <- run} class="mt-2 flex items-start gap-2">
            <span class="min-w-0 flex-1 whitespace-pre-wrap break-words">
              {Message.text(notice)}
            </span>
            <.withdraw_button
              :if={length(run) > 1 and notice.mailbox_state in ["queued", "claimed"]}
              message={notice}
            />
          </div>
        </details>
        <.queued_text :if={run == []} message={message} />
        <span class="opacity-60">
          {message.delivery_diagnostic || mailbox_label(message.mailbox_state)}
        </span>
        <.send_now_button
          :if={length(run) < 2 and message.mailbox_state == "queued"}
          message={message}
        />
        <.withdraw_button
          :if={length(run) < 2 and message.mailbox_state in ["queued", "claimed", "send_now"]}
          message={message}
        />
      </div>

      <form
        :if={@talkable?}
        id="agent-message-form"
        data-test="agent-message-form"
        phx-submit="send_message"
        phx-change="draft"
        class="shrink-0 pt-2 pb-3 px-[max(1rem,calc((100%-48rem)/2))]"
      >
        <%!-- A rendered value is load-bearing, which is not obvious and cost a
      duplicate send in real use. Without one the DOM patch has nothing to
      set, so what you typed survives the submit and sits in the box looking
      unsent — and the next thing anyone does is send it again. `InboxLive`'s
      message form has carried this attribute all along.

      It is `@draft` rather than `""` because the panels made every toggle a
      patch, and a hardcoded empty value threw away a half-written message
      every time someone opened one. `send_message` clears `@draft` itself,
      so the duplicate-send fix is still explicit rather than a side effect
      of rendering nothing. --%>
        <div class="flex items-end gap-2 rounded-3xl border border-base-content/10 bg-base-200 py-2 pl-4 pr-2 shadow-sm focus-within:border-base-content/25">
          <textarea
            id="agent-message-input"
            name="message"
            rows="1"
            phx-hook=".Composer"
            autocomplete="off"
            placeholder="Message this agent"
            data-test="agent-message"
            class="max-h-60 min-h-6 min-w-0 flex-1 resize-none self-center bg-transparent py-1 text-[15px] leading-6 outline-none"
          >{@draft}</textarea>
          <%!-- Disabled while it is in flight. `dispatch_message/3` waits on the
      machine — up to the transport's patience if that machine is slow — and
      a button that stays live through that invites the second click, which
      is a second turn and a second answer rather than a wasted one. --%>
          <button
            type="submit"
            phx-disable-with=""
            aria-label="Send"
            class="btn btn-circle btn-primary btn-sm shrink-0"
          >
            <.icon name="hero-arrow-up" class="size-4" />
          </button>
        </div>
      </form>

      <p
        :if={@conversation != nil and not @talkable?}
        data-test="agent-not-talkable"
        class="shrink-0 pt-3 pb-2 text-center text-xs opacity-60 px-[max(1rem,calc((100%-48rem)/2))]"
      >
        This agent is not running, so there is nothing to send a message to.
      </p>
    </div>
    """
  end
end
