defmodule CodeMySpecLocalWeb.RequirementsLive do
  @moduledoc """
  Human interface for the requirements graph.

  All data comes through the `Requirements` context which computes
  nodes on the fly from Files + Problems. The graph view uses
  `GraphProjector` for Mermaid rendering.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Components
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphProjector
  alias CodeMySpec.Projects
  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias CodeMySpecLocalWeb.RequirementsMarkdown

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, project: nil, scope: nil, markdown: nil, graph_data: nil, error: nil)}
  end

  # --- Handle params ---

  @impl true
  def handle_params(%{"project_name" => name, "name" => req_name, "child_id" => child_id}, _uri, %{assigns: %{live_action: :child}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      mod = ProjectSetup.find_step(child_id)

      if mod do
        command_text = generate_command(mod, scope)
        back = "[← Back to #{req_name}](/projects/#{project_slug(project)}/requirements/#{req_name})\n\n"
        markdown = back <> "# #{ProjectSetup.step_name(mod)}\n\n" <> command_text

        {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, error: nil)}
      else
        {:noreply, assign(socket, error: "Step not found: #{child_id}")}
      end
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name, "name" => req_name}, _uri, %{assigns: %{live_action: :show}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      nodes = Requirements.compute_all(scope)

      node = Enum.find(nodes, fn n ->
        n.entity_type == "project" and n.name == req_name
      end)

      if node do
        markdown = build_show_markdown(node, project, scope, nodes)
        {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, error: nil)}
      else
        {:noreply, assign(socket, error: "Requirement not found: #{req_name}")}
      end
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name, "story_id" => story_id, "name" => req_name}, _uri, %{assigns: %{live_action: :story_req_show}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      story = Stories.get_story!(scope, story_id)
      nodes = Requirements.compute_all(scope)

      node = Enum.find(nodes, fn n ->
        n.entity_type == "story" and n.entity_id == story.id and n.name == req_name
      end)

      slug = project_slug(project)

      if node do
        back = "[← Back to #{story.title}](/projects/#{slug}/stories/#{story_id})\n\n"
        markdown = back <> RequirementsMarkdown.show(%{node: node})
        {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, graph_data: nil, error: nil)}
      else
        {:noreply, assign(socket, error: "Requirement not found: #{req_name}")}
      end
    else
      {:error, msg} -> {:noreply, assign(socket, error: "#{msg}")}
    end
  end

  def handle_params(%{"project_name" => name, "component_id" => component_id, "name" => req_name}, _uri, %{assigns: %{live_action: :component_req_show}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      component = Components.get_component!(scope, component_id)
      nodes = Requirements.compute_all(scope)

      node = Enum.find(nodes, fn n ->
        n.entity_type == "component" and n.entity_id == component.id and n.name == req_name
      end)

      slug = project_slug(project)

      if node do
        back = "[← Back to #{component.module_name}](/projects/#{slug}/components/#{component_id})\n\n"
        markdown = back <> RequirementsMarkdown.show(%{node: node})
        {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, graph_data: nil, error: nil)}
      else
        {:noreply, assign(socket, error: "Requirement not found: #{req_name}")}
      end
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name}, _uri, %{assigns: %{live_action: :components_graph}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      graph_data = GraphProjector.components_graph(scope)

      {:noreply,
       assign(socket,
         project: project,
         scope: scope,
         markdown: nil,
         graph_data: graph_data,
         error: nil
       )}
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name}, _uri, %{assigns: %{live_action: :components}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      components = Components.list_components(scope)
      nodes = Requirements.compute_all(scope)
      slug = project_slug(project)

      lines =
        Enum.map_join(components, "\n", fn component ->
          comp_nodes = Enum.filter(nodes, &(&1.entity_type == "component" and &1.entity_id == component.id))
          total = length(comp_nodes)
          satisfied = Enum.count(comp_nodes, & &1.satisfied)
          check = if satisfied == total and total > 0, do: "[x]", else: "[ ]"
          "- #{check} [#{component.module_name}](/projects/#{slug}/components/#{component.id}) (#{satisfied}/#{total})"
        end)

      back = "[← Back to project](/projects/#{slug})\n\n"
      markdown = back <> "# Components\n\n#{lines}\n"

      {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, graph_data: nil, error: nil)}
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name, "component_id" => component_id}, _uri, %{assigns: %{live_action: :component_graph}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      graph_data = GraphProjector.component_graph(scope, component_id)

      {:noreply,
       assign(socket,
         project: project,
         scope: scope,
         markdown: nil,
         graph_data: graph_data,
         error: nil
       )}
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name, "component_id" => component_id}, _uri, %{assigns: %{live_action: :component_show}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      component = Components.get_component!(scope, component_id)
      nodes = Requirements.compute_all(scope)
      markdown = build_component_show_markdown(component, project, nodes)
      {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, graph_data: nil, error: nil)}
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name, "story_id" => story_id}, _uri, %{assigns: %{live_action: :story_show}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      story = Stories.get_story!(scope, story_id)
      nodes = Requirements.compute_all(scope)
      markdown = build_story_show_markdown(story, project, nodes)
      {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, graph_data: nil, error: nil)}
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name}, _uri, %{assigns: %{live_action: :stories}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      {:ok, stories} = Stories.list_project_stories(scope)
      nodes = Requirements.compute_all(scope)
      slug = project_slug(project)

      lines =
        Enum.map_join(stories, "\n", fn story ->
          story_nodes = Enum.filter(nodes, &(&1.entity_type == "story" and &1.entity_id == story.id))
          total = length(story_nodes)
          satisfied = Enum.count(story_nodes, & &1.satisfied)
          check = if satisfied == total and total > 0, do: "[x]", else: "[ ]"
          "- #{check} [#{story.title}](/projects/#{slug}/stories/#{story.id}) (#{satisfied}/#{total})"
        end)

      back = "[← Back to requirements](/projects/#{slug}/requirements)\n\n"
      markdown = back <> "# Stories\n\n#{lines}\n"

      {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, graph_data: nil, error: nil)}
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name}, _uri, %{assigns: %{live_action: :graph}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      graph_data = GraphProjector.project_graph(scope)

      {:noreply,
       assign(socket,
         project: project,
         scope: scope,
         markdown: nil,
         graph_data: graph_data,
         error: nil
       )}
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name}, _uri, socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      nodes = Requirements.compute_all(scope)
      actionable = Requirements.next_actionable_project(scope)

      markdown =
        RequirementsMarkdown.index(%{project: project, nodes: nodes, actionable: actionable})
        |> rewrite_req_links(project)
        |> append_nav_links(project)

      {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, error: nil)}
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  # --- Events ---

  @impl true
  def handle_event("node_clicked", %{"name" => name, "entity_type" => "project"}, socket) do
    slug = project_slug(socket.assigns.project)
    {:noreply, push_navigate(socket, to: "/projects/#{slug}/requirements/#{name}")}
  end

  def handle_event("node_clicked", %{"entity_type" => "story", "entity_id" => id}, socket) do
    slug = project_slug(socket.assigns.project)
    {:noreply, push_navigate(socket, to: "/projects/#{slug}/stories/#{id}")}
  end

  def handle_event("node_clicked", _params, socket) do
    {:noreply, socket}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error} class="text-red-400">
      <h1>Error</h1>
      <p>{@error}</p>
    </div>

    <div :if={@graph_data} id="graph-page">
      <div class="mb-4">
        <.link navigate={"/projects/#{project_slug(@project)}/requirements"} class="text-blue-400 hover:underline">
          ← Back to requirements
        </.link>
      </div>
      <h1 class="text-xl font-bold mb-6">Requirements Graph</h1>
      <div class="flex gap-4 text-sm mb-4">
        <span class="flex items-center gap-1"><span class="w-3 h-3 rounded-full bg-[#60a5fa] inline-block"></span> Satisfied</span>
        <span class="flex items-center gap-1"><span class="w-3 h-3 rounded-full bg-[#4ade80] inline-block"></span> Actionable</span>
        <span class="flex items-center gap-1"><span class="w-3 h-3 rounded-full bg-[#fbbf24] inline-block"></span> Blocked</span>
      </div>
      <div
        id="sigma-graph"
        phx-hook="SigmaGraph"
        data-graph={Jason.encode!(@graph_data)}
        phx-update="ignore"
        style="width: 95vw; height: 85vh; margin-left: calc(-50vw + 50%); background: #0f172a; border-radius: 8px;"
      >
      </div>
    </div>

    <div :if={@markdown} class="prose prose-invert max-w-none">
      {raw(CodeMySpecLocalWeb.markdown_to_html(@markdown))}
    </div>
    """
  end

  # --- Markdown builders ---

  defp build_show_markdown(node, project, scope, all_nodes) do
    slug = project_slug(project)
    back = "[← Back to requirements](/projects/#{slug}/requirements)\n\n"

    status = if node.satisfied, do: "Satisfied", else: "Not satisfied"
    header = "# #{node.name}\n\n#{node.description}\n\n**#{status}**\n"

    body =
      case node.name do
        "project_setup" ->
          build_setup_checklist(scope, slug, node.name)

        _ ->
          if node.satisfied_by && !node.satisfied do
            "\n\n" <> generate_command(node.satisfied_by, scope)
          else
            ""
          end
      end

    # Prereqs and dependents
    project_nodes = Enum.filter(all_nodes, &(&1.entity_type == "project"))

    prereq_links =
      node.prerequisites
      |> Enum.map(fn prereq_name ->
        prereq = Enum.find(project_nodes, &(&1.name == prereq_name))
        status_icon = if prereq && prereq.satisfied, do: "x", else: " "
        "[#{status_icon}] [#{prereq_name}](/projects/#{slug}/requirements/#{prereq_name})"
      end)

    dependent_links =
      project_nodes
      |> Enum.filter(fn n -> node.name in n.prerequisites end)
      |> Enum.map(fn n ->
        status_icon = if n.satisfied, do: "x", else: " "
        "[#{status_icon}] [#{n.name}](/projects/#{slug}/requirements/#{n.name})"
      end)

    nav = ""
    nav = if prereq_links != [], do: nav <> "\n\n---\n\n### Depends on\n\n" <> Enum.join(prereq_links, " | "), else: nav
    nav = if dependent_links != [], do: nav <> "\n\n### Unblocks\n\n" <> Enum.join(dependent_links, " | "), else: nav

    back <> header <> body <> nav
  end

  defp build_setup_checklist(scope, slug, req_name) do
    steps = ProjectSetup.setup_steps()

    {items, _} =
      Enum.map_reduce(steps, scope, fn mod, acc_scope ->
        satisfied =
          case mod.evaluate(acc_scope, %{}) do
            {:ok, :valid} -> true
            _ -> false
          end

        step_id = ProjectSetup.step_id(mod)
        step_name = ProjectSetup.step_name(mod)
        check = if satisfied, do: "[x]", else: "[ ]"
        link = "[#{step_name}](/projects/#{slug}/requirements/#{req_name}/#{step_id})"
        {"- #{check} #{link}", acc_scope}
      end)

    done = Enum.count(items, &String.starts_with?(&1, "- [x]"))
    total = length(items)

    "\n\n## Steps (#{done}/#{total})\n\n" <> Enum.join(items, "\n")
  end

  defp build_component_show_markdown(component, project, nodes) do
    slug = project_slug(project)
    comp_nodes = Enum.filter(nodes, &(&1.entity_type == "component" and &1.entity_id == component.id))
    total = length(comp_nodes)
    satisfied = Enum.count(comp_nodes, & &1.satisfied)
    actionable = Enum.filter(comp_nodes, fn n -> !n.satisfied and n.satisfied_by end)
    actionable_names = MapSet.new(actionable, & &1.name)

    back = "[← Back to requirements](/projects/#{slug}/requirements)\n\n"
    header = "# #{component.module_name} — Requirements (#{satisfied}/#{total})\n\n"
    type_info = "Type: **#{component.type}**\n\n"

    lines =
      Enum.map_join(comp_nodes, "\n", fn n ->
        check = if n.satisfied, do: "[x]", else: "[ ]"
        tag = if MapSet.member?(actionable_names, n.name), do: " *(actionable)*", else: ""
        "- #{check} [**#{n.name}**](/projects/#{slug}/components/#{component.id}/requirements/#{n.name}) — #{n.description}#{tag}"
      end)

    back <> header <> type_info <> lines <> "\n"
  end

  defp build_story_show_markdown(story, project, nodes) do
    slug = project_slug(project)
    story_nodes = Enum.filter(nodes, &(&1.entity_type == "story" and &1.entity_id == story.id))
    total = length(story_nodes)
    satisfied = Enum.count(story_nodes, & &1.satisfied)
    actionable_names = story_nodes |> Enum.reject(& &1.satisfied) |> MapSet.new(& &1.name)

    back = "[← Back to stories](/projects/#{slug}/stories)\n\n"
    header = "# #{story.title} — Requirements (#{satisfied}/#{total})\n\n"

    lines =
      Enum.map_join(story_nodes, "\n", fn n ->
        check = if n.satisfied, do: "[x]", else: "[ ]"
        tag = if MapSet.member?(actionable_names, n.name), do: " *(actionable)*", else: ""
        "- #{check} [**#{n.name}**](/projects/#{slug}/stories/#{story.id}/requirements/#{n.name}) — #{n.description}#{tag}"
      end)

    back <> header <> lines <> "\n"
  end

  defp rewrite_req_links(markdown, project) do
    slug = project_slug(project)
    String.replace(markdown, ~r/\*\*([a-z_\/]+)\*\*/, "[**\\1**](/projects/#{slug}/requirements/\\1)")
  end

  defp append_nav_links(markdown, project) do
    slug = project_slug(project)
    markdown <> "\n\n---\n\n[View Stories ->](/projects/#{slug}/stories) | [View Components ->](/projects/#{slug}/components) | [View Graph ->](/projects/#{slug}/requirements/graph) | [Components Graph ->](/projects/#{slug}/components/graph)"
  end

  # --- Helpers ---

  defp generate_command(task_module, scope) do
    case task_module.command(scope, %{}) do
      {:ok, text} -> text
      {:error, reason} -> "Error: #{inspect(reason)}"
    end
  rescue
    error -> "Error: #{inspect(error)}"
  end

  defp load_project_and_scope(name) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      {:ok, project, scope}
    end
  end

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
