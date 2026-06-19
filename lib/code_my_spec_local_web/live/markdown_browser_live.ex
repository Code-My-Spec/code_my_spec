defmodule CodeMySpecLocalWeb.MarkdownBrowserLive do
  @moduledoc """
  Generic browser for directories of markdown files.

  Reusable across multiple directories — each `live_action` maps to a
  filesystem root and display title. Roots can be:

    - A static string path (app-level, e.g. `priv/knowledge/`)
    - `{:project, "relative/path"}` — resolved from the project's `local_path` at runtime

  To add a new library, add an entry to `@libraries` and two routes in the router.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Knowledge
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  # Library config + path resolution rules live in CodeMySpec.Knowledge —
  # the LiveView is the display surface, the lib module is the contract.
  @libraries Knowledge.libraries()

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()
    {:ok, assign(socket, projects: projects, project: nil, markdown: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"project_name" => project_name} = params, _uri, socket)
      when not is_map_key(params, "path") do
    library = socket.assigns.live_action
    config = Map.fetch!(@libraries, library)

    with {:ok, project} <- Projects.get_project_by_name(project_name),
         {:ok, root} <- resolve_root(config.root, project_name) do
      resolved_config = Map.put(config, :root, root)
      base_url = "/projects/#{project_name}/#{library_path(library)}"
      markdown = build_index(resolved_config, root, base_url)

      {:noreply,
       assign(socket,
         project: project,
         markdown: markdown,
         library: library,
         page_title: config.title,
         error: nil
       )}
    else
      {:error, msg} -> {:noreply, assign(socket, error: "#{msg}")}
    end
  end

  def handle_params(%{"project_name" => project_name, "path" => path_segments}, _uri, socket) do
    library = socket.assigns.live_action
    config = Map.fetch!(@libraries, library)

    with {:ok, project} <- Projects.get_project_by_name(project_name),
         {:ok, root} <- resolve_root(config.root, project_name) do
      resolved_config = Map.put(config, :root, root)
      base_url = "/projects/#{project_name}/#{library_path(library)}"
      relative_path = Path.join(path_segments)
      full_path = Path.join(root, relative_path)

      cond do
        not safe_path?(root, full_path) ->
          {:noreply, assign(socket, project: project, library: library, error: "Invalid path")}

        not File.exists?(full_path) ->
          {:noreply,
           assign(socket,
             project: project,
             library: library,
             error: "Not found: #{relative_path}"
           )}

        File.dir?(full_path) ->
          markdown = build_index(resolved_config, full_path, base_url)

          {:noreply,
           assign(socket,
             project: project,
             library: library,
             markdown: markdown,
             page_title: Path.basename(full_path) |> humanize(),
             error: nil
           )}

        String.ends_with?(full_path, ".md") ->
          markdown = build_file_view(resolved_config, full_path, base_url, relative_path)

          {:noreply,
           assign(socket,
             project: project,
             library: library,
             markdown: markdown,
             page_title: Path.basename(full_path, ".md") |> humanize(),
             error: nil
           )}

        true ->
          {:noreply,
           assign(socket,
             project: project,
             library: library,
             error: "Not found: #{relative_path}"
           )}
      end
    else
      {:error, msg} -> {:noreply, assign(socket, error: "#{msg}")}
    end
  end

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

      <div
        :if={@markdown}
        class="prose prose-sm md:prose-base max-w-none bg-base-200 border border-base-300 rounded-box p-6 overflow-x-auto"
      >
        {md_html(@markdown)}
      </div>
    </Layouts.app>
    """
  end

  # Resolves a root spec ({:priv, _} | {:project, _}) for the given project_name.
  # Mirrors MarkdownBrowserController.resolve_scope/1 + Knowledge.resolve_root/2
  # so the LiveView and the API agree on path resolution. The previous
  # `defdelegate resolve_root(root, project_name), to: Knowledge` passed args
  # in the wrong order (and the wrong type for the scope arg), crashing every
  # knowledge route with a FunctionClauseError.
  defp resolve_root(root_spec, project_name) do
    with {:ok, project} <- Projects.get_project_by_name(project_name),
         {:ok, scope} <- Scope.for_local_project(project) do
      Knowledge.resolve_root(scope, root_spec)
    end
  end

  defp build_index(config, dir_path, base_url) do
    back =
      if dir_path == config.root do
        ""
      else
        parent =
          dir_path
          |> Path.relative_to(config.root)
          |> Path.dirname()

        parent_url = if parent == ".", do: base_url, else: "#{base_url}/#{parent}"
        "[← Back](#{parent_url})\n\n"
      end

    title =
      if dir_path == config.root do
        config.title
      else
        dir_path |> Path.basename() |> humanize()
      end

    entries = list_entries(dir_path)

    lines =
      Enum.map_join(entries, "\n", fn {name, type} ->
        relative = Path.relative_to(Path.join(dir_path, name), config.root)

        case type do
          :dir -> "- [#{humanize(name)}/](#{base_url}/#{relative})"
          :file -> "- [#{humanize_filename(name)}](#{base_url}/#{relative})"
        end
      end)

    description =
      if dir_path == config.root and config[:description] do
        "\n#{config.description}\n"
      else
        ""
      end

    "#{back}# #{title}\n#{description}\n#{lines}\n"
  end

  defp build_file_view(_config, full_path, base_url, relative_path) do
    parent_dir = Path.dirname(relative_path)
    parent_url = if parent_dir == ".", do: base_url, else: "#{base_url}/#{parent_dir}"
    content = File.read!(full_path)

    "[← Back](#{parent_url})\n\n#{content}"
  end

  defdelegate list_entries(dir_path), to: Knowledge
  defdelegate safe_path?(root, path), to: Knowledge

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
