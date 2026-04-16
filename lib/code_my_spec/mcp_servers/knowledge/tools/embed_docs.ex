defmodule CodeMySpec.McpServers.Knowledge.Tools.EmbedDocs do
  @moduledoc """
  Generate embeddings for all project documentation.

  Processes knowledge base, specs, and rules through Ollama (mxbai-embed-large)
  and stores vectors in SQLite for semantic search.

  Content-hash deduplication means unchanged docs are skipped on re-runs.
  Requires Ollama running locally.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Embeddings
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      {:ok, results} = Embeddings.embed_project_docs(scope)
      {:reply, text_response(format_results(results)), frame}
    else
      {:error, reason} ->
        {:reply, error_response("#{reason}"), frame}
    end
  end

  defp format_results(results) do
    lines =
      Enum.map_join(results, "\n", fn {source, result} ->
        case result do
          %{error: reason} ->
            "- **#{source}**: error — #{reason}"

          %{embedded: embedded, skipped: skipped, deleted: deleted} ->
            "- **#{source}**: #{embedded} embedded, #{skipped} skipped, #{deleted} stale removed"
        end
      end)

    "# Embedding Results\n\n#{lines}"
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
