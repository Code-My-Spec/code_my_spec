defmodule CodeMySpecLocalWeb.IssuesLive do
  @moduledoc """
  Human interface for browsing issues.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Issues
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope
  alias CodeMySpecLocalWeb.IssuesMarkdown

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, project: nil, markdown: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"project_name" => name, "id" => id}, _uri, %{assigns: %{live_action: :show}} = socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      slug = project_slug(project)

      case Issues.get_issue(scope, id) do
        nil ->
          {:noreply, assign(socket, error: "Issue not found: #{id}")}

        issue ->
          markdown = IssuesMarkdown.show(issue, base_path: "/projects/#{slug}")
          {:noreply, assign(socket, project: project, markdown: markdown, error: nil)}
      end
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  def handle_params(%{"project_name" => name} = params, _uri, socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      slug = project_slug(project)
      filters = parse_filters(params)
      issues = Issues.list_filtered(scope, filters)

      markdown = IssuesMarkdown.index(issues, base_path: "/projects/#{slug}", filters: filters)

      {:noreply, assign(socket, project: project, markdown: markdown, error: nil)}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

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

  defp parse_filters(params) do
    %{}
    |> maybe_put(:status, parse_atom(params["status"]))
    |> maybe_put(:severity, parse_atom(params["severity"]))
    |> maybe_put(:scope, parse_atom(params["scope"]))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_atom(nil), do: nil
  defp parse_atom(s) when is_binary(s) and s != "", do: String.to_existing_atom(s)
  defp parse_atom(_), do: nil

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
