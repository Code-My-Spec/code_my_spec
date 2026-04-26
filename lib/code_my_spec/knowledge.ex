defmodule CodeMySpec.Knowledge do
  @moduledoc """
  Read-only browser for the project's markdown knowledge libraries.

  Two libraries:

  - `:knowledge` — curated framework reference under
    `priv/knowledge/` (shipped with the app).
  - `:project_knowledge` — project-specific research under
    `<project>/.code_my_spec/knowledge/` (lives in the user's repo).

  Same content is exposed through two surfaces:

  - The `CodeMySpecLocalWeb.MarkdownBrowserLive` LiveView (browser UI).
  - The `list_knowledge` / `read_knowledge` MCP tools (agent UI).

  Both surfaces call into this module so the browsing rules
  (allowed libraries, root resolution, path-traversal protection)
  live in one place.
  """

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

  @doc """
  Returns the static library config map. Used by the LiveView for
  display-side helpers (titles, descriptions).
  """
  @spec libraries() :: map()
  def libraries, do: @libraries

  @doc """
  Resolves the configured filesystem root for a library.

  - `{:priv, relative}` — `priv/<relative>` of `:code_my_spec`.
  - `{:project, relative}` — `<project_root>/<relative>`, where the
    project is looked up by name and its `local_path` is the root.
  """
  @spec resolve_root(term(), String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_root({:priv, relative}, _project_name) do
    root = :code_my_spec |> :code.priv_dir() |> Path.join(relative)

    if File.dir?(root) do
      {:ok, root}
    else
      {:error, "Directory not found: priv/#{relative}"}
    end
  end

  def resolve_root({:project, relative}, project_name) do
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

  @doc """
  Resolve a library + path-segments + project-name into either a
  rendered markdown listing (for a directory) or a markdown file's
  contents (for a `.md` file).

  Used by the MCP knowledge tools to drive the same content as the
  LiveView from the agent surface.
  """
  @spec resolve(atom(), [String.t()], String.t() | nil) ::
          {:ok, String.t()} | {:error, atom() | String.t()}
  def resolve(library, path_segments, project_name) do
    with {:ok, config} <- Map.fetch(@libraries, library),
         {:ok, root} <- resolve_root(config.root, project_name) do
      case path_segments do
        [] ->
          lines = root |> list_entries() |> format_entries()
          {:ok, "# #{config.title}\n\n#{lines}\n"}

        segments ->
          full_path = Path.join([root | segments])

          cond do
            not safe_path?(root, full_path) ->
              {:error, :invalid_path}

            not File.exists?(full_path) ->
              {:error, :not_found}

            File.dir?(full_path) ->
              lines = full_path |> list_entries() |> format_entries()
              {:ok, "# #{Path.basename(full_path)}\n\n#{lines}\n"}

            String.ends_with?(full_path, ".md") ->
              {:ok, File.read!(full_path)}

            true ->
              {:error, :not_found}
          end
      end
    end
  end

  @doc """
  Lists `dir_path` as `[{name, :dir | :file}]`, hiding dotfiles and
  sorting directories first, then alphabetical with READMEs floated
  to the top of each tier.
  """
  @spec list_entries(String.t()) :: [{String.t(), :dir | :file}]
  def list_entries(dir_path) do
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

  @doc """
  Returns `true` if `path` is safely contained within `root`. Guards
  against `..`-style traversal in user-supplied path segments.
  """
  @spec safe_path?(String.t(), String.t()) :: boolean()
  def safe_path?(root, path) do
    expanded = Path.expand(path)
    String.starts_with?(expanded, Path.expand(root))
  end

  defp format_entries(entries) do
    Enum.map_join(entries, "\n", fn {name, type} ->
      label = if type == :dir, do: "#{name}/", else: Path.basename(name, ".md")
      "- #{label}"
    end)
  end
end
