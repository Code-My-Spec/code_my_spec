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

  @chunk_size 1500
  @chunk_overlap 200

  @doc """
  Embed all docs for a source (e.g. "knowledge", "project_knowledge", "spec", "rules").

  Walks the directory, chunks each markdown file, and embeds changed chunks.
  Returns `{:ok, %{embedded: n, skipped: n, deleted: n}}`.
  """
  def embed_directory(project_id, source, dir_path) do
    unless File.dir?(dir_path) do
      {:error, "Directory not found: #{dir_path}"}
    else
      files = walk_markdown_files(dir_path)

      results =
        Enum.map(files, fn path ->
          relative = Path.relative_to(path, dir_path)
          content = File.read!(path)
          embed_file(project_id, source, relative, content)
        end)

      # Delete embeddings for files that no longer exist
      existing_paths = Enum.map(files, &Path.relative_to(&1, dir_path))
      deleted = delete_stale(project_id, source, existing_paths)

      embedded = Enum.sum(Enum.map(results, fn {:ok, r} -> r.embedded end))
      skipped = Enum.sum(Enum.map(results, fn {:ok, r} -> r.skipped end))

      {:ok, %{embedded: embedded, skipped: skipped, deleted: deleted}}
    end
  end

  @doc """
  Embed a single file's content. Chunks, deduplicates by hash, embeds new chunks.
  """
  def embed_file(project_id, source, path, content) do
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
      |> Enum.reduce({0, 0}, fn {chunk, index}, {emb, skip} ->
        hash = content_hash(chunk)

        if MapSet.member?(existing_hashes, hash) do
          {emb, skip + 1}
        else
          case generate_and_store(project_id, source, path, index, chunk, hash) do
            :ok -> {emb + 1, skip}
            {:error, reason} ->
              Logger.warning("[EmbeddingService] Failed to embed #{path} chunk #{index}: #{inspect(reason)}")
              {emb, skip}
          end
        end
      end)

    # Delete old chunks for this file that don't match current chunk hashes
    current_hashes = Enum.map(chunks, &content_hash/1)
    delete_old_chunks(project_id, source, path, current_hashes)

    {:ok, %{embedded: embedded, skipped: skipped}}
  end

  @doc """
  Semantic search across embedded docs. Returns top matches with distance scores.
  """
  def search(project_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    source = Keyword.get(opts, :source)
    source_prefix = Keyword.get(opts, :source_prefix)

    case generate_embedding(query) do
      {:ok, query_embedding} ->
        vector_json = Jason.encode!(query_embedding)

        {where_clause, params, filtered?} =
          cond do
            source ->
              {"WHERE e.project_id = ?1 AND e.source = ?3",
               [project_id, limit, source], true}

            source_prefix ->
              {"WHERE e.project_id = ?1 AND e.source LIKE ?3",
               [project_id, limit, source_prefix <> "%"], true}

            true ->
              {"WHERE e.project_id = ?1", [project_id, limit], false}
          end

        sql = """
        SELECT e.source, e.path, e.chunk_index, e.content
        FROM doc_embeddings e
        #{where_clause}
        ORDER BY vec_distance_cosine(e.embedding, vec_f32(?#{if filtered?, do: 4, else: 3}))
        LIMIT ?2
        """

        params = params ++ [vector_json]

        case Ecto.Adapters.SQL.query(Repo, sql, params) do
          {:ok, %{rows: rows}} ->
            results =
              Enum.map(rows, fn [src, path, chunk_index, content] ->
                %{source: src, path: path, chunk_index: chunk_index, content: content}
              end)

            {:ok, results}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
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

  defp generate_and_store(project_id, source, path, index, chunk, hash) do
    case generate_embedding(chunk) do
      {:ok, embedding} ->
        vector_json = Jason.encode!(embedding)
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        sql = """
        INSERT INTO doc_embeddings (id, project_id, source, path, chunk_index, content, content_hash, embedding, inserted_at, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, vec_f32(?8), ?9, ?10)
        ON CONFLICT DO NOTHING
        """

        case Ecto.Adapters.SQL.query(Repo, sql, [
               UUID.uuid4(), project_id, source, path, index, chunk, hash, vector_json, now, now
             ]) do
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
        |> Enum.flat_map(fn name ->
          full = Path.join(dir, name)

          cond do
            File.dir?(full) -> walk_markdown_files(full)
            String.ends_with?(name, ".md") -> [full]
            true -> []
          end
        end)

      _ ->
        []
    end
  end

end
