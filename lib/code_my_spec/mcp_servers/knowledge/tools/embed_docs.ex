defmodule CodeMySpec.McpServers.Knowledge.Tools.EmbedDocs do
  @moduledoc """
  Generate embeddings for all project documentation.

  Processes knowledge base, specs, and rules through Ortex
  (sentence-transformers/all-MiniLM-L6-v2, 384 dims) and stores vectors
  in SQLite via sqlite_vec.

  Content-hash deduplication means unchanged docs are skipped on re-runs.
  Only available when running via the CodeMySpec CLI binary — not from a
  mix phx.server dev run.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Embeddings
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, results} <- Embeddings.embed_project_docs(scope) do
      {:reply, text_response(format_results(results)), frame}
    else
      {:error, :embeddings_unavailable} ->
        {:reply, error_response(embeddings_unavailable_message()), frame}

      {:error, reason} ->
        {:reply, error_response("#{reason}"), frame}
    end
  end

  defp embeddings_unavailable_message do
    "Embeddings are unavailable in this runtime. The embed pipeline (Ortex + sqlite_vec) ships only with the CodeMySpec CLI binary. This tool is a no-op when running via mix phx.server."
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
