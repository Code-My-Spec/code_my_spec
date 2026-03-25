defmodule CodeMySpecLocalWeb.HomeLive do
  @moduledoc """
  Main menu page for the local web interface.

  Renders a markdown-based navigation hub linking to all project sections.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, markdown: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"project_name" => name}, _uri, socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      slug = project_slug(project)
      dir_param = URI.encode_www_form(scope.cwd)

      markdown = build_menu(project.name, slug, dir_param)

      {:noreply,
       assign(socket,
         markdown: markdown,
         page_title: project.name,
         error: nil
       )}
    else
      {:error, msg} -> {:noreply, assign(socket, error: "#{msg}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error} style="color: #f87171;">
      <h1>Error</h1>
      <p>{@error}</p>
    </div>

    <div :if={@markdown} class="prose prose-invert">
      {raw(CodeMySpecLocalWeb.markdown_to_html(@markdown))}
    </div>
    """
  end

  defp build_menu(project_name, slug, dir_param) do
    """
    # #{project_name}

    ## Initialization

    - [Project Init Checklist](/init?dir=#{dir_param})

    ## Data

    - [Stories](/projects/#{slug}/stories)
    - [Issues](/projects/#{slug}/issues)

    ## Requirements

    - [Project Requirements](/projects/#{slug}/requirements)
    - [Stories Requirements](/projects/#{slug}/stories/requirements)
    - [Components Requirements](/projects/#{slug}/components)

    ## Reference

    - [Knowledge Base](/projects/#{slug}/knowledge)
    - [Project Knowledge](/projects/#{slug}/project-knowledge)

    ## Project Management

    - [Next Task](/projects/#{slug}/next-task)
    - [Sync Requirements](/projects/#{slug}/sync)
    """
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
