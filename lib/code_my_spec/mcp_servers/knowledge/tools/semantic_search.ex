defmodule CodeMySpec.McpServers.Knowledge.Tools.SemanticSearch do
  @moduledoc """
  Semantic search across all embedded documentation.

  Uses vector similarity (cosine distance) to find the most relevant
  documentation chunks for a natural language query.

  Searches across every embedded source — project knowledge, the
  framework knowledge base, specs, rules, and compiled hex dependency
  docs — or filters to a single source.

  ## Sources

  - `knowledge` — framework reference (LiveView, DaisyUI, etc.)
  - `project_knowledge` — project-specific research and decisions
  - `spec` / `rules` — embedded spec and rule files
  - `hexdocs` — every embedded hex package (prefix match, `hexdocs:*`)
  - `hexdocs:<package>` — a specific hex package, e.g. `hexdocs:phoenix`

  Embeddings are auto-maintained by `sync_project` — running it picks up
  any changed knowledge/spec/rule files and refreshes their vectors.
  Hex package embeddings are still managed via `embed_hexdocs`.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Embeddings
  alias CodeMySpec.McpServers.Validators

  schema do
    field :query, :string, required: true, description: "Natural language search query"

    field :source, :string,
      description:
        "Filter to a source. One of: 'knowledge', 'project_knowledge', 'spec', 'rules', " <>
          "'hexdocs' (all hex packages), or 'hexdocs:<package>' (one package). " <>
          "Omit to search everything."

    field :limit, :integer, description: "Max results (default: 10)"
  end

  @impl true
  def execute(%{query: query} = params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        run_search(scope, query, params, frame)

      {:error, reason} ->
        {:reply, error_response("#{reason}"), frame}
    end
  end

  defp run_search(scope, query, params, frame) do
    opts =
      []
      |> put_source(params[:source])
      |> maybe_add(:limit, params[:limit])

    case Embeddings.search(scope, query, opts) do
      {:ok, results} ->
        {:reply, text_response(format_results(query, results)), frame}

      {:error, :embeddings_unavailable} ->
        {:reply,
         error_response(
           "Embeddings are unavailable in this runtime. The embed pipeline (Ortex + sqlite_vec) ships only with the CodeMySpec CLI binary."
         ), frame}

      {:error, reason} ->
        {:reply, error_response("#{inspect(reason)}"), frame}
    end
  end

  # Bare "hexdocs" means "any hexdocs:<package>" — translate to prefix match.
  # Everything else is an exact source match.
  defp put_source(opts, nil), do: opts
  defp put_source(opts, ""), do: opts
  defp put_source(opts, "hexdocs"), do: Keyword.put(opts, :source_prefix, "hexdocs:")
  defp put_source(opts, source), do: Keyword.put(opts, :source, source)

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_results(query, results) do
    header = "# Search: \"#{query}\"\n\n**#{length(results)} results**\n"
    header <> "\n" <> format_body(results)
  end

  defp format_body([]),
    do: "\nNo matches found. Run `sync_project` to refresh project/knowledge/spec/rule embeddings, or `embed_hexdocs` for hex package embeddings."

  defp format_body(results) do
    Enum.map_join(results, "\n\n---\n\n", &format_result/1)
  end

  defp format_result(result) do
    """
    **#{result.source}/#{result.path}** (chunk #{result.chunk_index})

    #{String.slice(result.content, 0, 500)}#{if String.length(result.content) > 500, do: "...", else: ""}
    """
  end

  defp text_response(content) do
    Response.tool()
    |> Response.text(content)
  end

  defp error_response(message) do
    Response.tool()
    |> Response.error(message)
  end
end
