defmodule CodeMySpec.Embeddings.Backend do
  @moduledoc """
  Behaviour for embedding storage and retrieval implementations.

  Two production impls:

  * `CodeMySpec.Embeddings.SqliteVecBackend` — wraps the existing
    `EmbeddingService` (Ortex generation + sqlite_vec storage). Used in
    `:dev_cli` / `:prod_cli` runtimes that ship with the CLI binary.
  * `CodeMySpec.Embeddings.TestBackend` — ETS-backed in-memory store
    for the test env, where Ortex isn't loaded and the doc_embeddings
    table doesn't exist (Postgres test DB).

  The active backend is selected via `Application.get_env(:code_my_spec,
  :embeddings_backend)`. If unset, embeddings are unavailable and all
  calls return `{:error, :embeddings_unavailable}`.
  """

  @type result :: %{
          source: String.t(),
          path: String.t(),
          chunk_index: integer(),
          content: String.t()
        }

  @callback embed_file(
              project_id :: String.t(),
              source :: String.t(),
              path :: String.t(),
              content :: String.t()
            ) :: {:ok, %{embedded: integer(), skipped: integer()}} | {:error, term()}

  @callback delete_path(
              project_id :: String.t(),
              source :: String.t(),
              path :: String.t()
            ) :: {:ok, integer()} | {:error, term()}

  @callback search(
              project_id :: String.t(),
              query :: String.t(),
              opts :: keyword()
            ) :: {:ok, [result()]} | {:error, term()}
end
