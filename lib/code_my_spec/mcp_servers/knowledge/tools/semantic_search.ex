defmodule CodeMySpec.McpServers.Knowledge.Tools.SemanticSearch do
  @moduledoc """
  Semantic search across all embedded project documentation.

  Uses vector similarity (cosine distance) to find the most relevant
  documentation chunks for a natural language query.

  Searches across knowledge base, specs, rules, and any other embedded sources.
  Requires docs to have been embedded first via embed_docs.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Embeddings
  alias CodeMySpec.McpServers.Validators

  schema do
    field :query, :string, required: true, description: "Natural language search query"

    field :source, :string,
      description:
        "Filter to a source: 'knowledge', 'project_knowledge', 'spec', or 'rules'. Omit to search all."

    field :limit, :integer, description: "Max results (default: 10)"
  end

  @impl true
  def execute(%{query: query} = params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      opts =
        []
        |> maybe_add(:source, params[:source])
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
    else
      {:error, reason} ->
        {:reply, error_response("#{reason}"), frame}
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_results(query, results) do
    header = "# Search: \"#{query}\"\n\n**#{length(results)} results**\n"

    body =
      if results == [] do
        "\nNo matches found. Run `embed_docs` first to generate embeddings."
      else
        Enum.map_join(results, "\n\n---\n\n", fn result ->
          """
          **#{result.source}/#{result.path}** (chunk #{result.chunk_index})

          #{String.slice(result.content, 0, 500)}#{if String.length(result.content) > 500, do: "...", else: ""}
          """
        end)
      end

    header <> "\n" <> body
  end

  defp text_response(content) do
    Anubis.Server.Response.tool()
    |> Anubis.Server.Response.text(content)
  end

  defp error_response(message) do
    Anubis.Server.Response.tool()
    |> Anubis.Server.Response.error(message)
  end
end
