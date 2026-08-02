defmodule CodeMySpecLocalWeb.MarkdownBrowserLive do
  @moduledoc """
  Generic browser for directories of markdown files.

  Reusable across multiple libraries — each `live_action` maps to a
  filesystem root (priv content) or a project-relative path resolved
  through the scope's environment. All root resolution and path-traversal
  protection lives in `CodeMySpec.Knowledge`; this LiveView is the display
  surface only.

  Directory listings are structured data and render as a list of links;
  a `.md` file's contents are markdown and render through `md_html/1`.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Knowledge
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  # Library config (titles) lives in CodeMySpec.Knowledge.
  @libraries Knowledge.libraries()

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()
    {:ok, assign(socket, projects: projects, project: nil, view: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"project_name" => project_name} = params, _uri, socket)
      when not is_map_key(params, "path") do
    load_view(socket, project_name, [])
  end

  def handle_params(%{"project_name" => project_name, "path" => path_segments}, _uri, socket) do
    load_view(socket, project_name, path_segments)
  end

  defp load_view(socket, project_name, path_segments) do
    library = socket.assigns.live_action
    config = Map.fetch!(@libraries, library)
    base_url = "/app/projects/#{project_name}/#{library_path(library)}"

    with {:ok, project} <- Projects.get_project_by_name(project_name),
         {:ok, scope} <- Scope.for_local_project(project),
         {:ok, result} <- Knowledge.browse(scope, library, path_segments) do
      view = build_view(result, config, base_url, path_segments)

      {:noreply,
       assign(socket,
         project: project,
         library: library,
         view: view,
         page_title: elem(view, 1).title,
         error: nil
       )}
    else
      {:error, reason} ->
        {:noreply, assign(socket, library: library, view: nil, error: error_message(reason))}
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
      section={assigns[:library]}
      page_title={assigns[:page_title]}
    >
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <.dir_view :if={match?({:dir, _}, @view)} dir={elem(@view, 1)} />
      <.file_view :if={match?({:file, _}, @view)} file={elem(@view, 1)} />
    </Layouts.app>
    """
  end

  attr :dir, :map, required: true

  defp dir_view(assigns) do
    ~H"""
    <div>
      <.back_link :if={@dir.back_url} url={@dir.back_url} />
      <h1 class="text-2xl font-bold mb-4">{@dir.title}</h1>

      <ul class="space-y-1.5">
        <li
          :for={entry <- @dir.entries}
          class="flex items-center gap-2 rounded-box border border-base-300 bg-base-200 p-3"
        >
          <span class="flex-none text-base-content/50">{if entry.type == :dir, do: "▸", else: "·"}</span>
          <.link navigate={entry.url} class="link link-hover flex-1 truncate">{entry.label}</.link>
        </li>
      </ul>

      <p :if={@dir.entries == []} class="text-base-content/50">Empty.</p>
    </div>
    """
  end

  attr :file, :map, required: true

  defp file_view(assigns) do
    ~H"""
    <div>
      <.back_link :if={@file.back_url} url={@file.back_url} />
      <div class="prose prose-sm md:prose-base max-w-none bg-base-200 border border-base-300 rounded-box p-6 overflow-x-auto">
        {md_html(@file.content)}
      </div>
    </div>
    """
  end

  attr :url, :string, required: true

  defp back_link(assigns) do
    ~H"""
    <div class="mb-4">
      <.link navigate={@url} class="btn btn-ghost btn-sm gap-1">← Back</.link>
    </div>
    """
  end

  # --- View builders ---

  defp build_view({:dir, entries}, config, base_url, path_segments) do
    {:dir,
     %{
       title: dir_title(config, path_segments),
       back_url: parent_url(base_url, path_segments),
       entries:
         Enum.map(entries, fn {name, type, rel} ->
           label = if type == :dir, do: "#{humanize(name)}/", else: humanize_filename(name)
           %{label: label, type: type, url: "#{base_url}/#{rel}"}
         end)
     }}
  end

  defp build_view({:file, content}, _config, base_url, path_segments) do
    {:file,
     %{
       title: file_title(path_segments),
       back_url: parent_url(base_url, path_segments),
       content: content
     }}
  end

  defp dir_title(config, []), do: config.title
  defp dir_title(_config, segments), do: segments |> List.last() |> humanize()

  defp file_title(segments), do: segments |> List.last() |> humanize_filename()

  defp parent_url(_base_url, []), do: nil

  defp parent_url(base_url, segments) do
    case Enum.drop(segments, -1) do
      [] -> base_url
      parent -> "#{base_url}/#{Enum.join(parent, "/")}"
    end
  end

  defp error_message(:not_found), do: "Not found"
  defp error_message(:invalid_path), do: "Invalid path"
  defp error_message(:unknown_library), do: "Unknown library"
  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)

  # --- Helpers ---

  defp humanize(name) do
    name
    |> String.replace(~r/[-_]/, " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp humanize_filename(name) do
    name
    |> Path.basename(".md")
    |> humanize()
  end

  defp library_path(library) when is_atom(library) do
    library |> Atom.to_string() |> String.replace("_", "-")
  end
end
