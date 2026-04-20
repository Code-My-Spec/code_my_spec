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

  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  @libraries %{
    knowledge: %{
      title: "Knowledge Base",
      root: {:priv, "knowledge"},
      description: "Curated reference articles for AI-assisted development"
    },
    project_knowledge: %{
      title: "Project Knowledge",
      root: {:project, ".code_my_spec/knowledge"},
      description: "Project-specific research and technology decisions"
    }
  }

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

      <article :if={@markdown} class="prose max-w-none">
        {raw(CodeMySpecLocalWeb.markdown_to_html(@markdown))}
      </article>
    </Layouts.app>
    """
  end

  defp resolve_root({:priv, relative}, _project_name) do
    root = :code_my_spec |> :code.priv_dir() |> Path.join(relative)

    if File.dir?(root) do
      {:ok, root}
    else
      {:error, "Directory not found: priv/#{relative}"}
    end
  end

  defp resolve_root({:project, relative}, project_name) do
    with {:ok, project} <- Projects.get_project_by_name(project_name),
         {:ok, scope} <- Scope.for_local_project(project) do
      root = Path.join(scope.cwd, relative)

      if File.dir?(root) do
        {:ok, root}
      else
        {:error, "Directory not found: #{relative}"}
      end
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

  defp list_entries(dir_path) do
    dir_path
    |> File.ls!()
    |> Enum.reject(&String.starts_with?(&1, "."))
    |> Enum.sort()
    |> Enum.map(fn name ->
      full = Path.join(dir_path, name)
      type = if File.dir?(full), do: :dir, else: :file
      {name, type}
    end)
    |> Enum.sort_by(fn {name, type} ->
      {if(type == :dir, do: 0, else: 1), if(name =~ ~r/^readme/i, do: 0, else: 1), name}
    end)
  end

  defp safe_path?(root, path) do
    expanded = Path.expand(path)
    String.starts_with?(expanded, Path.expand(root))
  end

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

  def libraries, do: @libraries

  def resolve(library, path_segments, project_name) do
    with {:ok, config} <- Map.fetch(@libraries, library),
         {:ok, root} <- resolve_root(config.root, project_name) do
      case path_segments do
        [] ->
          lines = list_entries(root) |> format_entries()
          {:ok, "# #{config.title}\n\n#{lines}\n"}

        segments ->
          relative_path = Path.join(segments)
          full_path = Path.join(root, relative_path)

          cond do
            not safe_path?(root, full_path) -> {:error, :invalid_path}
            not File.exists?(full_path) -> {:error, :not_found}
            File.dir?(full_path) ->
              lines = list_entries(full_path) |> format_entries()
              {:ok, "# #{Path.basename(full_path)}\n\n#{lines}\n"}
            String.ends_with?(full_path, ".md") -> {:ok, File.read!(full_path)}
            true -> {:error, :not_found}
          end
      end
    end
  end

  defp format_entries(entries) do
    Enum.map_join(entries, "\n", fn {name, type} ->
      label = if type == :dir, do: "#{name}/", else: Path.basename(name, ".md")
      "- #{label}"
    end)
  end
end
