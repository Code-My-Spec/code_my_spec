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

  @doc """
  Persist one embedded chunk.

  This is the only genuinely adapter-specific operation in the pipeline —
  sqlite_vec and pgvector spell the vector literal, the placeholders, and the
  upsert conflict target differently. Everything else `EmbeddingService` does
  (chunking, hashing, the file_hash fast path, stale-chunk cleanup) is shared,
  so the backends cannot drift on dedupe semantics.

  Part of the behaviour rather than an optional function discovered with
  `function_exported?/3`: that check returns false for a module that simply
  has not been loaded yet, which fails silently by falling back to the wrong
  adapter's SQL instead of erroring.
  """
  @callback store_chunk(
              project_id :: String.t() | nil,
              source :: String.t(),
              path :: String.t(),
              chunk_index :: integer(),
              chunk :: String.t(),
              content_hash :: String.t(),
              file_hash :: String.t()
            ) :: :ok | {:error, term()}
end
