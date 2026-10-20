defmodule CodeMySpec.Embeddings.EmbeddingService do
  @moduledoc """
  Generates and stores embeddings for project documentation.

  Chunks markdown and stores it in `doc_embeddings` through the configured
  backend's `store_chunk/7`, which embeds it.

  Content-hash deduplication: unchanged chunks skip re-embedding.
  """

  require Logger

  import Ecto.Query

  alias CodeMySpec.Embeddings.DocEmbedding
  alias CodeMySpec.Repo

  @chunk_size 1500
  @chunk_overlap 200

  @doc """
  Embed a single file's content. Chunks, deduplicates by hash, embeds new chunks.

  File-level short-circuit: if any existing chunk for this
  `(project_id, source, path)` already carries the same `file_hash` as
  the incoming bytes, we know nothing changed and return immediately
  — no chunking, no SELECT of existing chunk hashes, no DELETE of
  stale rows.
  """
  def embed_file(project_id, source, path, content) do
    file_hash = content_hash(content)

    if file_hash_matches?(project_id, source, path, file_hash) do
      {:ok, %{embedded: 0, skipped: :unchanged}}
    else
      do_embed_file(project_id, source, path, content, file_hash)
    end
  end

  defp file_hash_matches?(project_id, source, path, file_hash) do
    from(e in DocEmbedding,
      where: ^project_filter(project_id),
      where: e.source == ^source and e.path == ^path and e.file_hash == ^file_hash,
      limit: 1,
      select: 1
    )
    |> Repo.one() == 1
  end

  # `e.project_id == ^project_id` never matches a shared row: Postgres
  # evaluates `column = NULL` to NULL, not true, even when the bound
  # parameter happens to be nil — only `IS NULL` does. Every query in this
  # module scoping by project needs this, not just equality, once shared
  # (project_id IS NULL) rows exist.
  defp project_filter(nil), do: dynamic([e], is_nil(e.project_id))
  defp project_filter(project_id), do: dynamic([e], e.project_id == ^project_id)

  defp do_embed_file(project_id, source, path, content, file_hash) do
    chunks = chunk_text(content)

    existing_hashes =
      from(e in DocEmbedding,
        where: ^project_filter(project_id),
        where: e.source == ^source and e.path == ^path,
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

  defp embed_chunk(
         project_id,
         source,
         path,
         index,
         chunk,
         file_hash,
         existing_hashes,
         {emb, skip}
       ) do
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
      where: ^project_filter(project_id),
      where:
        e.source == ^source and e.path == ^path and
          (is_nil(e.file_hash) or e.file_hash != ^file_hash)
    )
    |> Repo.update_all(set: [file_hash: file_hash])
  end

  # -- Chunking --

  @doc """
  Split text into overlapping chunks, same sizing every embedded source
  uses. Public so the hex-doc reconciler (step 3) chunks hex-package
  markdown identically rather than inventing its own sizing.
  """
  @spec chunk_text(String.t()) :: [String.t()]
  def chunk_text(text) do
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

  # Storage is a Backend callback, so the configured backend is asked
  # directly rather than sniffed for — see Embeddings.Backend.store_chunk/7.
  defp generate_and_store(project_id, source, path, index, chunk, hash, file_hash) do
    case Application.get_env(:code_my_spec, :embeddings_backend) do
      nil -> {:error, :embeddings_unavailable}
      backend -> backend.store_chunk(project_id, source, path, index, chunk, hash, file_hash)
    end
  end

  # -- Deduplication --

  @doc "sha256 hex digest, the content-hash every embedded chunk is keyed on."
  @spec content_hash(String.t()) :: String.t()
  def content_hash(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  defp delete_old_chunks(project_id, source, path, current_hashes) do
    from(e in DocEmbedding,
      where: ^project_filter(project_id),
      where:
        e.source == ^source and
          e.path == ^path and
          e.content_hash not in ^current_hashes
    )
    |> Repo.delete_all()
  end
end
