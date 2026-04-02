defmodule CodeMySpec.Embeddings do
  @moduledoc """
  Context for document embeddings and semantic search.

  Manages embedding generation for project documentation (knowledge, specs, rules)
  and provides vector similarity search across all embedded content.
  """

  alias CodeMySpec.Embeddings.EmbeddingService
  alias CodeMySpec.Users.Scope

  @doc """
  Embed all project documentation sources.

  Processes knowledge, project_knowledge, specs, and rules directories.
  Skips unchanged content via content-hash deduplication.
  """
  def embed_project_docs(%Scope{} = scope) do
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
    EmbeddingService.search(scope.active_project_id, query, opts)
  end
end
