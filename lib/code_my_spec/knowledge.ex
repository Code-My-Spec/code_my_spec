defmodule CodeMySpec.Knowledge do
  @moduledoc """
  Read-only browser for the project's markdown knowledge libraries.

  Two libraries:

  - `:knowledge` — curated framework reference under
    `priv/knowledge/` (shipped with the app, bundled at compile time).
    Reads go directly against the real filesystem since the corpus
    is static and lives outside the project working tree.
  - `:project_knowledge` — project-specific research under
    `<project>/.code_my_spec/knowledge/` (lives in the user's repo).
    Reads route through `scope.environment` so the in-memory environment
    used in BDD specs sees writes made through `Environments.write_file/3`.

  Same content is exposed through two surfaces:

  - The `CodeMySpecLocalWeb.MarkdownBrowserLive` LiveView (browser UI).
  - The `list_knowledge` / `read_knowledge` MCP tools (agent UI).

  Both surfaces call into this module so the browsing rules
  (allowed libraries, root resolution, path-traversal protection)
  live in one place.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Environments, CodeMySpec.Users],
    exports: :all

  alias CodeMySpec.Environments
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

  - `{:priv, relative}` — `priv/<relative>` of `:code_my_spec` (real
    filesystem, always).
  - `{:project, relative}` — `<scope.cwd>/<relative>` (read via
    `scope.environment`).
  """
  @spec resolve_root(Scope.t(), term()) :: {:ok, root()} | {:error, String.t()}
  def resolve_root(_scope, {:priv, relative}) do
    root = :code_my_spec |> :code.priv_dir() |> Path.join(relative)

    if File.dir?(root) do
      {:ok, {:priv_path, root}}
    else
      {:error, "Directory not found: priv/#{relative}"}
    end
  end

  # Probed with `list_directory`, not `file_exists?`: `Harness.file_exists?`
  # proxies `stat`, and `stat` answers `{:error, :not_regular}` for a directory
  # — so an existing knowledge dir read as missing over a harness environment.
  def resolve_root(%Scope{environment: env}, {:project, relative}) when not is_nil(env) do
    root = Path.join(env.cwd, relative)

    case Environments.list_directory(env, root) do
      {:ok, _} -> {:ok, {:env, env, root}}
      {:error, _} -> {:error, "Directory not found: #{relative}"}
    end
  end

  def resolve_root(_scope, {:project, relative}),
    do: {:error, "Directory not found: #{relative}"}

  @typep root :: {:priv_path, String.t()} | {:env, Environments.Environment.t(), String.t()}

  @doc """
  Resolve a library + path-segments into either a rendered markdown
  listing (for a directory) or a markdown file's contents (for a
  `.md` file).

  Used by the MCP knowledge tools to drive the same content as the
  LiveView from the agent surface. The scope's environment provides
  the read path for `:project_knowledge` so in-memory environments
  (used in BDD specs) work transparently.
  """
  @spec resolve(Scope.t(), atom(), [String.t()]) ::
          {:ok, String.t()} | {:error, atom() | String.t()}
  def resolve(%Scope{} = scope, library, path_segments) do
    with {:ok, config} <- Map.fetch(@libraries, library),
         {:ok, root} <- resolve_root(scope, config.root) do
      case path_segments do
        [] ->
          lines = root |> list_entries() |> format_entries()
          {:ok, "# #{config.title}\n\n#{lines}\n"}

        segments ->
          full_path = Path.join([root_path(root) | segments])
          located = locate(root, full_path)
          resolve_located(located, root, full_path, config)
      end
    end
  end

  defp resolve_located(:invalid_path, _root, _full_path, _config), do: {:error, :invalid_path}
  defp resolve_located(:not_found, _root, _full_path, _config), do: {:error, :not_found}

  defp resolve_located(:dir, root, full_path, _config) do
    sub = with_path(root, full_path)
    lines = sub |> list_entries() |> format_entries()
    {:ok, "# #{Path.basename(full_path)}\n\n#{lines}\n"}
  end

  defp resolve_located(:file, root, full_path, _config) do
    if String.ends_with?(full_path, ".md") do
      read_file(root, full_path)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Browse a library for the display surface (LiveView).

  Unlike `resolve/3` — which renders a markdown string for the agent —
  this returns structured data so the UI can render a directory as a
  list of links and a file as its raw markdown content:

    - `{:ok, {:dir, [{name, :dir | :file, rel_path}]}}` — `rel_path` is
      relative to the library root, for building browser URLs.
    - `{:ok, {:file, content}}` — raw markdown for a `.md` file.

  Works across both backends (`:priv_path` real files, `:env` projects)
  via the same resolved-root abstraction as `resolve/3`.
  """
  @spec browse(Scope.t(), atom(), [String.t()]) ::
          {:ok, {:dir, [{String.t(), :dir | :file, String.t()}]}}
          | {:ok, {:file, String.t()}}
          | {:error, atom() | String.t()}
  def browse(%Scope{} = scope, library, path_segments) do
    with {:ok, config} <- Map.fetch(@libraries, library),
         {:ok, root} <- resolve_root(scope, config.root) do
      base = root_path(root)

      case path_segments do
        [] ->
          {:ok, {:dir, browse_entries(root, base)}}

        segments ->
          full_path = Path.join([base | segments])

          case locate(root, full_path) do
            :invalid_path -> {:error, :invalid_path}
            :not_found -> {:error, :not_found}
            :dir -> {:ok, {:dir, browse_entries(with_path(root, full_path), base)}}
            :file -> browse_file(root, full_path)
          end
      end
    else
      :error -> {:error, :unknown_library}
      {:error, reason} -> {:error, reason}
    end
  end

  defp browse_entries(dir_root, base) do
    dir_root
    |> list_entries()
    |> Enum.map(fn {name, type} ->
      full = Path.join(root_path(dir_root), name)
      {name, type, Path.relative_to(full, base)}
    end)
  end

  defp browse_file(root, full_path) do
    if String.ends_with?(full_path, ".md") do
      with {:ok, content} <- read_file(root, full_path), do: {:ok, {:file, content}}
    else
      {:error, :not_found}
    end
  end

  defp locate({:priv_path, root_path}, full_path) do
    cond do
      not safe_path?(root_path, full_path) -> :invalid_path
      not File.exists?(full_path) -> :not_found
      File.dir?(full_path) -> :dir
      true -> :file
    end
  end

  # Read first, list second: a regular file reads, a directory lists, and a path
  # that does neither is absent. Gating on `file_exists?` made every subdirectory
  # `:not_found` over a harness environment, for the reason in `resolve_root/2`.
  # Directories are implicit in the in-memory backend, which is why membership is
  # inferred from a successful listing rather than asked for directly.
  defp locate({:env, env, root_path}, full_path) do
    cond do
      not safe_path?(root_path, full_path) ->
        :invalid_path

      match?({:ok, _}, Environments.read_file(env, full_path)) ->
        :file

      match?({:ok, _}, Environments.list_directory(env, full_path)) ->
        :dir

      true ->
        :not_found
    end
  end

  defp read_file({:priv_path, _}, full_path), do: {:ok, File.read!(full_path)}

  defp read_file({:env, env, _}, full_path) do
    case Environments.read_file(env, full_path) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp root_path({:priv_path, path}), do: path
  defp root_path({:env, _env, path}), do: path

  defp with_path({:priv_path, _}, full_path), do: {:priv_path, full_path}
  defp with_path({:env, env, _}, full_path), do: {:env, env, full_path}

  @doc """
  Lists a directory as `[{name, :dir | :file}]`, hiding dotfiles and
  sorting directories first, then alphabetical with READMEs floated
  to the top of each tier.

  Accepts either a raw filesystem path string (for priv content) or
  a resolved root tuple (`{:priv_path, path}` / `{:env, env, path}`).
  """
  @spec list_entries(String.t() | root()) :: [{String.t(), :dir | :file}]
  def list_entries(dir_path) when is_binary(dir_path) do
    list_entries({:priv_path, dir_path})
  end

  def list_entries({:priv_path, dir_path}) do
    dir_path
    |> File.ls!()
    |> Enum.reject(&String.starts_with?(&1, "."))
    |> Enum.map(fn name ->
      full = Path.join(dir_path, name)
      type = if File.dir?(full), do: :dir, else: :file
      {name, type}
    end)
    |> sort_entries()
  end

  def list_entries({:env, env, dir_path}) do
    {:ok, names} = Environments.list_directory(env, dir_path)

    names
    |> Enum.reject(&String.starts_with?(&1, "."))
    |> Enum.map(fn name ->
      full = Path.join(dir_path, name)

      type =
        case Environments.read_file(env, full) do
          {:ok, _} -> :file
          {:error, _} -> :dir
        end

      {name, type}
    end)
    |> sort_entries()
  end

  defp sort_entries(entries) do
    Enum.sort_by(entries, fn {name, type} ->
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
