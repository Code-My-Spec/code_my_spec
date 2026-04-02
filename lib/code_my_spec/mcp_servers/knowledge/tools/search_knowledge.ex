defmodule CodeMySpec.McpServers.Knowledge.Tools.SearchKnowledge do
  @moduledoc """
  Search the knowledge base for entries matching a query string.

  Searches file names and content across the knowledge library, returning
  matching file paths with surrounding context.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Validators
  alias CodeMySpecLocalWeb.MarkdownBrowserLive

  schema do
    field :query, :string, required: true, description: "Search query (case-insensitive)"

    field :library, :string,
      description:
        "Which knowledge library: 'knowledge' (framework) or 'project_knowledge' (project-specific). Default: 'knowledge'"
  end

  @impl true
  def execute(%{"query" => query} = params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      library = library_atom(params)
      project_name = scope.active_project.name

      config = Map.fetch!(MarkdownBrowserLive.libraries(), library)

      case resolve_root(config.root, project_name) do
        {:ok, root} ->
          results = search_files(root, query)
          {:reply, search_response(query, library, root, results), frame}

        {:error, reason} ->
          {:reply, error_response("#{inspect(reason)}"), frame}
      end
    else
      {:error, reason} ->
        {:reply, error_response("#{reason}"), frame}
    end
  end

  defp library_atom(%{"library" => "project_knowledge"}), do: :project_knowledge
  defp library_atom(_), do: :knowledge

  defp resolve_root({:priv, relative}, _project_name) do
    root = :code_my_spec |> :code.priv_dir() |> Path.join(relative)
    if File.dir?(root), do: {:ok, root}, else: {:error, "Directory not found"}
  end

  defp resolve_root({:project, relative}, project_name) do
    alias CodeMySpec.Projects
    alias CodeMySpec.Users.Scope

    with {:ok, project} <- Projects.get_project_by_name(project_name),
         {:ok, scope} <- Scope.for_local_project(project) do
      root = Path.join(scope.cwd, relative)
      if File.dir?(root), do: {:ok, root}, else: {:error, "Directory not found"}
    end
  end

  defp search_files(root, query) do
    downcased_query = String.downcase(query)

    root
    |> walk_files()
    |> Enum.flat_map(fn path ->
      relative = Path.relative_to(path, root)
      content = File.read!(path)

      # Check filename match
      name_match = String.contains?(String.downcase(relative), downcased_query)

      # Check content match — find lines containing the query
      matching_lines =
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _idx} ->
          String.contains?(String.downcase(line), downcased_query)
        end)
        |> Enum.take(3)

      if name_match or matching_lines != [] do
        [%{path: relative, name_match: name_match, lines: matching_lines}]
      else
        []
      end
    end)
  end

  defp walk_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          full = Path.join(dir, name)

          cond do
            File.dir?(full) -> walk_files(full)
            String.ends_with?(name, ".md") -> [full]
            true -> []
          end
        end)

      _ ->
        []
    end
  end

  defp search_response(query, library, _root, results) do
    header = "# Search: \"#{query}\" in #{library}\n\n**#{length(results)} matches**\n"

    body =
      if results == [] do
        "\nNo matching knowledge entries found."
      else
        Enum.map_join(results, "\n", fn result ->
          name_tag = if result.name_match, do: " (filename match)", else: ""

          line_previews =
            Enum.map_join(result.lines, "\n", fn {line, idx} ->
              "  L#{idx}: #{String.trim(line)}"
            end)

          if line_previews == "" do
            "\n- **#{result.path}**#{name_tag}"
          else
            "\n- **#{result.path}**#{name_tag}\n#{line_previews}"
          end
        end)
      end

    Anubis.Server.Response.tool()
    |> Anubis.Server.Response.text(header <> body)
  end

  defp error_response(message) do
    Anubis.Server.Response.tool()
    |> Anubis.Server.Response.error(message)
  end
end
