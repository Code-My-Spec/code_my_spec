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
  any changed knowledge/spec/rule files, projects hex docs from compiled
  deps, and refreshes all vectors. There is no separate `embed_docs` or
  `embed_hexdocs` tool; `sync_project` is the single entry point.
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

      # Names what to do instead, not only why it failed.
      #
      # This said "the embed pipeline (Ortex + sqlite_vec) ships only with the
      # CodeMySpec CLI binary" and stopped — an explanation of the
      # implementation to an agent that needs a next step. Every internal agent
      # carries this tool (`ToolSets` gives it to coding, product and main), and
      # in this runtime every call fails, so the message is the only thing
      # standing between a failed lookup and a dropped question (`084b8351`).
      #
      # `list_knowledge` and `read_knowledge` do work here — measured, the same
      # session that filed this read `devops/README.md` fine. What is missing is
      # search, so an agent that knows the tree can still get where it is going;
      # it just has to look rather than ask.
      {:error, :embeddings_unavailable} ->
        {:reply,
         error_response(
           "Embeddings are unavailable in this runtime — the embed pipeline ships only " <>
             "with the CodeMySpec CLI binary, so no query will work here and retrying or " <>
             "rephrasing will not help.\n\n" <>
             "`list_knowledge` and `read_knowledge` do work: browse the tree and read by " <>
             "path. Knowledge is organised by area, so a topic usually lives under a " <>
             "directory you can guess — `devops/`, for instance — and `list_knowledge` " <>
             "shows what is there."
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
    do:
      "\nNo matches found. Run `sync_project` to refresh all embeddings (project knowledge, specs, rules, hex docs)."

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
