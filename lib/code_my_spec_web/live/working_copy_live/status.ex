defmodule CodeMySpecWeb.WorkingCopyLive.Status do
  @moduledoc "Offers, questions and tap-outs for one working copy."
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Notifications
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.WorkingCopyLive.Components
  alias CodeMySpecWeb.WorkingCopyLive.Rows
  alias CodeMySpecWeb.WorkingCopyLive.StoryGraph
  alias CodeMySpecWeb.WorkingCopyLive.StoryGraphLayout
  alias LiveFlow.Changes.NodeChange

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Working copy status",
       flow: nil,
       stories: [],
       story_id: nil,
       selected_requirement_id: nil,
       graph_error: nil,
       needs_layout: false,
       graph_topic: nil
     )}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:working_copy_id, id)
     |> assign(:show_retired, params["show_retired"] == "true")
     |> load()}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("filter", %{"show_retired" => value}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         ~p"/app/projects/#{socket.assigns.project.id}/working-copies/#{socket.assigns.working_copy_id}/status?#{[show_retired: value == "true"]}"
     )}
  end

  def handle_event("select_requirement", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_requirement_id, id)}
  end

  def handle_event("lf:request_layout", _params, socket), do: {:noreply, arrange(socket)}

  def handle_event("lf:node_change", %{"changes" => changes}, socket) do
    # Only presentation changes are accepted. The diagram cannot edit requirements.
    changes = Enum.filter(changes, &(&1["type"] in ["position", "dimensions", "select"]))

    if socket.assigns.flow do
      socket =
        assign(
          socket,
          :flow,
          NodeChange.apply_changes(socket.assigns.flow, changes)
        )

      socket = if socket.assigns.needs_layout, do: arrange(socket), else: socket

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("lf:viewport_change", params, socket) do
    if socket.assigns.flow do
      {:noreply,
       assign(socket, :flow, LiveFlow.State.update_viewport(socket.assigns.flow, params))}
    else
      {:noreply, socket}
    end
  end

  # LiveFlow's editor shortcuts are intentionally inert in this read-only view.
  def handle_event("lf:" <> _event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:lf_node_click, id}, socket),
    do: {:noreply, assign(socket, :selected_requirement_id, id)}

  def handle_info({:graph_updated, project_id}, socket) do
    if project_id == socket.assigns.project.id,
      do: {:noreply, load(socket)},
      else: {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:story_graph, {:ok, flow}, socket) do
    previous = socket.assigns.flow

    changed =
      is_nil(previous) or Map.keys(previous.nodes) != Map.keys(flow.nodes) or
        Map.keys(previous.edges) != Map.keys(flow.edges)

    flow = StoryGraph.preserve_view(flow, previous)
    socket = assign(socket, flow: flow, needs_layout: changed, graph_error: nil)
    {:noreply, if(changed and previous, do: arrange(socket), else: socket)}
  end

  def handle_async(:story_graph, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket, graph_error: "Could not load this story’s requirements. Try Refresh.")}
  end

  defp arrange(%{assigns: %{flow: nil}} = socket), do: socket

  defp arrange(socket) do
    socket
    |> assign(:needs_layout, false)
    |> assign(:flow, StoryGraphLayout.arrange(socket.assigns.flow))
    |> push_event("lf:fit_view", %{padding: 0.1, duration: 0})
  end

  defp load_graph(%{assigns: %{story_id: nil}} = socket),
    do: socket |> cancel_async(:story_graph) |> assign(flow: nil, graph_error: nil)

  defp load_graph(socket) do
    scope = %{
      socket.assigns.current_scope
      | active_working_copy_id: socket.assigns.working_copy_id,
        cwd: socket.assigns.row.harness.root
    }

    story_id = socket.assigns.story_id
    teams = socket.assigns.teams
    agents = teams |> Enum.map(& &1.agent) |> Enum.reject(& &1.retired_at)

    socket
    |> assign(:graph_error, nil)
    |> start_async(:story_graph, fn ->
      {:ok, graph} = Requirements.story_graph(scope, story_id)
      work = Enum.map(agents, &{&1, CodeMySpec.Agents.Work.work_for(scope, &1.role, &1)})
      StoryGraph.build(graph, work, teams)
    end)
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    project = socket.assigns[:project]
    id = socket.assigns.working_copy_id
    row = project && Rows.get(scope, project, id, DateTime.utc_now())

    if row do
      agents =
        Agents.list_agents(scope)
        |> Enum.filter(
          &(&1.working_copy_id == id and (socket.assigns.show_retired or is_nil(&1.retired_at)))
        )

      teams = Enum.map(agents, &team_details(&1, scope, id))

      assigned_id = WorkingCopies.team_story_id(id)
      story = assigned_id && Stories.get_story(scope, assigned_id)
      stories = if story, do: [story], else: []
      story_id = story && story.id

      socket =
        if story_id != socket.assigns.story_id,
          do: assign(socket, flow: nil, selected_requirement_id: nil),
          else: socket

      topic = GraphInputs.topic(project.id)

      subscribe_graph(socket, project.id, topic)

      assign(socket,
        graph_topic: topic,
        stories: stories,
        story_id: story_id,
        row: row,
        agents: Map.new(agents, &{&1.id, "#{&1.role} · #{String.slice(&1.id, 0, 8)}"}),
        teams: teams
      )
      |> load_graph()
    else
      socket
      |> put_flash(:error, "That working copy is not on this project.")
      |> push_navigate(to: ~p"/app/projects")
    end
  end

  defp team_details(agent, scope, copy_id) do
    %{
      agent: agent,
      offer_results:
        Offers.count_by_kind_and_status(scope, working_copy_id: copy_id, agent_id: agent.id)
        |> Enum.reduce(%{}, fn {{_kind, status}, count}, totals ->
          Map.update(totals, status, count, &(&1 + count))
        end),
      questions:
        Notifications.list_question_requests_for_agent(agent.id)
        |> Enum.filter(&(&1.status == "pending"))
        |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime}),
      tap_outs:
        Notifications.list_permission_requests_for_agent(agent.id)
        |> Enum.filter(&(&1.tool_name == "tap_out" and &1.status == "pending"))
        |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    }
  end

  defp subscribe_graph(socket, project_id, topic) do
    if connected?(socket) and socket.assigns.graph_topic != topic do
      unsubscribe_graph(socket.assigns.graph_topic)
      GraphInputs.subscribe(project_id)
    end
  end

  defp unsubscribe_graph(nil), do: :ok
  defp unsubscribe_graph(topic), do: Phoenix.PubSub.unsubscribe(CodeMySpec.PubSub, topic)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      <div :if={assigns[:row]} class="mx-auto w-full max-w-6xl" data-test="working-copy-status-page">
        <.header>
          {@row.heading}
          <:subtitle>Working copy status</:subtitle>
          <:actions><button phx-click="refresh" class="btn btn-sm">Refresh</button></:actions>
        </.header>
        <Components.StoryGraph.graph
          flow={@flow}
          stories={@stories}
          story_id={@story_id}
          selected={@flow && @flow.nodes[@selected_requirement_id]}
          error={@graph_error}
        />
        <form phx-change="filter" class="mt-6">
          <label class="flex items-center gap-2 cursor-pointer">
            <input type="hidden" name="show_retired" value="false" />
            <input
              type="checkbox"
              name="show_retired"
              value="true"
              checked={@show_retired}
              class="toggle toggle-sm"
            />
            <span>Show retired</span>
          </label>
        </form>
        <p :if={@teams == []} class="mt-6 opacity-60">No agents match this filter.</p>
        <div class="mt-6 space-y-4">
          <Components.Agent.detail :for={team <- @teams} team={team} agents={@agents} />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
