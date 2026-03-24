defmodule CodeMySpecLocalWeb.RequirementsLive do
  @moduledoc """
  Human interface for project requirements.

  Generates markdown (same source as the LLM API), renders via MDEx.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Components
  alias CodeMySpec.Projects
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphProjector
  alias CodeMySpec.Setup.SetupSteps
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias CodeMySpecLocalWeb.RequirementsMarkdown

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, project: nil, scope: nil, markdown: nil, mermaid: nil, error: nil)}
  end

  # --- Handle params ---

  @impl true
  def handle_params(%{"project_name" => name, "name" => req_name, "child_id" => child_id}, _uri, %{assigns: %{live_action: :child}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      step = Enum.find(SetupSteps.all(), &(&1.id == child_id))

      if step do
        command_text = generate_command(step.module, scope, project)
        back = "[← Back to #{req_name}](/projects/#{project_slug(project)}/requirements/#{req_name})\n\n"
        markdown = back <> "# #{step.name}\n\n" <> command_text

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
      project = Repo.preload(project, :requirements)
      requirement = Enum.find(project.requirements, &(&1.name == req_name))

      if requirement do
        names = build_entity_names(scope)
        markdown = build_show_markdown(requirement, project, scope, names)
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
      story =
        Stories.get_story!(scope, story_id)
        |> Repo.preload([:requirements, :component])

      requirement = Enum.find(story.requirements, &(&1.name == req_name))
      slug = project_slug(project)
      names = build_entity_names(scope)

      if requirement do
        markdown = build_entity_req_show_markdown(requirement, story.title, "/projects/#{slug}/stories/#{story_id}", scope, project, names)
        {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, mermaid: nil, error: nil)}
      else
        {:noreply, assign(socket, error: "Requirement not found: #{req_name}")}
      end
    else
      {:error, msg} -> {:noreply, assign(socket, error: "#{msg}")}
    end
  end

  def handle_params(%{"project_name" => name, "component_id" => component_id, "name" => req_name}, _uri, %{assigns: %{live_action: :component_req_show}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      component =
        Components.get_component!(scope, component_id)
        |> Repo.preload([:requirements, :dependencies])

      requirement = Enum.find(component.requirements, &(&1.name == req_name))
      slug = project_slug(project)
      names = build_entity_names(scope)

      if requirement do
        markdown = build_entity_req_show_markdown(requirement, component.module_name, "/projects/#{slug}/components/#{component_id}", scope, project, names)
        {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, mermaid: nil, error: nil)}
      else
        {:noreply, assign(socket, error: "Requirement not found: #{req_name}")}
      end
    else
      {:error, msg} -> {:noreply, assign(socket, error: "#{msg}")}
    end
  end

  def handle_params(%{"project_name" => name}, _uri, %{assigns: %{live_action: :components}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      components =
        Components.list_components(scope)
        |> Repo.preload(:requirements)

      slug = project_slug(project)

      lines =
        Enum.map_join(components, "\n", fn component ->
          reqs = component.requirements || []
          total = length(reqs)
          satisfied = Enum.count(reqs, & &1.satisfied)
          check = if satisfied == total and total > 0, do: "[x]", else: "[ ]"
          "- #{check} [#{component.module_name}](/projects/#{slug}/components/#{component.id}) (#{satisfied}/#{total})"
        end)

      back = "[← Back to project](/projects/#{slug})\n\n"
      markdown = back <> "# Components\n\n#{lines}\n"

      {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, mermaid: nil, error: nil)}
    else
      {:error, msg} -> {:noreply, assign(socket, error: "#{msg}")}
    end
  end

  def handle_params(%{"project_name" => name, "component_id" => component_id}, _uri, %{assigns: %{live_action: :component_show}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      component =
        Components.get_component!(scope, component_id)
        |> Repo.preload([:requirements, :dependencies])

      markdown = build_component_show_markdown(component, project, scope)
      {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, mermaid: nil, error: nil)}
    else
      {:error, msg} -> {:noreply, assign(socket, error: "#{msg}")}
    end
  end

  def handle_params(%{"project_name" => name, "story_id" => story_id}, _uri, %{assigns: %{live_action: :story_show}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      story =
        Stories.get_story!(scope, story_id)
        |> Repo.preload([:requirements, :component])

      markdown = build_story_show_markdown(story, project, scope)
      {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, mermaid: nil, error: nil)}
    else
      {:error, msg} -> {:noreply, assign(socket, error: "#{msg}")}
    end
  end

  def handle_params(%{"project_name" => name}, _uri, %{assigns: %{live_action: :stories}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      {:ok, stories} = Stories.list_project_stories(scope)
      stories = Repo.preload(stories, :requirements)
      slug = project_slug(project)

      lines =
        Enum.map_join(stories, "\n", fn story ->
          reqs = story.requirements || []
          total = length(reqs)
          satisfied = Enum.count(reqs, & &1.satisfied)
          check = if satisfied == total and total > 0, do: "[x]", else: "[ ]"
          "- #{check} [#{story.title}](/projects/#{slug}/stories/#{story.id}) (#{satisfied}/#{total})"
        end)

      back = "[← Back to requirements](/projects/#{slug}/requirements)\n\n"
      markdown = back <> "# Stories\n\n#{lines}\n"

      {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, mermaid: nil, error: nil)}
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name}, _uri, %{assigns: %{live_action: :graph}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      mermaid = GraphProjector.project_graph(scope)

      {:noreply,
       assign(socket,
         project: project,
         scope: scope,
         markdown: nil,
         mermaid: mermaid,
         error: nil
       )}
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name}, _uri, socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      project = Repo.preload(project, :requirements)
      requirements = project.requirements || []
      project = %{project | requirements: requirements}
      actionable = Requirements.next_actionable(scope, project)

      markdown =
        RequirementsMarkdown.index(%{project: project, requirements: requirements, actionable: actionable})
        |> rewrite_api_links_to_ui(project)
        |> append_graph_link(project)

      {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, error: nil)}
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error} class="text-red-400">
      <h1>Error</h1>
      <p>{@error}</p>
    </div>

    <div :if={@mermaid} id="graph-page">
      <div class="mb-4">
        <.link navigate={"/projects/#{project_slug(@project)}/requirements"} class="text-blue-400 hover:underline">
          ← Back to requirements
        </.link>
      </div>
      <h1 class="text-xl font-bold mb-6">Requirements Graph</h1>
      <div id="mermaid-graph" phx-hook="Mermaid" data-graph={@mermaid} phx-update="ignore">
        <pre class="mermaid">{@mermaid}</pre>
      </div>
    </div>

    <div :if={@markdown} class="prose prose-invert max-w-none">
      {raw(CodeMySpecLocalWeb.markdown_to_html(@markdown))}
    </div>
    """
  end

  # --- Markdown builders ---

  defp build_show_markdown(requirement, project, scope, names) do
    slug = project_slug(project)
    back = "[← Back to requirements](/projects/#{slug}/requirements)\n\n"

    status = if requirement.satisfied, do: "✓ Satisfied", else: "Not satisfied"
    score = if requirement.score, do: " (#{Float.round(requirement.score, 2)})", else: ""

    header = "# #{requirement.name}\n\n#{requirement.description}\n\n**#{status}#{score}**\n"

    body =
      case get_checklist(requirement) do
        # scope: :children — show the child checklist
        items when is_list(items) ->
          done = Enum.count(items, &get_field(&1, "satisfied"))
          total = length(items)

          lines =
            Enum.map_join(items, "\n", fn item ->
              name = get_field(item, "name")
              id = get_field(item, "id")
              satisfied = get_field(item, "satisfied")
              detail = get_field(item, "detail")

              check = if satisfied, do: "[x]", else: "[ ]"
              link = "[#{name}](/projects/#{slug}/requirements/#{requirement.name}/#{id})"
              detail_text = if detail && !satisfied, do: " — #{detail}", else: ""

              "- #{check} #{link}#{detail_text}"
            end)

          "\n\n## Steps (#{done}/#{total})\n\n#{lines}"

        # Direct — show the command output
        nil ->
          if requirement.satisfied_by do
            "\n\n" <> generate_command(requirement.satisfied_by, scope, project)
          else
            ""
          end
      end

    # Build navigation: depends_on (blockers) and next (what this unblocks)
    nav = build_requirement_nav(requirement, project, names)

    back <> header <> body <> nav
  end

  defp build_requirement_nav(requirement, project, names) do
    slug = project_slug(project)
    all_requirements = project.requirements || []

    # Same-entity deps
    same_deps =
      (requirement.depends_on || [])
      |> Enum.filter(fn edge -> edge["entity_type"] == "project" end)
      |> Enum.map(fn edge ->
        name = edge["requirement_name"]
        req = Enum.find(all_requirements, &(&1.name == name))
        status = if req && req.satisfied, do: "✓", else: "○"
        "#{status} [#{name}](/projects/#{slug}/requirements/#{name})"
      end)

    # Cross-entity deps (scope: :dependencies or :children)
    cross_deps = render_cross_entity_deps(requirement, slug, names)

    # Same-entity dependents
    dependents =
      all_requirements
      |> Enum.filter(fn r ->
        (r.depends_on || [])
        |> Enum.any?(fn edge ->
          edge["entity_type"] == "project" and edge["requirement_name"] == requirement.name
        end)
      end)
      |> Enum.map(fn r ->
        status = if r.satisfied, do: "✓", else: "○"
        "#{status} [#{r.name}](/projects/#{slug}/requirements/#{r.name})"
      end)

    sections = []

    sections =
      if same_deps != [] do
        sections ++ ["\n\n---\n\n### Depends on\n\n" <> Enum.join(same_deps, " | ")]
      else
        sections
      end

    sections =
      if cross_deps != "" do
        sections ++ [cross_deps]
      else
        sections
      end

    sections =
      if dependents != [] do
        sections ++ ["\n\n### Unblocks\n\n" <> Enum.join(dependents, " | ")]
      else
        sections
      end

    Enum.join(sections)
  end

  # Renders cross-entity dependency links for :dependencies/:children scope requirements
  defp render_cross_entity_deps(requirement, slug, names) do
    story_edges =
      (requirement.depends_on || [])
      |> Enum.filter(fn edge -> edge["entity_type"] == "story" end)

    component_edges =
      (requirement.depends_on || [])
      |> Enum.filter(fn edge -> edge["entity_type"] == "component" end)

    sections = []

    sections =
      if story_edges != [] do
        lines =
          Enum.map_join(story_edges, "\n", fn edge ->
            story_id = edge["entity_id"]
            title = Map.get(names, {:story, story_id}, "Story ##{story_id}")
            req_name = edge["requirement_name"]
            "- [#{title}](/projects/#{slug}/stories/#{story_id}) → #{req_name}"
          end)

        sections ++ ["\n\n### Story dependencies\n\n#{lines}"]
      else
        sections
      end

    sections =
      if component_edges != [] do
        lines =
          Enum.map_join(component_edges, "\n", fn edge ->
            cid = edge["entity_id"]
            module = Map.get(names, {:component, cid}, cid)
            "- [#{module}](/projects/#{slug}/components/#{cid}) → #{edge["requirement_name"]}"
          end)

        sections ++ ["\n\n### Component dependencies\n\n#{lines}"]
      else
        sections
      end

    Enum.join(sections)
  end

  # --- Entity requirement show (story/component) ---

  defp build_entity_req_show_markdown(requirement, entity_label, back_path, scope, project, names) do
    slug = project_slug(project)
    back = "[← Back to #{entity_label}](#{back_path})\n\n"

    status = if requirement.satisfied, do: "✓ Satisfied", else: "Not satisfied"
    score = if requirement.score, do: " (#{Float.round(requirement.score, 2)})", else: ""

    header = "# #{requirement.name}\n\n#{requirement.description}\n\n**#{status}#{score}**\n"

    body =
      if requirement.satisfied_by && !requirement.satisfied do
        "\n\n" <> generate_command(requirement.satisfied_by, scope, project)
      else
        ""
      end

    # Cross-entity deps
    cross_deps = render_cross_entity_deps(requirement, slug, names)

    back <> header <> body <> cross_deps
  end

  # --- Story show ---

  defp build_story_show_markdown(story, project, scope) do
    slug = project_slug(project)
    names = build_entity_names(scope)
    reqs = story.requirements || []
    total = length(reqs)
    satisfied = Enum.count(reqs, & &1.satisfied)
    actionable = Requirements.next_actionable(scope, story)

    actionable_names =
      actionable |> Map.values() |> List.flatten() |> MapSet.new(& &1.name)

    back = "[← Back to stories](/projects/#{slug}/stories)\n\n"
    header = "# #{story.title} — Requirements (#{satisfied}/#{total})\n\n"

    component_info =
      if story.component do
        "Linked component: [**#{story.component.module_name}**](/projects/#{slug}/components/#{story.component.id})\n\n"
      else
        "No component linked.\n\n"
      end

    lines =
      Enum.map_join(reqs, "\n", fn req ->
        check = if req.satisfied, do: "[x]", else: "[ ]"
        tag = if MapSet.member?(actionable_names, req.name), do: " *(actionable)*", else: ""

        # Show cross-entity deps for :dependencies/:children scope requirements
        cross_deps = render_story_req_deps(req, slug, names)

        "- #{check} [**#{req.name}**](/projects/#{slug}/stories/#{story.id}/requirements/#{req.name}) — #{req.description}#{tag}#{cross_deps}"
      end)

    back <> header <> component_info <> lines <> "\n"
  end

  defp render_story_req_deps(req, slug, names) do
    component_edges =
      (req.depends_on || [])
      |> Enum.filter(fn edge -> edge["entity_type"] == "component" end)

    if component_edges == [] do
      ""
    else
      links =
        Enum.map_join(component_edges, ", ", fn edge ->
          cid = edge["entity_id"]
          module = Map.get(names, {:component, cid}, cid)
          "[#{module}](/projects/#{slug}/components/#{cid})"
        end)

      "\n  - depends on: #{links}"
    end
  end

  # --- Component show ---

  defp build_component_show_markdown(component, project, scope) do
    slug = project_slug(project)
    reqs = component.requirements || []
    total = length(reqs)
    satisfied = Enum.count(reqs, & &1.satisfied)
    actionable = Requirements.next_actionable(scope, component)

    actionable_names =
      actionable |> Map.values() |> List.flatten() |> MapSet.new(& &1.name)

    back = "[← Back to requirements](/projects/#{slug}/requirements)\n\n"
    header = "# #{component.module_name} — Requirements (#{satisfied}/#{total})\n\n"
    type_info = "Type: **#{component.type}**\n\n"

    deps_info =
      case component.dependencies do
        deps when is_list(deps) and deps != [] ->
          dep_links =
            Enum.map_join(deps, "\n", fn dep ->
              "- [#{dep.module_name}](/projects/#{slug}/components/#{dep.id})"
            end)

          "### Dependencies\n\n#{dep_links}\n\n"

        _ ->
          ""
      end

    lines =
      Enum.map_join(reqs, "\n", fn req ->
        check = if req.satisfied, do: "[x]", else: "[ ]"
        tag = if MapSet.member?(actionable_names, req.name), do: " *(actionable)*", else: ""
        "- #{check} [**#{req.name}**](/projects/#{slug}/components/#{component.id}/requirements/#{req.name}) — #{req.description}#{tag}"
      end)

    back <> header <> type_info <> deps_info <> lines <> "\n"
  end

  # Make the index markdown link to UI pages instead of API
  defp rewrite_api_links_to_ui(markdown, project) do
    slug = project_slug(project)
    # The markdown has **req_name** — make them links to the show page
    String.replace(markdown, ~r/\*\*([a-z_\/]+)\*\*/, "[**\\1**](/projects/#{slug}/requirements/\\1)")
  end

  defp append_graph_link(markdown, project) do
    slug = project_slug(project)
    markdown <> "\n\n---\n\n[View Stories →](/projects/#{slug}/stories) | [View Requirements Graph →](/projects/#{slug}/graph)"
  end

  # --- Helpers ---

  defp get_checklist(%{details: details}) do
    details["checklist"] || Map.get(details, :checklist)
  end

  defp get_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    _ -> Map.get(map, key)
  end

  defp generate_command(task_module, scope, project) do
    case task_module.command(scope, %{project: project}) do
      {:ok, text} -> text
      {:error, reason} -> "Error: #{inspect(reason)}"
    end
  rescue
    error -> "Error: #{inspect(error)}"
  end

  defp build_entity_names(scope) do
    components =
      Components.list_components(scope)
      |> Enum.map(fn c -> {{:component, c.id}, c.module_name} end)

    stories =
      case Stories.list_project_stories(scope) do
        {:ok, stories} -> Enum.map(stories, fn s -> {{:story, s.id}, s.title} end)
        _ -> []
      end

    Map.new(components ++ stories)
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
