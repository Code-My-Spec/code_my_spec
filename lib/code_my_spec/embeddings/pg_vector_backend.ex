defmodule CodeMySpec.Embeddings.PgVectorBackend do
  @moduledoc """
  Postgres/pgvector backend for the embedding pipeline.

  `EmbeddingService` is almost entirely adapter-agnostic — chunking, content
  hashing, the file_hash fast path, stale-chunk deletion and file walking are
  all plain Ecto or plain Elixir, and only the chunk upsert and the
  similarity search are reimplemented here, so the two backends cannot drift
  on chunk sizes, hashing, or dedupe semantics.

  `search/3` is plain `Ecto.Query` — `dynamic/2` builds the scope clause
  (the project's own rows, shared rows for its exact locked dependency
  versions, and framework knowledge), which lets Postgrex handle parameter
  binding rather than hand-counted `$N` placeholders. The vector cast still
  needs a `fragment/1`: a bare `?::vector` cast makes the PARAMETER type
  `vector`, which Postgrex cannot encode without the pgvector extension
  registered in a custom types module, so the vector is bound as `text` and
  cast in SQL instead (`encode_vector/1`'s own JSON string). `<=>` is
  pgvector's cosine-distance operator, matching the HNSW index built with
  `vector_cosine_ops`.

  `store_embedded_chunk/8` stays raw SQL for the same reason, plus the
  upsert's conflict target, which differs by whether the row is shared.
  """

  @behaviour CodeMySpec.Embeddings.Backend

  import Ecto.Query

  alias CodeMySpec.Dependencies
  alias CodeMySpec.Embeddings.{DocEmbedding, EmbeddingService, Serving}
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias Ecto.Adapters.SQL, as: AdaptersSQL

  @impl true
  def embed_file(project_id, source, path, content) do
    EmbeddingService.embed_file(project_id, source, path, content)
  end

  @impl true
  def delete_path(project_id, source, path) do
    {count, _} =
      from(e in DocEmbedding,
        where: ^project_filter(project_id),
        where: e.source == ^source and e.path == ^path
      )
      |> Repo.delete_all()

    {:ok, count}
  end

  # `e.project_id == ^project_id` never matches a shared row: Postgres
  # evaluates `column = NULL` to NULL, not true, even when the bound
  # parameter happens to be nil — only `IS NULL` does.
  defp project_filter(nil), do: dynamic([e], is_nil(e.project_id))
  defp project_filter(project_id), do: dynamic([e], e.project_id == ^project_id)

  @doc """
  A project's own rows, plus shared rows for exactly the package versions
  its `mix.lock` pins, plus framework knowledge.

  Exact versions only, no fallback to another version of the same package —
  a dependency whose docs haven't been embedded yet (or at all, if the
  package has none) simply contributes nothing, same as before this existed.

  Built with `dynamic/2` rather than hand-counted `$N` placeholders: the old
  raw-SQL version was fine while the scope was one project_id, but a clause
  per locked dependency makes manual parameter counting the kind of thing
  that is right until the dependency list has a different length than it
  did when it was tested.
  """
  @impl true
  def search(project_id, query, opts) do
    limit = Keyword.get(opts, :limit, 10)
    source = Keyword.get(opts, :source)
    source_prefix = Keyword.get(opts, :source_prefix)

    with {:ok, embedding} <- Serving.embed(query) do
      vector = encode_vector(embedding)

      results =
        DocEmbedding
        |> where(^scope_filter(project_id))
        |> where(^source_filter(source, source_prefix))
        |> order_by([e], fragment("? <=> ?::vector", e.embedding, ^vector))
        |> limit(^limit)
        |> select([e], %{
          source: e.source,
          path: e.path,
          chunk_index: e.chunk_index,
          content: e.content
        })
        |> Repo.all()

      {:ok, results}
    end
  end

  # "code_my_spec" with any version: framework knowledge is re-embedded on
  # every release rather than pinned to one version the way a hex package is
  # — see the embeddings rework design doc, "Framework knowledge".
  @framework_package "code_my_spec"

  defp scope_filter(project_id) do
    own = dynamic([e], e.project_id == ^project_id)
    framework = dynamic([e], is_nil(e.project_id) and e.package == ^@framework_package)

    project_id
    |> locked_dependencies()
    |> Enum.reduce(dynamic(^own or ^framework), fn %{name: name, version: version}, acc ->
      dep = dynamic([e], is_nil(e.project_id) and e.package == ^name and e.version == ^version)
      dynamic(^acc or ^dep)
    end)
  end

  defp locked_dependencies(project_id) do
    Dependencies.list_dependencies(%Scope{active_project_id: project_id})
  end

  defp source_filter(source, _prefix) when not is_nil(source), do: dynamic([e], e.source == ^source)

  defp source_filter(_source, prefix) when not is_nil(prefix),
    do: dynamic([e], like(e.source, ^(prefix <> "%")))

  defp source_filter(_source, _prefix), do: dynamic(true)

  @doc """
  Store one chunk. Called by `EmbeddingService` in place of its sqlite_vec
  INSERT when this backend is active.

  `DO UPDATE`, not `DO NOTHING`: when a file changes, the row for this
  (project_id, source, path, chunk_index) already exists from the prior
  version. Doing nothing would drop the new chunk, and the stale-chunk
  cleanup that runs next would then delete the old row too — leaving the
  file with no embeddings at all.
  """
  @impl true
  def store_chunk(project_id, source, path, index, chunk, hash, file_hash) do
    with {:ok, embedding} <- Serving.embed(chunk) do
      store_embedded_chunk(project_id, source, path, index, chunk, hash, file_hash, embedding)
    end
  end

  @doc """
  Store a chunk whose vector was computed somewhere else.

  The light harness embeds on the machine that holds the file, because
  embedding needs the file's *content* and no file content crosses the wire.
  So the vector arrives already made and this server never loads a model —
  which is why `Ortex` is not a dependency of the web build.

  Identical to `store_chunk/7` past the embedding step, deliberately: one INSERT
  and one conflict target for both paths, so a row written by a harness and a
  row written locally cannot differ in shape.
  """
  @spec store_embedded_chunk(
          String.t() | nil,
          String.t(),
          String.t(),
          integer(),
          String.t(),
          String.t(),
          String.t(),
          [float()]
        ) :: :ok | {:error, term()}
  def store_embedded_chunk(project_id, source, path, index, chunk, hash, file_hash, embedding) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # The conflict target must match whichever partial unique index applies,
    # so shared rows (project_id IS NULL) name their own.
    conflict =
      if is_nil(project_id) do
        "(source, path, chunk_index) WHERE project_id IS NULL"
      else
        "(project_id, source, path, chunk_index) WHERE project_id IS NOT NULL"
      end

    sql = """
    INSERT INTO doc_embeddings
      (id, project_id, source, path, chunk_index, content, content_hash, file_hash,
       embedding, inserted_at, updated_at)
    VALUES ($1::text::uuid, $2::text::uuid, $3, $4, $5, $6, $7, $8, $9::text::vector, $10, $11)
    ON CONFLICT #{conflict} DO UPDATE SET
      content = excluded.content,
      content_hash = excluded.content_hash,
      file_hash = excluded.file_hash,
      embedding = excluded.embedding,
      updated_at = excluded.updated_at
    """

    params = [
      UUID.uuid4(),
      project_id,
      source,
      path,
      index,
      chunk,
      hash,
      file_hash,
      encode_vector(embedding),
      now,
      now
    ]

    case AdaptersSQL.query(Repo, sql, params) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # pgvector accepts its text form, "[1,2,3]" — the same shape Jason produces
  # for a list of floats.
  defp encode_vector(embedding), do: Jason.encode!(embedding)
end
