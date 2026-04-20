defmodule CodeMySpec.Embeddings do
  @moduledoc """
  Context for document embeddings and semantic search.

  Manages embedding generation for project documentation (knowledge, specs, rules)
  and provides vector similarity search across all embedded content.

  Embeddings require Ortex + sqlite_vec, which are compiled only for
  `:dev_cli` / `:prod_cli`. Callers must handle `{:error, :embeddings_unavailable}`
  when running from the Phoenix dev server.
  """

  alias CodeMySpec.Embeddings.EmbeddingService
  alias CodeMySpec.Users.Scope

  @doc """
  Returns `:ok` if the embedding pipeline is loaded, `{:error, :embeddings_unavailable}`
  otherwise. Use as a precondition before calling embed/search functions.
  """
  def available? do
    Code.ensure_loaded?(CodeMySpec.Embeddings.OrtexServing) and
      Code.ensure_loaded?(SqliteVec)
  end

  @doc """
  Embed all project documentation sources.

  Processes knowledge, project_knowledge, specs, and rules directories.
  Skips unchanged content via content-hash deduplication.
  """
  def embed_project_docs(%Scope{} = scope) do
    if available?() do
      do_embed_project_docs(scope)
    else
      {:error, :embeddings_unavailable}
    end
  end

  defp do_embed_project_docs(%Scope{} = scope) do
    project_id = scope.active_project_id
    cwd = scope.cwd || scope.environment.cwd
    base = CodeMySpec.Paths.base_dir()

    sources = [
      {"knowledge", Path.join([:code.priv_dir(:code_my_spec), "knowledge"])},
      {"project_knowledge", Path.join([cwd, base, "knowledge"])},
      {"spec", Path.join([cwd, base, "spec"])},
      {"rules", Path.join([cwd, base, "rules"])}
    ]

    results =
      sources
      |> Enum.filter(fn {_source, dir} -> File.dir?(dir) end)
      |> Enum.map(fn {source, dir} ->
        case EmbeddingService.embed_directory(project_id, source, dir) do
          {:ok, result} -> {source, result}
          {:error, reason} -> {source, %{error: reason}}
        end
      end)

    {:ok, Map.new(results)}
  end

  @doc """
  Semantic search across all embedded project docs.
  """
  def search(%Scope{} = scope, query, opts \\ []) do
    if available?() do
      EmbeddingService.search(scope.active_project_id, query, opts)
    else
      {:error, :embeddings_unavailable}
    end
  end
end
