defmodule CodeMySpec.Embeddings do
  @moduledoc """
  Context for document embeddings and semantic search.

  The server reconciles every corpus itself; nothing watches a working tree:

  * framework knowledge — `FrameworkKnowledgeReconciler`, on boot;
  * hex docs — `HexDocReconciler` / `HexDocSweep`, from `mix.lock`;
  * project knowledge — `ProjectKnowledgeReconciler`, from the main copy's
    `project_knowledge` file rows (`FileSync.reconcile_project_knowledge/1`).

  Search is dispatched through `Embeddings.Backend` to the configured
  implementation (`PgVectorBackend` on the server, `TestBackend` in `:test`).
  When none is configured, `search/3` returns `{:error, :embeddings_unavailable}`.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Dependencies,
      CodeMySpec.Repo,
      CodeMySpec.Users.Scope
    ],
    exports: :all

  alias CodeMySpec.Embeddings.HexDocReconciler
  alias CodeMySpec.Users.Scope

  @pg_vector CodeMySpec.Embeddings.PgVectorBackend

  @doc "Retry failed hex doc packages; see `HexDocReconciler.reset_failed/1`."
  defdelegate reset_failed_doc_packages(opts \\ []), to: HexDocReconciler, as: :reset_failed

  @doc """
  True when the server reconciles corpora itself (`PgVectorBackend`).
  """
  @spec server_reconciled?() :: boolean()
  def server_reconciled?, do: backend() == @pg_vector

  @doc """
  Semantic search across all embedded project docs.
  """
  def search(%Scope{active_project_id: project_id}, query, opts \\ []) do
    case backend() do
      nil -> {:error, :embeddings_unavailable}
      mod -> mod.search(project_id, query, opts)
    end
  end

  defp backend do
    Application.get_env(:code_my_spec, :embeddings_backend)
  end
end
