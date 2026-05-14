defmodule CodeMySpec.Embeddings.EmbeddingService do
  @moduledoc """
  Generates and stores embeddings for project documentation.

  Chunks markdown files, generates embeddings via Bumblebee (all-MiniLM-L6-v2, 384 dims),
  and stores them in the doc_embeddings table with sqlite_vec for vector search.

  Content-hash deduplication: unchanged chunks skip re-embedding.
  """

  require Logger

  import Ecto.Query

  alias CodeMySpec.Embeddings.DocEmbedding
  alias CodeMySpec.Embeddings.Serving
  alias CodeMySpec.Repo
  alias Ecto.Adapters.SQL, as: AdaptersSQL

  @chunk_size 1500
  @chunk_overlap 200

  @doc """
  Embed all docs for a source (e.g. "knowledge", "project_knowledge", "spec", "rules").

  Walks the directory, chunks each markdown file, and embeds changed chunks.
  Returns `{:ok, %{embedded: n, skipped: n, deleted: n}}`.
  """
  def embed_directory(project_id, source, dir_path) do
    if File.dir?(dir_path) do
      do_embed_directory(project_id, source, dir_path)
    else
      {:error, "Directory not found: #{dir_path}"}
    end
  end

  defp do_embed_directory(project_id, source, dir_path) do
    files = walk_markdown_files(dir_path)

    results =
      Enum.map(files, fn path ->
        relative = Path.relative_to(path, dir_path)
        content = File.read!(path)
        embed_file(project_id, source, relative, content)
      end)

    existing_paths = Enum.map(files, &Path.relative_to(&1, dir_path))
    deleted = delete_stale(project_id, source, existing_paths)

    embedded = Enum.sum(Enum.map(results, fn {:ok, r} -> r.embedded end))
    skipped = Enum.sum(Enum.map(results, fn {:ok, r} -> r.skipped end))

    {:ok, %{embedded: embedded, skipped: skipped, deleted: deleted}}
  end

  @doc """
  Embed a single file's content. Chunks, deduplicates by hash, embeds new chunks.

  File-level short-circuit: if any existing chunk for this
  `(project_id, source, path)` already carries the same `file_hash` as
  the incoming bytes, we know nothing changed and return immediately
  — no chunking, no SELECT of existing chunk hashes, no DELETE of
  stale rows. This is the hot path on every boot of
  `sync_framework_knowledge`.
  """
  def embed_file(project_id, source, path, content) do
    file_hash = content_hash(content)

    if file_hash_matches?(project_id, source, path, file_hash) do
      Logger.info(
        "[EmbedDecision] skip file_hash_match source=#{source} path=#{path} hash=#{String.slice(file_hash, 0, 8)}"
      )

      {:ok, %{embedded: 0, skipped: :unchanged}}
    else
      Logger.info(
        "[EmbedDecision] embed file_hash_changed source=#{source} path=#{path} hash=#{String.slice(file_hash, 0, 8)}"
      )

      do_embed_file(project_id, source, path, content, file_hash)
    end
  end

  defp file_hash_matches?(project_id, source, path, file_hash) do
    rows =
      from(e in DocEmbedding,
        where: e.project_id == ^project_id and e.source == ^source and e.path == ^path,
        select: %{file_hash: e.file_hash, chunk_index: e.chunk_index}
      )
      |> Repo.all()

    hash_summary =
      rows
      |> Enum.map(& &1.file_hash)
      |> Enum.uniq()
      |> Enum.map_join(",", fn
        nil -> "nil"
        h -> String.slice(h, 0, 8)
      end)

    Logger.info(
      "[EmbedDecision.probe] source=#{source} path=#{path} want_hash=#{String.slice(file_hash, 0, 8)} row_count=#{length(rows)} stored_hashes=[#{hash_summary}]"
    )

    Enum.any?(rows, &(&1.file_hash == file_hash))
  end

  defp do_embed_file(project_id, source, path, content, file_hash) do
    chunks = chunk_text(content)

    existing_hashes =
      from(e in DocEmbedding,
        where: e.project_id == ^project_id and e.source == ^source and e.path == ^path,
        select: e.content_hash
      )
      |> Repo.all()
      |> MapSet.new()

    {embedded, skipped} =
      chunks
      |> Enum.with_index()
      |> Enum.reduce({0, 0}, fn {chunk, index}, acc ->
        embed_chunk(project_id, source, path, index, chunk, file_hash, existing_hashes, acc)
      end)

    # Delete old chunks for this file that don't match current chunk hashes
    current_hashes = Enum.map(chunks, &content_hash/1)
    delete_old_chunks(project_id, source, path, current_hashes)

    # Backfill file_hash on any chunks that were kept (existing rows) so the
    # next call hits the fast path. New inserts already got file_hash via
    # `generate_and_store`.
    backfill_file_hash(project_id, source, path, file_hash)

    {:ok, %{embedded: embedded, skipped: skipped}}
  end

  defp embed_chunk(project_id, source, path, index, chunk, file_hash, existing_hashes, {emb, skip}) do
    hash = content_hash(chunk)

    if MapSet.member?(existing_hashes, hash) do
      {emb, skip + 1}
    else
      store_chunk(project_id, source, path, index, chunk, hash, file_hash, {emb, skip})
    end
  end

  defp store_chunk(project_id, source, path, index, chunk, hash, file_hash, {emb, skip}) do
    case generate_and_store(project_id, source, path, index, chunk, hash, file_hash) do
      :ok ->
        {emb + 1, skip}

      {:error, reason} ->
        Logger.warning(
          "[EmbeddingService] Failed to embed #{path} chunk #{index}: #{inspect(reason)}"
        )

        {emb, skip}
    end
  end

  defp backfill_file_hash(project_id, source, path, file_hash) do
    from(e in DocEmbedding,
      where:
        e.project_id == ^project_id and e.source == ^source and e.path == ^path and
          (is_nil(e.file_hash) or e.file_hash != ^file_hash)
    )
    |> Repo.update_all(set: [file_hash: file_hash])
  end

  @doc """
  Semantic search across embedded docs. Returns top matches with distance scores.
  """
  def search(project_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    source = Keyword.get(opts, :source)
    source_prefix = Keyword.get(opts, :source_prefix)

    with {:ok, query_embedding} <- generate_embedding(query),
         {:ok, rows} <- run_search_query(project_id, limit, source, source_prefix, query_embedding) do
      {:ok, Enum.map(rows, &row_to_result/1)}
    end
  end

  defp run_search_query(project_id, limit, source, source_prefix, query_embedding) do
    vector_json = Jason.encode!(query_embedding)
    {where_clause, params, filtered?} = build_where(project_id, limit, source, source_prefix)

    sql = """
    SELECT e.source, e.path, e.chunk_index, e.content
    FROM doc_embeddings e
    #{where_clause}
    ORDER BY vec_distance_cosine(e.embedding, vec_f32(?#{if filtered?, do: 4, else: 3}))
    LIMIT ?2
    """

    case AdaptersSQL.query(Repo, sql, params ++ [vector_json]) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_where(project_id, limit, source, _source_prefix) when not is_nil(source) do
    {"WHERE e.project_id = ?1 AND e.source = ?3", [project_id, limit, source], true}
  end

  defp build_where(project_id, limit, _source, source_prefix) when not is_nil(source_prefix) do
    {"WHERE e.project_id = ?1 AND e.source LIKE ?3",
     [project_id, limit, source_prefix <> "%"], true}
  end

  defp build_where(project_id, limit, _source, _source_prefix) do
    {"WHERE e.project_id = ?1", [project_id, limit], false}
  end

  defp row_to_result([src, path, chunk_index, content]) do
    %{source: src, path: path, chunk_index: chunk_index, content: content}
  end

  # -- Chunking --

  defp chunk_text(text) do
    text
    |> String.split("\n")
    |> chunk_lines([], [], 0)
    |> Enum.reject(&(&1 == ""))
  end

  defp chunk_lines([], current_lines, chunks, _size) do
    chunk = Enum.join(Enum.reverse(current_lines), "\n")
    if chunk == "", do: chunks, else: chunks ++ [chunk]
  end

  defp chunk_lines([line | rest], current_lines, chunks, current_size) do
    line_size = String.length(line) + 1

    if current_size + line_size > @chunk_size and current_lines != [] do
      chunk = Enum.join(Enum.reverse(current_lines), "\n")

      # Keep overlap lines for context
      overlap_lines = take_overlap_lines(current_lines, @chunk_overlap)
      overlap_size = overlap_lines |> Enum.join("\n") |> String.length()

      chunk_lines([line | rest], overlap_lines, chunks ++ [chunk], overlap_size)
    else
      chunk_lines(rest, [line | current_lines], chunks, current_size + line_size)
    end
  end

  defp take_overlap_lines(lines, max_chars) do
    lines
    |> Enum.reduce_while({[], 0}, fn line, {acc, size} ->
      new_size = size + String.length(line) + 1

      if new_size > max_chars do
        {:halt, {acc, new_size}}
      else
        {:cont, {[line | acc], new_size}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # -- Embedding generation --

  defp generate_and_store(project_id, source, path, index, chunk, hash, file_hash) do
    case generate_embedding(chunk) do
      {:ok, embedding} ->
        vector_json = Jason.encode!(embedding)
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        sql = """
        INSERT INTO doc_embeddings (id, project_id, source, path, chunk_index, content, content_hash, file_hash, embedding, inserted_at, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, vec_f32(?9), ?10, ?11)
        ON CONFLICT DO NOTHING
        """

        params = [
          UUID.uuid4(), project_id, source, path, index, chunk, hash, file_hash, vector_json, now, now
        ]

        case AdaptersSQL.query(Repo, sql, params) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_embedding(text) do
    Serving.embed(text)
  end

  # -- Deduplication --

  defp content_hash(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  defp delete_old_chunks(project_id, source, path, current_hashes) do
    from(e in DocEmbedding,
      where:
        e.project_id == ^project_id and
          e.source == ^source and
          e.path == ^path and
          e.content_hash not in ^current_hashes
    )
    |> Repo.delete_all()
  end

  defp delete_stale(project_id, source, existing_paths) do
    {count, _} =
      from(e in DocEmbedding,
        where:
          e.project_id == ^project_id and
            e.source == ^source and
            e.path not in ^existing_paths
      )
      |> Repo.delete_all()

    count
  end

  # -- File walking --

  defp walk_markdown_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.flat_map(&expand_entry(dir, &1))

      _ ->
        []
    end
  end

  defp expand_entry(dir, name) do
    full = Path.join(dir, name)

    cond do
      File.dir?(full) -> walk_markdown_files(full)
      String.ends_with?(name, ".md") -> [full]
      true -> []
    end
  end
end
