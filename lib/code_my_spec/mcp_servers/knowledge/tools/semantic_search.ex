defmodule CodeMySpec.McpServers.Knowledge.Tools.SemanticSearch do
  @moduledoc """
  Semantic search across all embedded documentation.

  Uses vector similarity (cosine distance) to find the most relevant
  documentation chunks for a natural language query.

  Searches across every embedded source — project knowledge, the
  framework knowledge base, and hex dependency docs — or filters to a
  single source.

  ## Sources

  - `knowledge` — framework reference (LiveView, DaisyUI, etc.)
  - `project_knowledge` — project-specific research and decisions
  - `hexdocs` — every embedded hex package (prefix match, `hexdocs:*`)
  - `hexdocs:<package>` — a specific hex package, e.g. `hexdocs:phoenix`

  Embeddings fill in on their own — there is no sync tool and nothing to
  run. Hex docs appear once the server's reconciler has embedded the
  package versions this project's `mix.lock` actually pins; framework
  knowledge on server boot; project knowledge once the main copy's harness
  has reported a change to `.code_my_spec/knowledge`. A query that finds nothing
  for a package or topic that should exist usually means that embedding
  hasn't landed yet, not that something needs triggering.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Embeddings
  alias CodeMySpec.McpServers.Validators

  schema do
    field :query, :string, required: true, description: "Natural language search query"

    field :source, :string,
      description:
        "Filter to a source. One of: 'knowledge', 'project_knowledge', " <>
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
      # An explanation of the implementation alone is no use to an agent that
      # needs a next step. Every internal agent carries this tool (`ToolSets`
      # gives it to coding, product and main), and in this runtime every call
      # fails, so the message is the only thing standing between a failed lookup
      # and a dropped question (`084b8351`).
      #
      # `list_knowledge` and `read_knowledge` do work here — measured, the same
      # session that filed this read `devops/README.md` fine. What is missing is
      # search, so an agent that knows the tree can still get where it is going;
      # it just has to look rather than ask.
      {:error, :embeddings_unavailable} ->
        {:reply,
         error_response(
           "Embeddings are unavailable in this runtime — no embeddings backend is " <>
             "configured, so no query will work here and retrying or rephrasing will " <>
             "not help.\n\n" <>
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
      "\nNo matches found. Embeddings fill in on their own — there's nothing to run. " <>
        "If this is a hex package, its docs land once the server's reconciler has " <>
        "embedded the version this project's mix.lock pins; retrying later (not now) " <>
        "may turn up results once that's happened."

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
