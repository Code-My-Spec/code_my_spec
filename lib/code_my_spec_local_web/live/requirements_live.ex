defmodule CodeMySpecLocalWeb.RequirementsLive do
  @moduledoc """
  Human interface for the requirements graph.

  All data comes through the `Requirements` context which computes
  nodes on the fly from Files + Problems. The graph view uses
  `GraphProjector` for Mermaid rendering.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpec.Components
  alias CodeMySpec.Projects
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphProjector
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias CodeMySpecLocalWeb.RequirementsMarkdown

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()

    {:ok,
     assign(socket,
       projects: projects,
       project: nil,
       scope: nil,
       markdown: nil,
       graph_data: nil,
       error: nil,
       setup_error: nil
     )}
  end

  # --- Handle params ---

  @impl true
  def handle_params(%{"project_name" => name, "name" => req_name, "child_id" => child_id}, _uri, %{assigns: %{live_action: :child}} = socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
        mod = ProjectSetup.find_step(child_id)

        if mod do
          command_text = generate_command(mod, scope)
          back = "[← Back to #{req_name}](/projects/#{project_slug(project)}/requirements/#{req_name})\n\n"
          markdown = back <> "# #{ProjectSetup.step_name(mod)}\n\n" <> command_text

          {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, error: nil)}
        else
          {:noreply, assign(socket, error: "Step not found: #{child_id}")}
        end

      {:error, msg} ->
        {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name, "name" => req_name}, _uri, %{assigns: %{live_action: :show}} = socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
        handle_show_for_project(project, scope, req_name, socket)

      {:error, msg} ->
        {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name, "story_id" => story_id, "name" => req_name}, _uri, %{assigns: %{live_action: :story_req_show}} = socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
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

      {:error, msg} ->
        {:noreply, assign(socket, error: "#{msg}")}
    end
  end

  def handle_params(%{"project_name" => name, "component_id" => component_id, "name" => req_name}, _uri, %{assigns: %{live_action: :component_req_prompt}} = socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
        component = Components.get_component!(scope, component_id)
        nodes = Requirements.compute_all(scope)

        node = Enum.find(nodes, fn n ->
          n.entity_type == "component" and n.entity_id == component.id and n.name == req_name
        end)

        slug = project_slug(project)

        if node && node.satisfied_by do
          task = %{component_id: component_id, component_module_name: component.module_name}
          prompt_text = fetch_prompt_text(node.satisfied_by, scope, task)

          back = "[← Back to #{req_name}](/projects/#{slug}/components/#{component_id}/requirements/#{req_name})\n\n"
          markdown = back <> "# Prompt: #{component.module_name} / #{req_name}\n\n" <> prompt_text

          {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, graph_data: nil, error: nil)}
        else
          {:noreply, assign(socket, error: "Requirement #{req_name} has no task module")}
        end

      {:error, msg} ->
        {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name, "component_id" => component_id, "name" => req_name}, _uri, %{assigns: %{live_action: :component_req_show}} = socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
        component = Components.get_component!(scope, component_id)
        nodes = Requirements.compute_all(scope)

        node = Enum.find(nodes, fn n ->
          n.entity_type == "component" and n.entity_id == component.id and n.name == req_name
        end)

        slug = project_slug(project)

        if node do
          back = "[← Back to #{component.module_name}](/projects/#{slug}/components/#{component_id})\n\n"
          prompt_link = prompt_link(node, slug, component_id, req_name)
          markdown = back <> RequirementsMarkdown.show(%{node: node}) <> prompt_link
          {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, graph_data: nil, error: nil)}
        else
          {:noreply, assign(socket, error: "Requirement not found: #{req_name}")}
        end

      {:error, msg} ->
        {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name}, _uri, %{assigns: %{live_action: :components_graph}} = socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
        graph_data = GraphProjector.components_graph(scope)

        {:noreply,
         assign(socket,
           project: project,
           scope: scope,
           markdown: nil,
           graph_data: graph_data,
           error: nil
         )}

      {:error, msg} ->
        {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name}, _uri, %{assigns: %{live_action: :components}} = socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
        components = Components.list_components(scope)
        nodes = Requirements.compute_all(scope)
        slug = project_slug(project)

        lines = Enum.map_join(components, "\n", &component_line(&1, nodes, slug))

        back = "[← Back to project](/projects/#{slug})\n\n"
        markdown = back <> "# Components\n\n#{lines}\n"

        {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, graph_data: nil, error: nil)}

      {:error, msg} ->
        {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name, "component_id" => component_id}, _uri, %{assigns: %{live_action: :component_graph}} = socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
        graph_data = GraphProjector.component_graph(scope, component_id)

        {:noreply,
         assign(socket,
           project: project,
           scope: scope,
           markdown: nil,
           graph_data: graph_data,
           error: nil
         )}

      {:error, msg} ->
        {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name, "component_id" => component_id}, _uri, %{assigns: %{live_action: :component_show}} = socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
        component = Components.get_component!(scope, component_id)
        nodes = Requirements.compute_all(scope)
        markdown = build_component_show_markdown(component, project, nodes)
        {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, graph_data: nil, error: nil)}

      {:error, msg} ->
        {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name, "story_id" => story_id}, _uri, %{assigns: %{live_action: :story_show}} = socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
        story = Stories.get_story!(scope, story_id)
        nodes = Requirements.compute_all(scope)
        markdown = build_story_show_markdown(story, project, nodes)
        {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, graph_data: nil, error: nil)}

      {:error, msg} ->
        {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name}, _uri, %{assigns: %{live_action: :stories}} = socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
        {:ok, stories} = Stories.list_project_stories(scope)
        nodes = Requirements.compute_all(scope)
        slug = project_slug(project)

        lines = Enum.map_join(stories, "\n", &story_line(&1, nodes, slug))

        back = "[← Back to requirements](/projects/#{slug}/requirements)\n\n"
        markdown = back <> "# Stories\n\n#{lines}\n"

        {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, graph_data: nil, error: nil)}

      {:error, msg} ->
        {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name}, _uri, %{assigns: %{live_action: :graph}} = socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
        graph_data = GraphProjector.project_graph(scope)

        {:noreply,
         assign(socket,
           project: project,
           scope: scope,
           markdown: nil,
           graph_data: graph_data,
           error: nil
         )}

      {:error, msg} ->
        {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name}, _uri, socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
        nodes = Requirements.compute_all(scope)
        actionable = Requirements.next_actionable_project(scope)

        markdown =
          RequirementsMarkdown.index(%{project: project, nodes: nodes, actionable: actionable})
          |> rewrite_req_links(project)

        {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, error: nil)}

      {:error, msg} ->
        {:noreply, assign(socket, error: msg)}
    end
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={@project}
      section={section_for(@live_action)}
    >
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={@setup_error} data-role="setup-error" role="alert" class="alert alert-error my-4">
        <span>Setup error: {@setup_error}</span>
      </div>

      <div :if={@graph_data} id="graph-page">
        <div class="mb-4">
          <.link navigate={"/projects/#{project_slug(@project)}/requirements"} class="btn btn-ghost btn-sm gap-1">
            ← Back to requirements
          </.link>
        </div>
        <h1 class="text-2xl font-bold mb-4">Requirements Graph</h1>
        <div class="flex flex-wrap gap-4 text-sm mb-4">
          <span class="flex items-center gap-2"><span class="w-3 h-3 rounded-full bg-primary inline-block"></span> Satisfied</span>
          <span class="flex items-center gap-2"><span class="w-3 h-3 rounded-full bg-success inline-block"></span> Actionable</span>
          <span class="flex items-center gap-2"><span class="w-3 h-3 rounded-full bg-warning inline-block"></span> Blocked</span>
        </div>
        <div
          id="sigma-graph"
          phx-hook="SigmaGraph"
          data-graph={Jason.encode!(@graph_data)}
          phx-update="ignore"
          class="rounded-box border border-base-300 bg-base-200"
          style="width: 100%; height: 80vh;"
        >
        </div>
      </div>

      <article :if={@markdown} class="prose max-w-none">
        {raw(CodeMySpecLocalWeb.markdown_to_html(@markdown))}
      </article>
    </Layouts.app>
    """
  end

  defp section_for(action)
       when action in [:components, :components_graph, :component_show, :component_graph,
                       :component_req_show, :component_req_prompt],
       do: :components

  defp section_for(action) when action in [:stories, :story_show, :story_req_show], do: :stories
  defp section_for(:graph), do: :requirements_graph
  defp section_for(_), do: :requirements

  # --- Markdown builders ---

  defp build_show_markdown(node, project, scope, all_nodes) do
    slug = project_slug(project)
    back = "[← Back to requirements](/projects/#{slug}/requirements)\n\n"
    header = build_show_header(node)
    nav = build_show_nav(node, all_nodes, slug)

    case build_show_body(node, scope, slug) do
      {:ok, body} -> {:ok, back <> header <> body <> nav}
      {:error, reason} -> {:error, reason, back <> header <> nav}
    end
  end

  defp build_show_header(node) do
    status = if node.satisfied, do: "Satisfied", else: "Not satisfied"
    "# #{node.name}\n\n#{node.description}\n\n**#{status}**\n"
  end

  defp build_show_body(%{render_command_always?: true, satisfied_by: satisfied_by}, scope, _slug)
       when not is_nil(satisfied_by) do
    case satisfied_by.command(scope, %{}) do
      {:ok, text} -> {:ok, "\n\n" <> text}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_show_body(%{satisfied_by: satisfied_by, satisfied: false}, scope, _slug)
       when not is_nil(satisfied_by),
       do: {:ok, "\n\n" <> generate_command(satisfied_by, scope)}

  defp build_show_body(_node, _scope, _slug), do: {:ok, ""}

  defp build_show_nav(node, all_nodes, slug) do
    project_nodes = Enum.filter(all_nodes, &(&1.entity_type == "project"))
    prereq_links = prereq_links(node, project_nodes, slug)
    dependent_links = dependent_links(node, project_nodes, slug)

    prereq_section(prereq_links) <> dependent_section(dependent_links)
  end

  defp prereq_links(node, project_nodes, slug) do
    Enum.map(node.prerequisites, fn prereq_name ->
      prereq = Enum.find(project_nodes, &(&1.name == prereq_name))
      status_icon = if prereq && prereq.satisfied, do: "x", else: " "
      "[#{status_icon}] [#{prereq_name}](/projects/#{slug}/requirements/#{prereq_name})"
    end)
  end

  defp dependent_links(node, project_nodes, slug) do
    project_nodes
    |> Enum.filter(fn n -> node.name in n.prerequisites end)
    |> Enum.map(fn n ->
      status_icon = if n.satisfied, do: "x", else: " "
      "[#{status_icon}] [#{n.name}](/projects/#{slug}/requirements/#{n.name})"
    end)
  end

  defp prereq_section([]), do: ""
  defp prereq_section(links), do: "\n\n---\n\n### Depends on\n\n" <> Enum.join(links, " | ")

  defp dependent_section([]), do: ""
  defp dependent_section(links), do: "\n\n### Unblocks\n\n" <> Enum.join(links, " | ")

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

  # --- Helpers ---

  defp fetch_prompt_text(satisfied_by, scope, task) do
    case satisfied_by.command(scope, task) do
      {:ok, text} -> text
      {:error, reason} -> "Error generating prompt: #{inspect(reason)}"
    end
  end

  defp prompt_link(%{satisfied_by: nil}, _slug, _component_id, _req_name), do: ""

  defp prompt_link(_node, slug, component_id, req_name),
    do: "\n\n[View Prompt →](/projects/#{slug}/components/#{component_id}/requirements/#{req_name}/prompt)\n"

  defp check_mark(satisfied, total) when satisfied == total and total > 0, do: "[x]"
  defp check_mark(_satisfied, _total), do: "[ ]"

  defp component_line(component, nodes, slug) do
    comp_nodes = Enum.filter(nodes, &(&1.entity_type == "component" and &1.entity_id == component.id))
    total = length(comp_nodes)
    satisfied = Enum.count(comp_nodes, & &1.satisfied)
    "- #{check_mark(satisfied, total)} [#{component.module_name}](/projects/#{slug}/components/#{component.id}) (#{satisfied}/#{total})"
  end

  defp story_line(story, nodes, slug) do
    story_nodes = Enum.filter(nodes, &(&1.entity_type == "story" and &1.entity_id == story.id))
    total = length(story_nodes)
    satisfied = Enum.count(story_nodes, & &1.satisfied)
    "- #{check_mark(satisfied, total)} [#{story.title}](/projects/#{slug}/stories/#{story.id}) (#{satisfied}/#{total})"
  end

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

  defp handle_show_for_project(project, scope, req_name, socket) do
    nodes = Requirements.compute_all(scope)

    node =
      Enum.find(nodes, fn n ->
        n.entity_type == "project" and n.name == req_name
      end)

    case node && build_show_markdown(node, project, scope, nodes) do
      {:ok, markdown} ->
        {:noreply,
         assign(socket,
           project: project,
           scope: scope,
           markdown: markdown,
           error: nil,
           setup_error: nil
         )}

      {:error, reason, markdown} ->
        {:noreply,
         assign(socket,
           project: project,
           scope: scope,
           markdown: markdown,
           error: nil,
           setup_error: inspect(reason)
         )}

      nil_or_false when nil_or_false in [nil, false] ->
        {:noreply, assign(socket, error: "Requirement not found: #{req_name}")}
    end
  end
end
