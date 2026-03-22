defmodule CodeMySpecLocalWeb.RequirementsLive do
  @moduledoc """
  Human interface for project requirements.

  Generates markdown (same source as the LLM API), renders via MDEx.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Projects
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Setup.SetupSteps
  alias CodeMySpec.Users.Scope
  alias CodeMySpecLocalWeb.RequirementsMarkdown

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, project: nil, scope: nil, markdown: nil, error: nil)}
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
        markdown = build_show_markdown(requirement, project, scope)
        {:noreply, assign(socket, project: project, scope: scope, markdown: markdown, error: nil)}
      else
        {:noreply, assign(socket, error: "Requirement not found: #{req_name}")}
      end
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

    <div :if={@markdown} class="prose prose-invert max-w-none">
      {raw(CodeMySpecLocalWeb.markdown_to_html(@markdown))}
    </div>
    """
  end

  # --- Markdown builders ---

  defp build_show_markdown(requirement, project, scope) do
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

    back <> header <> body
  end

  # Make the index markdown link to UI pages instead of API
  defp rewrite_api_links_to_ui(markdown, project) do
    slug = project_slug(project)
    # The markdown has **req_name** — make them links to the show page
    String.replace(markdown, ~r/\*\*([a-z_\/]+)\*\*/, "[**\\1**](/projects/#{slug}/requirements/\\1)")
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
