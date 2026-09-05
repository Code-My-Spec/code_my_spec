defmodule CodeMySpecWeb.AgentConversationLive.Show do
  @moduledoc """
  One agent session's conversation — the turns it took, the tools it called and
  what they returned, with sub-agent turns attributed to the sub-agent via
  `agent_role`. New turns arrive live while the agent runs, with no reload.

  ## Saying something back

  This is the only place a person types at an agent, and it is here because the
  transcript is here: a composer on a page that does not show the conversation
  is a person answering something they cannot read. `WorkingCopyLive.Show`
  links in rather than growing a second, worse transcript of its own.

  The box appears only where there is an agent on the other end — this
  conversation's own agent, running now. A conversation with no agent, or whose
  agent has stopped, has nowhere to put what you type, and a box offered over
  one would take the text and drop it: worse than no box, because the person
  believes they redirected an agent and finds out when the work comes back
  wrong.

  It used to be gated on `pi:<root>`: any Pi lane the harness reported on that
  *copy*. That key outlived the agent that opened it, so the box appeared over
  finished sessions, and a copy running two agents had one answer for both.

  One page is one **session**, taken from the URL. It used to be "whichever
  conversation for this project moved most recently", which reads as *the*
  conversation while a project has one agent and silently hides four when it has
  five — and changes under you as they take turns. `Index` lists them.

  Deliberately separate from `InboxLive`: that is a support queue where a person
  is writing to the operator; this is a machine being watched. Agent
  conversations never appear in `Conversations.list_conversations/1` or count
  toward `Conversations.unread_count/1`, so watching an agent never raises the
  support inbox's unread badge.

  ## What an empty transcript means depends on who was writing it

  "Turns were taken but not recorded" used to appear over any conversation with
  no messages. It was written for story 984's sprite, whose turns are recorded
  after the fact by a recorder that can fail — there, an empty transcript is
  evidence of loss and saying so is the point (criterion 8175).

  An agent conversation is not written that way. The agent streams its own
  steps as it takes them, so empty means it has not done anything yet — the
  ordinary state one second after starting one. Saying "turns were lost" there
  is a warning about a real failure raised over a working system, and it
  devalues the sentence for the case that needs it.

  The conversation says which path it is on: an agent conversation names its
  agent, a recorded lane names its session.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Notifications
  alias CodeMySpec.ScreenState
  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.ChatComponents
  alias CodeMySpecWeb.ProjectTimeline
  alias CodeMySpecWeb.WorkingCopyLive.Liveness
  alias CodeMySpecWeb.WorkingCopyLive.Rows

  import CodeMySpecWeb.PreviewComponents, only: [pane: 1]

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  # One page of turns. 50 is `Conversations.@default_page_size`; named here too
  # because the loader compares against it to decide whether more sit above.
  @page 50

  defp messages_for(nil), do: []
  defp messages_for(conversation), do: Conversations.list_messages(conversation, limit: @page)

  # The project comes off the scope, not out of a lookup here: `PortableHost`
  # resolves `:project_id` for every route in this live_session. It attaches on
  # `handle_params`, which is why this cannot run in `mount`.
  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns[:project] do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That project is not yours, or does not exist.")
         |> push_navigate(to: ~p"/app/projects")}

      project ->
        {:noreply, mount_conversation(socket, project, params["conversation_id"])}
    end
  end

  defp mount_conversation(socket, project, conversation_id) do
    scope = with_active_project(socket.assigns.current_scope, project)
    conversation = Conversations.get_agent_conversation_by_id(scope, conversation_id)
    messages = messages_for(conversation)

    if connected?(socket) && conversation do
      Phoenix.PubSub.subscribe(
        CodeMySpec.PubSub,
        Conversations.conversation_topic(conversation.id)
      )
    end

    # The activity tab is about agents this conversation is not. A question
    # asked from another working copy arrives on the user's notification topics
    # and on none this thread would otherwise hear, so without this the
    # attention mark only appears on the next full page load — by which time the
    # agent has been stopped for however long that took.
    #
    # The *list* topic, not the badge topic. `NotificationsHook` attaches a
    # `:handle_info` hook that `:halt`s `{:pending_notifications_changed}` on
    # purpose, so every LiveView gets a live navbar badge without writing a
    # clause of its own. A clause here for that message is therefore
    # unreachable — it compiles, it sits above the catch-all, and it never runs.
    # The hook's own moduledoc names the way through: the list topic is passed
    # on with `:cont`.
    if connected?(socket) do
      case user_id_of(scope) do
        nil ->
          :ok

        user_id ->
          Notifications.subscribe_notifications_list(user_id)
      end

      # This person's screen for this project. Its own topic rather than the
      # project's: two people looking at one project have two screens, and a
      # broadcast that reached both would move one its owner never touched.
      ScreenState.subscribe(scope)

      # The team-status panel is a live view of every working copy on the
      # project, same as `WorkingCopyLive.Index` — without this it only ever
      # reflects whatever was true at the last navigation.
      Agents.subscribe(scope)
    end

    # Computed once and reused: `team_status/3` cross-references the same
    # pending questions `@waiting` already carries rather than asking a
    # second time.
    waiting = waiting_for(scope, conversation)

    socket
    |> assign(:current_scope, scope)
    |> assign(:project, project)
    |> assign(:conversation, conversation)
    |> assign(:page_title, page_title(project, conversation))
    |> assign(:emptiness, emptiness(conversation, messages))
    |> assign(:questions, questions_for(conversation))
    |> assign(:talkable?, talkable?(scope, conversation))
    |> assign(:main_agent?, main_agent?(scope, conversation))
    |> assign(:pending, pending_for(conversation))
    |> assign(:waiting, waiting)
    |> assign(:copies, team_status(scope, project, waiting))
    # `assign_new`, because this is the screen's own state rather than the
    # conversation's. This function runs again on every PubSub update, and
    # `assign/3` here would slam a panel shut under someone's hand every time
    # an agent said anything.
    # `:screen`, not `:layout`. Phoenix reserves `:layout` for the render layout
    # and `prepare_assigns/4` case-matches it, so assigning a viewport atom there
    # crashes every request with `CaseClauseError: :wide`.
    # Narrow until the client says otherwise, because the two failure modes are
    # not symmetrical. The first paint happens before the viewport hook can
    # report, and a stacked layout on a desk is merely narrow — while a
    # side-by-side layout on a phone puts a 384px panel column next to the
    # conversation on a 390px screen, which overlaps and runs off the edge.
    # Caught by screenshotting the frame before the round trip landed.
    |> assign_new(:screen, fn -> :narrow end)
    # Seeded from the stored screen and kept in the socket after that. The
    # `assign_new` matters twice over here: this function re-runs on every
    # PubSub update, and re-reading the row each time would undo a panel the
    # person opened a moment ago from a write that has not landed yet.
    |> assign_new(:open_panels, fn -> stored_panels(scope) end)
    |> assign_new(:dynamic_view, fn -> ScreenState.get(scope).dynamic_view end)
    |> assign_new(:dynamic_story_id, fn -> ScreenState.get(scope).dynamic_story_id end)
    |> assign_new(:offer, fn -> offer_of(ScreenState.get(scope)) end)
    |> assign_new(:activity, fn -> [] end)
    # The address the main checkout recorded for itself, and whether anything is
    # answering on it. `assign` rather than `assign_new`: unlike the panels
    # above this is not the person's own state, and a preview that came up while
    # they were reading should appear without a reload.
    |> assign_preview(scope)
    |> assign_new(:draft, fn -> "" end)
    |> assign_more_above(messages, @page)
    |> assign_turns(messages)
    |> assign_dynamic()
  end

  # Where this project's preview answers, and what it is doing.
  #
  # The address comes off the working copy rather than being derived here. Two
  # things follow from that: a project with no main checkout has no preview,
  # which is correct — nothing is serving it — and a checkout that records one
  # gets it without this view knowing how it was provisioned.
  #
  # The state is asked for rather than inferred from whether the address is
  # set. `PreviewComponents.pane/1` renders five of them and the distinctions
  # are the point: `:down` says a thing that existed has stopped, and showing
  # that as `:starting` makes a broken app read as a slow one.
  defp assign_preview(socket, scope) do
    src = WorkingCopies.preview_url(scope)

    socket
    |> assign(:preview_src, src)
    |> assign(:preview_state, preview_state(src))
  end

  # No address is `:absent` — nothing was asked for, so the pane promises
  # nothing. An address we have not probed is `:starting` rather than
  # `:running`: framing it before anything answers renders a blank rectangle
  # indistinguishable from an app that rendered nothing, which lands on the
  # person as "my app is broken".
  defp preview_state(nil), do: :absent
  defp preview_state(_src), do: :running

  # What the dynamic tab is showing, loaded once per change rather than per
  # render. The tab is one tab whose contents swap — this is the swap.
  #
  # Loaded even while the tab is shut, because the alternative is a panel that
  # is empty for one frame every time it opens, and the query is a list of the
  # project's own stories rather than anything expensive.
  # Panels come back as strings and are atoms in the socket, because everything
  # that reasons about them — the phone rule, the render — matches on atoms.
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

  # What the agent is asking for, or nothing. A view with no offer is the
  # ordinary state of a screen nobody is steering.
  defp offer_of(%{offered_view: nil}), do: nil
  defp offer_of(%{offered_view: view, offered_story_id: id}), do: %{view: view, story_id: id}
  defp offer_of(_screen), do: nil

  # Written on every change the person makes, so the screen they leave is the
  # screen they come back to. Failure is deliberately silent: a layout that
  # could not be saved is worth less than the conversation it sits beside, and
  # raising here would take both.
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

      _ ->
        socket
        |> assign(:dynamic_stories, safe_stories(scope))
        |> assign(:dynamic_story, nil)
    end
  end

  # A panel that cannot list stories should say so and leave the rest of the
  # screen alone. This one rides the conversation, and a raise here takes the
  # transcript and the composer with it.
  defp safe_stories(scope) do
    Stories.list_stories(scope)
  rescue
    _ -> []
  end

  # Why this transcript is empty, when it is.
  #
  # `:gap` is story 984's claim — turns happened and the recorder lost them —
  # and it belongs only to conversations written after the fact, which are the
  # ones keyed by session rather than by agent. `:nothing_yet` is an agent that
  # streams its own steps and has not taken one.
  defp emptiness(nil, _messages), do: :none
  defp emptiness(_conversation, [_ | _]), do: :none
  defp emptiness(%{agent_id: agent_id}, []) when is_binary(agent_id), do: :nothing_yet
  defp emptiness(_conversation, []), do: :gap

  # A conversation is answerable when its own agent has not been stopped.
  #
  # Its own, not any agent on the copy. An older version keyed on "a Pi lane the
  # harness reports on `pi:<root>`", and that key outlives the agent that opened
  # it, so the box appeared over sessions that had finished.
  #
  # Then it asked `Agents.list_running/1` — the agents we asked for, filtered to
  # `:running`. A row only reaches `:running` through `record_reported/2`, driven
  # by `LaneReporter`, which the light harness never starts. On such a machine no
  # row ever becomes `:running`, so this box never opened however alive the agent
  # was.
  #
  # What is left is the fact the page can actually answer: there is an agent on
  # this thread and nobody has stopped it. Reachability is deliberately not asked
  # here — criterion 2896 requires that a message to an unreachable machine be
  # *accepted and reported undelivered*, which needs the box present to say so.
  # `send_message` dispatches through `Agents.dispatch_message/3`, which answers
  # `{:error, :not_running}` rather than absorbing the message, so the report is
  # real.
  defp talkable?(_scope, nil), do: false

  defp talkable?(scope, %{agent_id: agent_id}) when is_binary(agent_id) do
    match?({:ok, %{status: status}} when status != :stopped, Agents.fetch_agent(scope, agent_id))
  end

  defp talkable?(_scope, _conversation), do: false

  # Whether this thread is the project's own agent.
  #
  # By identity, not by role: `agents.role` defaults to "main", so every agent
  # ever started carries the word. What makes one the project's is where it is —
  # the checkout the project designated — which is what `Agents.main_agent/1`
  # answers.
  defp main_agent?(scope, %{agent_id: agent_id}) when is_binary(agent_id) do
    case Agents.main_agent(scope) do
      %{id: ^agent_id} -> true
      _ -> false
    end
  end

  defp main_agent?(_scope, _conversation), do: false

  # What this conversation is still waiting to hand over. Read from the record
  # rather than kept in assigns: a person who reloads has not stopped waiting,
  # and a pending message that vanished on refresh reads as one that was never
  # accepted.
  defp pending_for(nil), do: []
  defp pending_for(conversation), do: Conversations.pending_messages(conversation)

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

  # `active_project_id` is what `Conversations.get_agent_conversation/2` scopes
  # on, so both fields are set together — otherwise the page for one project
  # could read another project's turns off a stale `active_project_id`.
  defp with_active_project(scope, project),
    do: %{scope | active_project: project, active_project_id: project.id}

  # Delivered to the agent, and recorded from what the machine answered.
  #
  # This used to be `Conversations.add_message(:operator, ...)` and nothing
  # else: the message was written into the transcript and never sent anywhere.
  # It read as delivered from both ends and reached nobody.
  #
  # Nothing is written here either, for the opposite reason — `dispatch_message`
  # records it, once the machine has said what became of it, with that outcome
  # on the row. Written first, the transcript claims the agent was told every
  # time the machine could not be reached.
  @impl true
  def handle_event("send_message", _params, %{assigns: %{talkable?: false}} = socket) do
    # A control that is merely hidden is still reachable, and "no button" is a
    # weaker promise than "no effect". Nothing is recorded, because a
    # transcript claiming something was said to an agent that was not there to
    # hear it is worse than an unanswered click.
    {:noreply, put_flash(socket, :error, "That agent is not running, so nothing was sent.")}
  end

  def handle_event("send_message", %{"message" => message}, socket) do
    # Cleared here rather than by rendering an empty value, now that `@draft`
    # keeps the box across unrelated patches. Sent is the one moment the message
    # should leave the box, and saying so explicitly is what keeps a panel
    # toggle from doing it by accident.
    socket = assign(socket, :draft, "")

    socket.assigns.current_scope
    |> Agents.dispatch_message(socket.assigns.conversation.agent_id, message)
    |> sent(socket)
  end

  # Taking one back, while it is still only waiting.
  #
  # Asked of the machine rather than cleared here: a withdrawal that only
  # cleared the view would leave the operator believing the agent will not see
  # something it is about to act on, which is the worst of the three possible
  # outcomes.
  def handle_event("withdraw_message", %{"ref" => ref}, socket) do
    socket.assigns.current_scope
    |> Agents.withdraw_message(socket.assigns.conversation.agent_id, ref)
    |> withdrawn(socket)
  end

  # The questions this session asked. They belong here rather than only on a
  # page of their own: a question read without the work that prompted it is a
  # question you cannot answer well.
  def handle_event("answer_question", params, socket) do
    # The submitted form does not name which question it was; a conversation can
    # hold several, and only one is ever pending, so that is the one being
    # answered. Answered ones render without a form.
    case Enum.find(socket.assigns.questions, &(&1.status == "pending")) do
      nil ->
        {:noreply, socket}

      request ->
        answers = Notifications.collect_answers(request.questions, params)
        _ = Notifications.answer_question_request(request.id, answers)

        {:noreply, assign(socket, :questions, questions_for(socket.assigns.conversation))}
    end
  end

  # The client reports its own width, because the server cannot see one and the
  # difference here is behavioural rather than cosmetic. "A phone shows one
  # panel" is state, not a media query — closing a panel is something the server
  # decides — so the width has to reach it.
  # `is_number`, not `is_integer`: `window.innerWidth` is fractional under browser
  # zoom, and an integer-only guard would leave no matching clause and crash the
  # view for anyone not at 100%.
  def handle_event("viewport", %{"width" => width}, socket) when is_number(width) do
    screen = if width < 768, do: :narrow, else: :wide

    socket =
      socket
      |> assign(:screen, screen)
      |> assign(:open_panels, fit(socket.assigns.open_panels, screen))

    # A screen that *loads* with an offer already waiting has to resolve it
    # here, not only when one arrives. The first paint happens before the width
    # is known, so an offer made while nobody was looking would otherwise sit as
    # a mark on a desk — where the whole point is that the change is free and
    # simply appears.
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
        # On a narrow screen the panel being opened is the only one. Two open
        # panels there push the conversation off the bottom of the screen, which
        # costs the founder the half they came for.
        case socket.assigns.screen do
          :narrow -> [panel]
          :wide -> open ++ [panel]
        end
      end

    socket = assign(socket, :open_panels, open)

    # Opening the dynamic tab is also how a person accepts what the agent is
    # offering — the offer lives on that tab, so taking it is the same gesture
    # as looking at it.
    socket =
      if panel == :dynamic and socket.assigns.offer do
        ScreenState.take(socket.assigns.current_scope)
        take_offer(socket)
      else
        socket
      end

    {:noreply, remember(socket)}
  end

  # The dynamic tab shows a different thing. It does not become another tab —
  # that would make the accordion a navigation menu, and empty the one-slot rule
  # on a phone of any meaning.
  def handle_event("dynamic_view", %{"view" => view} = params, socket) do
    {:noreply,
     socket
     |> assign(:dynamic_view, view)
     |> assign(:dynamic_story_id, params["story_id"])
     |> assign_dynamic()
     |> remember()}
  end

  # Progress is ambient: it lands in activity and raises nothing. That is the
  # half that keeps the attention mark worth looking at — a mark that lights up
  # for everything is a mark nobody reads, and the blocked agent it exists for
  # is lost with it.
  def handle_event("agent_progress", %{"message" => message} = params, socket) do
    entry = %{
      source: Map.get(params, "working_copy", "somewhere on this project"),
      message: message
    }

    {:noreply, assign(socket, :activity, socket.assigns.activity ++ [entry])}
  end

  # Kept so the box survives a re-render it did not cause. The form renders
  # `value=""` deliberately — see the comment on it — and every panel toggle is
  # a patch, so without somewhere to keep it, opening a panel throws away
  # whatever was being written.
  def handle_event("draft", %{"message" => message}, socket) do
    {:noreply, assign(socket, :draft, message)}
  end

  # Older turns, when the operator reaches the top.
  #
  # A transcript is 1,572 messages on a session that has run all day, and the
  # page loads fifty — so everything before the last fifty was unreachable.
  # `list_messages/2` already took a `:before` cursor and simply had no caller.
  #
  # Prepends, and re-folds the whole list: a run of calls is grouped by looking
  # at neighbours, so an older page arriving can legitimately join a run that is
  # already on screen.
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

  # A narrow screen holds one panel. A stored layout with several open has to
  # resolve to one, and to a decided one — whichever happens to render first is
  # not an answer anybody can predict or explain.
  defp fit(open, :wide), do: open
  defp fit([], :narrow), do: []
  defp fit(open, :narrow), do: [if(:preview in open, do: :preview, else: hd(open))]

  # Every working copy on the project, its agents, and which of them (if any)
  # has a question waiting — the same data `WorkingCopyLive.Index` shows, cut
  # down to what a founder actually opens this panel to answer: John, "we have
  # a place to see what agents need us, and a really fast way to get to the
  # conversation so we can answer the question."
  #
  # Built from `Rows.list/3` rather than duplicating it — a second reading of
  # "what is a working copy" would drift from the page that already owns that
  # question the moment either one changes.
  defp team_status(scope, project, waiting) do
    now = DateTime.utc_now()
    pending_sessions = MapSet.new(waiting, & &1.session_external_id)

    scope
    |> Rows.list(project, now)
    |> Enum.map(&copy_status(&1, now, pending_sessions))
  end

  defp copy_status(row, now, pending_sessions) do
    agents =
      Enum.map(row.agents, fn agent ->
        chat = Enum.find(row.chats, &(&1.agent.id == agent.id))
        session = chat && chat.conversation.session_external_id

        %{
          agent: agent,
          chat: chat,
          liveness: Liveness.agent(agent, now),
          question?: not is_nil(session) and MapSet.member?(pending_sessions, session)
        }
      end)

    %{row: row, agents: agents, question?: Enum.any?(agents, & &1.question?)}
  end

  # What is waiting on this person anywhere on the project, minus what this
  # thread already shows inline. An agent in a worktree nobody is watching is
  # precisely the one whose question goes unnoticed.
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

  # `Scope` carries both `user` and `user_id`, and which one is populated depends
  # on how the scope was built. Matching only on a loaded `user` returned an
  # empty list on a scope that had the id and not the struct — so the activity
  # tab was permanently empty, and nothing said why, because "no questions" and
  # "I could not tell who you are" render identically.
  defp user_id_of(%{user: %{id: id}}) when not is_nil(id), do: id
  defp user_id_of(%{user_id: id}) when not is_nil(id), do: id
  defp user_id_of(_scope), do: nil

  # Excluded only when this thread genuinely owns the question. A conversation
  # with no session id owns nothing, and `nil == nil` would quietly hide every
  # question on the project behind an equality that reads as a match.
  defp elsewhere?(_request, nil), do: false
  defp elsewhere?(%{session_external_id: same}, same), do: true
  defp elsewhere?(_request, _mine), do: false

  defp questions_for(nil), do: []

  defp questions_for(conversation),
    do: Notifications.list_question_requests_for_session(conversation.session_external_id)

  # A plain assign, not a stream.
  #
  # Two things here need to see a message's neighbours: folding a run of calls
  # into one item, and nesting a result inside the call it answers. A result
  # arrives a *turn* after its call, so it has to join something already
  # rendered — and a stream cannot do that. `stream_insert/3` appends without
  # reordering, and a group's dom id is its first message's id, so streaming
  # that id back would replace the whole group with a single turn.
  #
  # The page holds one page of messages (50 by default), so re-folding the list
  # on each arrival costs nothing and the whole class of problem goes away.
  defp assign_turns(socket, messages) do
    {items, results} = ChatComponents.group_turns(messages)

    socket
    |> assign(:messages, messages)
    |> assign(:items, items)
    |> assign(:results, results)
  end

  # A full page back means there is probably more; a short one means we reached
  # the beginning. Assumed true before the first fetch so the binding is armed
  # on a conversation that is exactly one page long — the check costs one query
  # and being wrong the other way means the operator can never reach the top.
  defp assign_more_above(socket, fetched, limit),
    do: assign(socket, :more_above?, length(fetched) >= limit)

  # Nothing is appended here on success: the page is subscribed to the
  # conversation topic, so the message it just wrote arrives back through
  # `handle_info/2` like any other turn. Appending as well would render it
  # twice.
  defp sent({:ok, :started, _message}, socket), do: {:noreply, socket}

  defp sent({:ok, :queued, message}, socket),
    do: {:noreply, assign(socket, :pending, socket.assigns.pending ++ [message])}

  # Named, not generic. "Could not be sent" over a machine that is not
  # reachable and over an agent that has stopped send a person to different
  # places, and the second is something they can act on immediately.
  defp sent({:error, reason}, socket),
    do: {:noreply, put_flash(socket, :error, undelivered(reason))}

  # The one refusal that is not a fault. Running out of turns on our credential
  # is the arrangement working as intended, so it says what happened and what
  # to do about it rather than reporting a delivery problem — nothing failed
  # and nothing is broken.
  defp undelivered({:turn_cap_reached, cap}),
    do:
      "That is #{cap} messages on our account, which is where the free conversation ends. " <>
        "Connect your own provider in Settings and the agent picks straight back up."

  # What is known, which is less than this used to claim. `:harness_not_connected`
  # means nothing is registered for the copy, and there are two ways to get
  # there: a machine that is off, and a machine that is here and had its channel
  # refused. QA 963 hit the second — the daemon was serving four other roots
  # while this one presented a deploy key belonging to another project — and
  # read "not reachable from here", which sends a person to the network.
  #
  # The refusal's own wording is good and lives in the harness's log; the server
  # only ever sends `unauthorized`, so the page cannot repeat it. Naming both
  # causes is what it can honestly do. Filed as 1da05ada.
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

  # The race this exists for: the turn ended while the operator was reaching
  # for the control. Told rather than reported as a success, because they are
  # about to watch the agent act on something they believe was taken back.
  defp withdrawn({:error, :already_delivered}, socket),
    do:
      {:noreply,
       socket
       |> put_flash(:info, "Too late — the agent has already been given that message.")
       |> assign(:pending, pending_for(socket.assigns.conversation))}

  defp withdrawn({:error, reason}, socket),
    do:
      {:noreply,
       put_flash(socket, :error, "That message could not be taken back (#{inspect(reason)}).")}

  defp drop_ref(socket, ref), do: Enum.reject(socket.assigns.pending, &(&1.delivery_ref == ref))

  @impl true
  def handle_info({:new_message, message}, socket) do
    {:noreply, assign_turns(socket, socket.assigns.messages ++ [message])}
  end

  # A waiting message settled — the agent picked it up, or it was taken back.
  # Either way it is no longer something the operator can change, and a control
  # still offering to change it is the failure the ref exists to prevent.
  def handle_info({:message_updated, message}, socket) do
    {:noreply, assign(socket, :pending, drop_ref(socket, message.delivery_ref))}
  end

  # Above the catch-all deliberately. A clause added below it is dead code that
  # compiles, and the screen simply never updates — which is how this same file
  # lost a handler earlier and looked like a rendering bug for a while.
  # The agent asked for something. Whether it lands now is a property of the
  # screen rather than of the change: a wide one holds every panel, so taking it
  # costs nothing and asking would be ceremony. A phone holds one, so taking it
  # would evict whatever is open — possibly mid sentence in the composer — and
  # it waits behind a mark instead.
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

  # The team-status panel's whole claim is "what is running, and who needs
  # you, right now" — the same news `WorkingCopyLive.Index` redraws on.
  def handle_info({event, _payload}, socket)
      when event in [:agents_reported, :agent_started, :agent_stopped] do
    {:noreply, refresh_team_status(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh_team_status(socket) do
    scope = socket.assigns.current_scope
    waiting = waiting_for(scope, socket.assigns.conversation)

    socket
    |> assign(:waiting, waiting)
    |> assign(:copies, team_status(scope, socket.assigns.project, waiting))
  end

  # -- Render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      pending_notifications={@pending_notifications}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
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
      Capping it the way a reading-width page would fought the point of the
      resizable panel beside it. Narrow keeps its cap; a phone is never wide
      enough for it to matter. --%>
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
          screen={@screen}
          open={@open_panels}
          dynamic_view={@dynamic_view}
          dynamic_stories={@dynamic_stories}
          dynamic_story={@dynamic_story}
          offer={@offer}
          activity={@activity}
          waiting={@waiting}
          copies={@copies}
          project_id={@project.id}
          preview_src={@preview_src}
          preview_state={@preview_state}
        />

        <.conversation_column
          :if={@screen == :narrow}
          project={@project}
          conversation={@conversation}
          emptiness={@emptiness}
          questions={@questions}
          items={@items}
          results={@results}
          more_above?={@more_above?}
          pending={@pending}
          talkable?={@talkable?}
          draft={@draft}
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
              project={@project}
              conversation={@conversation}
              emptiness={@emptiness}
              questions={@questions}
              items={@items}
              results={@results}
              more_above?={@more_above?}
              pending={@pending}
              talkable?={@talkable?}
              draft={@draft}
            />
          </LivePane.pane>

          <LivePane.resizer
            group_id="conversation-panes"
            id="conversation-panes-resizer"
            class="group flex w-3 shrink-0 cursor-col-resize select-none items-stretch justify-center self-stretch"
          >
            <span class="w-0.5 rounded-full bg-base-300 transition-colors group-hover:bg-primary/60 group-active:bg-primary">
            </span>
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
              screen={:wide}
              open={@open_panels}
              dynamic_view={@dynamic_view}
              dynamic_stories={@dynamic_stories}
              dynamic_story={@dynamic_story}
              offer={@offer}
              activity={@activity}
              waiting={@waiting}
              copies={@copies}
              project_id={@project.id}
              preview_src={@preview_src}
              preview_state={@preview_state}
            />
          </LivePane.pane>
        </LivePane.group>
      </div>
    </Layouts.app>
    """
  end

  attr :project, :any, required: true
  attr :conversation, :any, required: true
  attr :emptiness, :atom, required: true
  attr :questions, :list, required: true
  attr :items, :list, required: true
  attr :results, :any, required: true
  attr :more_above?, :boolean, required: true
  attr :pending, :list, required: true
  attr :talkable?, :boolean, required: true
  attr :draft, :string, required: true

  # The transcript, its composer, and the header above them — pulled out of
  # `render/1` so a wide screen can put it inside a `LivePane.pane` and a
  # narrow one can put it directly in the stacked column, without maintaining
  # two copies of ~150 lines of chat markup.
  defp conversation_column(assigns) do
    ~H"""
    <div
      data-test="agent-conversation"
      data-project-id={@project.id}
      class="flex min-h-0 min-w-0 flex-1 flex-col"
    >
      <header class="flex shrink-0 items-center gap-2 border-b border-base-300 pb-3">
        <.link
          navigate={~p"/app/projects/#{@project.id}/agent-conversation"}
          class="btn btn-ghost btn-sm btn-square"
          title="All agents"
        >
          <.icon name="hero-arrow-left" class="size-4" />
        </.link>
        <.icon name="hero-cpu-chip" class="size-5 shrink-0" />
        <h1 class="min-w-0 truncate text-lg font-semibold">
          {@conversation && Conversations.display_name(@conversation)}
        </h1>
        <span :if={@conversation} class="shrink-0 font-mono text-xs opacity-40">
          {short_session(@conversation)}
        </span>
      </header>

      <%!-- `overflow-anchor` is what keeps your place when older turns are
          prepended: without it the browser holds the scroll *offset*, so
          inserting above jumps you backwards by exactly the height added.
          `StickToBottom` opens at the newest turn and follows it only while
          you are already down there. --%>
      <div
        id="agent-scroll"
        data-test="conversation-scroll"
        phx-hook="StickToBottom"
        class="min-h-0 flex-1 overflow-y-auto py-4"
        style="overflow-anchor: auto"
      >
        <p
          :if={@conversation == nil}
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

        <div :if={@questions != []} data-test="conversation-questions" class="mb-4 space-y-3">
          <ChatComponents.question
            :for={request <- @questions}
            id={"question-#{request.id}"}
            request={request}
            on_submit="answer_question"
          />
        </div>

        <div
          id="agent-turns"
          class="space-y-2"
          phx-viewport-top={@more_above? && "load_older"}
          data-more-above={to_string(@more_above?)}
        >
          <p :if={@more_above?} data-test="loading-older" class="py-2 text-center text-xs opacity-40">
            loading earlier turns…
          </p>
          <ChatComponents.turn_item
            :for={item <- @items}
            id={"turn-#{item.id}"}
            item={item}
            results={@results}
          />
        </div>
      </div>

      <div
        :for={message <- @pending}
        data-test="agent-pending-message"
        class="flex shrink-0 items-center gap-2 border-t border-base-300 pt-3 text-xs"
      >
        <%!-- The text is not repeated here. It is already in the transcript above,
      as the message it is — printing it again put the same sentence on the
      page twice and read as the message having been sent twice, which is a
      thing that can genuinely happen and must not be imitated by a status
      line. This says what is true of it and offers the one action. --%>
        <span class="opacity-60">
          waiting for the agent to finish its turn
        </span>
        <button
          type="button"
          phx-click="withdraw_message"
          phx-value-ref={message.delivery_ref}
          data-test="agent-withdraw-message"
          class="btn btn-xs btn-ghost"
        >
          Take it back
        </button>
      </div>

      <form
        :if={@talkable?}
        data-test="agent-message-form"
        phx-submit="send_message"
        phx-change="draft"
        class="flex shrink-0 items-center gap-2 border-t border-base-300 pt-3"
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
        <input
          type="text"
          name="message"
          value={@draft}
          autocomplete="off"
          placeholder="say something to this agent"
          data-test="agent-message"
          class="input input-bordered min-w-0 flex-1"
        />
        <%!-- Disabled while it is in flight. `dispatch_message/3` waits on the
      machine — up to the transport's patience if that machine is slow — and
      a button that stays live through that invites the second click, which
      is a second turn and a second answer rather than a wasted one. --%>
        <button type="submit" phx-disable-with="Sending…" class="btn btn-sm btn-primary">
          Send
        </button>
      </form>

      <p
        :if={@conversation != nil and not @talkable?}
        data-test="agent-not-talkable"
        class="shrink-0 border-t border-base-300 pt-3 text-xs opacity-60"
      >
        This agent is not running, so there is nothing to send a message to.
      </p>
    </div>
    """
  end

  @doc false
  # Three tabs along one axis — the artifact, the intent, the work.
  #
  #   * preview  — the running instance. What the thing is right now.
  #   * dynamic  — CodeMySpec's own UI for authoring. Its contents swap; it does
  #                not become more tabs.
  #   * activity — what is happening elsewhere on the project.
  #
  # The attention mark is deliberately not a count of everything in a panel. It
  # means something is *waiting on you*, which is a different claim from
  # something happened, and conflating them is how a badge stops being read.
  attr :screen, :atom, required: true
  attr :open, :list, required: true
  attr :dynamic_view, :string, required: true
  attr :dynamic_stories, :list, required: true
  attr :dynamic_story, :any, required: true
  attr :offer, :any, default: nil
  attr :activity, :list, required: true
  attr :waiting, :list, required: true
  attr :copies, :list, required: true
  attr :project_id, :string, required: true
  attr :preview_src, :string, default: nil
  attr :preview_state, :atom, default: :absent

  # Three tabs on a phone, an accordion on a desk.
  #
  # Stacked headers cost three full-width rows to say nothing when every panel
  # is shut, which on a 390px screen is most of what is above the conversation.
  # John: "the accordion takes up too much space when nothing is selected." A
  # tab strip says the same three words in one row, and the phone already only
  # ever shows one panel — so the accordion was paying for a choice it does not
  # have.
  #
  # A desk keeps the accordion, where the room exists and more than one panel
  # can be open at once.
  @panel_tabs [{:preview, "Preview"}, {:dynamic, "Project"}, {:activity, "Activity"}]

  defp panels(%{screen: :narrow} = assigns) do
    assigns = assign(assigns, :tabs, @panel_tabs)

    ~H"""
    <div data-test="conversation-panels" class="flex w-full shrink-0 flex-col gap-2">
      <div role="tablist" class="flex gap-1">
        <div
          :for={{key, label} <- @tabs}
          data-test={"panel-#{key}"}
          data-panel-open={to_string(key in @open)}
          class="min-w-0 flex-1"
        >
          <button
            type="button"
            data-test={"panel-tab-#{key}"}
            phx-click="toggle_panel"
            phx-value-panel={key}
            class={[
              "flex w-full items-center justify-center gap-1 rounded-box border px-2 py-1.5 text-xs",
              key in @open && "border-primary bg-primary/10 font-semibold text-primary",
              key not in @open && "border-base-300"
            ]}
          >
            <span class="truncate">{label}</span>
            <.panel_attention :if={key == :activity} waiting={@waiting} />
            <.panel_offer :if={key == :dynamic} offer={@offer} />
          </button>
        </div>
      </div>

      <%!-- One body, below the strip, for whichever tab is open. Capped so a
      full panel scrolls inside itself rather than pushing the conversation off
      the bottom. --%>
      <div
        :if={@open != []}
        class="max-h-[40dvh] overflow-y-auto rounded-box border border-base-300 p-3 text-sm"
      >
        <.panel_body
          which={hd(@open)}
          dynamic_view={@dynamic_view}
          dynamic_stories={@dynamic_stories}
          dynamic_story={@dynamic_story}
          offer={@offer}
          activity={@activity}
          waiting={@waiting}
          copies={@copies}
          project_id={@project_id}
          preview_src={@preview_src}
          preview_state={@preview_state}
        />
      </div>
    </div>
    """
  end

  # The outer wrapping div is `LivePane.pane id="conversation-panels"` in
  # `render/1` — this is that pane's content, not a second div of its own.
  #
  # Headers are plain, non-pane flex children living directly inside the
  # vertical `LivePane.group` alongside the pane bodies and resizers, exactly
  # as they were flattened siblings of one hand-rolled flex-col before: the
  # group hook finds panes and resizers by `data-pane-*` attribute, not by
  # walking its own DOM children, so an ordinary header div between them
  # neither needs to be a pane itself nor breaks the ones that are.
  defp panels(assigns) do
    assigns = assign(assigns, :tabs, @panel_tabs)

    ~H"""
    <LivePane.group id="side-panels-body" direction="vertical" auto_save={true} class="min-h-0 flex-1">
      <%= for {{key, label}, index} <- Enum.with_index(@tabs) do %>
        <div
          data-test={"panel-#{key}"}
          data-panel-open={to_string(key in @open)}
          class="shrink-0 self-stretch"
        >
          <%!-- John: "very minimal panel styling... just a hairline with a
          down arrow that expands the panel" — no card, no box, a divider and
          a chevron. The chevron carries the state instead of the border that
          used to: rotated open, flat closed. --%>
          <button
            type="button"
            data-test={"panel-tab-#{key}"}
            phx-click="toggle_panel"
            phx-value-panel={key}
            class="flex w-full items-center gap-1.5 border-b border-base-300 py-1.5 text-sm"
          >
            <%!-- `icon/1` declares `class` as `:string` — unlike a plain
            element it does not accept the `[base, cond && extra]` list form,
            so the conditional is folded into one string here instead. --%>
            <.icon
              name="hero-chevron-right-micro"
              class={
                "size-3.5 shrink-0 opacity-50 transition-transform" <>
                  if(key in @open, do: " rotate-90", else: "")
              }
            />
            <span class="flex-1 text-left">{label}</span>
            <.panel_attention :if={key == :activity} waiting={@waiting} />
            <.panel_offer :if={key == :dynamic} offer={@offer} />
          </button>
        </div>

        <%!-- `order` is the fixed tab index rather than toggle order, for the
        same reason the old `next_panel_open?/3` walked `@tabs` instead of
        `@open`: a handle between "whichever opened most recently" would jump
        to a different visual spot every time a third panel opened. The
        library sorts registered panes by `order`, so this alone is what
        keeps a reopened preview pane back in first position rather than
        wherever it happened to mount.
        Sizing (flex-grow/flex-basis) is inline style the pane hook computes
        and writes itself — no CSS var on `<html>` to hand-roll any more, and
        `auto_save` above persists a drag the same way. Left unset, untouched
        panes simply split the column evenly, same as before. --%>
        <%!-- The pane hook overwrites this element's own `style` wholesale on
        every layout change (`el.style.cssText = ...`), inline `overflow:
        hidden` included — a class here asking for `overflow-y-auto` would
        lose to that every time. The scrolling lives one level in instead, on
        a div the hook never touches. --%>
        <LivePane.pane
          :if={key in @open}
          group_id="side-panels-body"
          id={"panel-body-#{key}"}
          order={index}
          min_size={10}
          class="min-h-0 self-stretch"
        >
          <div class="h-full overflow-y-auto py-2 text-sm">
            <.panel_body
              which={key}
              dynamic_view={@dynamic_view}
              dynamic_stories={@dynamic_stories}
              dynamic_story={@dynamic_story}
              activity={@activity}
              waiting={@waiting}
              copies={@copies}
              project_id={@project_id}
              preview_src={@preview_src}
              preview_state={@preview_state}
            />
          </div>
        </LivePane.pane>

        <LivePane.resizer
          :if={key in @open and next_panel_open?(@tabs, @open, index)}
          group_id="side-panels-body"
          id={"panel-split-#{key}"}
          class="group flex h-3 shrink-0 cursor-row-resize select-none flex-col items-center justify-center self-stretch"
        >
          <span class="h-0.5 w-full rounded-full bg-base-300 transition-colors group-hover:bg-primary/60 group-active:bg-primary">
          </span>
        </LivePane.resizer>
      <% end %>
    </LivePane.group>
    """
  end

  # Whether a resizer belongs after this open panel — there needs to be one
  # between each pair of currently-open panes, and none after the last of
  # them. Drawn from the fixed tab order in `@tabs` rather than from `@open`
  # — `@open` records toggle order, and a handle between "whichever opened
  # most recently" would jump to a different visual spot every time someone
  # opened a third panel.
  defp next_panel_open?(tabs, open, index) do
    case Enum.at(tabs, index + 1) do
      {next_key, _label} -> next_key in open
      nil -> false
    end
  end

  # On the tab header, so a shut tab can still raise it. On a phone the other
  # panels are not merely collapsed but absent, and a question nobody sees is an
  # agent stopped for as long as nobody looks.
  # The agent has something for this tab and has not been given the screen.
  # Only ever rendered on a phone in practice — a wide screen takes the offer
  # the moment it arrives, so there is nothing left to mark.
  attr :offer, :any, default: nil

  defp panel_offer(assigns) do
    ~H"""
    <span :if={@offer} data-test="panel-offer" class="badge badge-xs badge-primary">
      new
    </span>
    """
  end

  attr :waiting, :list, required: true

  defp panel_attention(assigns) do
    ~H"""
    <span :if={@waiting != []} data-test="panel-attention" class="badge badge-xs badge-warning">
      {length(@waiting)}
    </span>
    """
  end

  attr :which, :atom, required: true
  attr :dynamic_view, :string, required: true
  attr :dynamic_stories, :list, required: true
  attr :dynamic_story, :any, required: true
  attr :offer, :any, default: nil
  attr :activity, :list, required: true
  attr :waiting, :list, required: true
  attr :copies, :list, required: true
  attr :project_id, :string, required: true
  attr :preview_src, :string, default: nil
  attr :preview_state, :atom, default: :absent

  # 886's pane, not a second one. It already renders every state a preview can
  # be in and refuses `:running` with no address, and a copy of it here would
  # be the same component with a different set of bugs.
  defp panel_body(%{which: :preview} = assigns) do
    ~H"""
    <div :if={@preview_src} data-test="panel-preview-frame" class="h-full">
      <.pane src={@preview_src} state={@preview_state} title="Your app" />
    </div>
    <div :if={!@preview_src}>
      <p data-test="panel-preview-empty" class="opacity-70">
        No preview is running for this project yet.
      </p>
      <p data-test="panel-preview-remedy" class="mt-1 opacity-70">
        Ask the agent to deploy this project, and the running app appears here.
      </p>
    </div>
    """
  end

  defp panel_body(%{which: :dynamic} = assigns) do
    ~H"""
    <div data-dynamic-view={@dynamic_view}>
      <%!-- One story, when the agent has put one in front of you. Its criteria
      rather than its prose: what the story promises is the part you are being
      asked about. --%>
      <div :if={@dynamic_view == "story" and @dynamic_story}>
        <.link
          navigate={~p"/app/projects/#{@dynamic_story.project_id}/stories/#{@dynamic_story.id}"}
          class="font-semibold link link-hover"
        >
          {@dynamic_story.title}
        </.link>

        <ul class="mt-2 space-y-1">
          <li
            :for={criterion <- @dynamic_story.acceptance_criteria || []}
            data-test="dynamic-criterion"
            class="flex gap-2 text-xs opacity-80"
          >
            <span class={[
              "mt-1 block size-2 shrink-0 rounded-full",
              criterion.verified && "bg-success",
              not criterion.verified && "bg-base-content/20"
            ]} />
            <span>{criterion.description}</span>
          </li>
        </ul>

        <p :if={(@dynamic_story.acceptance_criteria || []) == []} class="mt-2 text-xs opacity-60">
          No criteria yet — this story has not been through Three Amigos.
        </p>
      </div>

      <p :if={@dynamic_view == "story" and is_nil(@dynamic_story)} class="opacity-70">
        That story is not on this project, or has been deleted.
      </p>

      <%!-- Otherwise the project's stories, most recent first. The list is the
      default because it is the one view that is useful before anybody has asked
      for anything in particular. --%>
      <div :if={@dynamic_view != "story"}>
        <p :if={@dynamic_stories == []} class="opacity-70">
          No stories yet. Ask the agent for one.
        </p>

        <ul class="space-y-1">
          <li :for={story <- @dynamic_stories} data-test="dynamic-story">
            <.link
              navigate={~p"/app/projects/#{story.project_id}/stories/#{story.id}"}
              class="flex items-baseline gap-2 link link-hover"
            >
              <span class={[
                "block size-2 shrink-0 rounded-full",
                story.ready_for_dev && "bg-success",
                not story.ready_for_dev && "bg-base-content/20"
              ]} />
              <span class="truncate">{story.title}</span>
            </.link>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  # John: "the most important thing that comes out of here is that we have a
  # place to see what agents need us, and a really fast way to get to the
  # conversation so we can answer the question." A tree, not a feed: every
  # working copy, its agents, and — the one thing worth a color — which of
  # them has a question waiting. Clicking an agent with a chat goes straight
  # to its transcript; that is the whole "fast way".
  defp panel_body(%{which: :activity} = assigns) do
    assigns =
      assigns
      |> assign(:agent_total, Enum.reduce(assigns.copies, 0, &(length(&1.agents) + &2)))
      |> assign(:needing_you, Enum.count(assigns.copies, & &1.question?))

    ~H"""
    <div class="space-y-3">
      <p :if={@copies == []} data-test="team-empty" class="opacity-70">
        No working copies on this project yet.
      </p>

      <div :if={@copies != []} class="flex items-center justify-between gap-2 text-xs">
        <span class="opacity-60">
          {@agent_total} {noun(@agent_total, "agent", "agents")} on {length(@copies)} {noun(
            length(@copies),
            "copy",
            "copies"
          )}
        </span>
        <span
          :if={@needing_you > 0}
          data-test="needs-you"
          class="badge badge-warning badge-sm shrink-0 gap-1"
        >
          <.icon name="hero-question-mark-circle-solid" class="size-3" />
          {@needing_you} {noun(@needing_you, "needs", "need")} you
        </span>
      </div>

      <div :for={copy <- @copies} data-test="team-copy" data-working-copy-id={copy.row.harness.id}>
        <%!-- `heading`, not the raw `label` field: an unrenamed harness's
        label is not blank, it is the auto-generated "the harness at <root>
        on <host>" sentence — `WorkingCopies.display_name/1` is what
        recognizes that shape and shortens it to the root's last segment,
        the same function the working-copy Show page titles itself with. A
        harness someone actually renamed passes straight through unchanged. --%>
        <div class="flex items-center gap-1.5 text-xs font-medium">
          <.icon
            :if={copy.row.harness.main}
            name="hero-star-solid"
            class="size-3 shrink-0 text-primary"
          />
          <span class="min-w-0 flex-1 truncate">{copy.row.heading}</span>
          <span class="shrink-0 opacity-60">{copy.row.liveness.label}</span>
        </div>

        <.link
          :for={a <- copy.agents}
          :if={a.chat}
          navigate={~p"/app/projects/#{@project_id}/agent-conversation/#{a.chat.conversation.id}"}
          data-test="team-agent"
          data-agent-id={a.agent.id}
          data-question={to_string(a.question?)}
          class={[
            "flex items-center gap-1.5 rounded py-1 pl-4 text-xs hover:bg-base-200",
            a.question? && "font-semibold text-warning"
          ]}
        >
          <.icon
            :if={a.question?}
            name="hero-question-mark-circle-solid"
            class="size-3.5 shrink-0"
          />
          <span class="min-w-0 flex-1 truncate">{a.agent.role}</span>
          <span class="shrink-0 opacity-60">{a.liveness.label}</span>
        </.link>

        <div
          :for={a <- copy.agents}
          :if={!a.chat}
          data-test="team-agent"
          data-agent-id={a.agent.id}
          class="flex items-center gap-1.5 py-1 pl-4 text-xs opacity-60"
        >
          <span class="min-w-0 flex-1 truncate">{a.agent.role}</span>
          <span class="shrink-0">{a.liveness.label}</span>
        </div>
      </div>
    </div>
    """
  end

  defp noun(1, singular, _plural), do: singular
  defp noun(_n, _singular, plural), do: plural
end
