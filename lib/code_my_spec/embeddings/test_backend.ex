defmodule CodeMySpec.Embeddings.TestBackend do
  @moduledoc """
  In-memory ETS backend for tests.

  Stores chunks keyed by `{project_id, source, path, chunk_index}` →
  `content`. Search ranks by token overlap (case-insensitive word
  intersection) — enough to make the spec contract observable
  ("query that mentions tokens from a chunk surfaces that chunk")
  without dragging Ortex / sqlite_vec into the Postgres-backed test
  env.

  Tests don't need vector relevance — they assert on whether the
  expected file path appears in the response. Token overlap is
  deterministic, dependency-free, and good enough for that.
  """

  @behaviour CodeMySpec.Embeddings.Backend

  @table :code_my_spec_embeddings_test_backend
  @chunk_size 1500
  @chunk_overlap 200

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

      _ref ->
        @table
    end
  end

  @doc "Wipe the in-memory store. Useful for test setup."
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def embed_file(project_id, source, path, content) do
    ensure_table()

    chunks = chunk_text(content)

    # Drop old chunks for this file before inserting current ones.
    delete_path(project_id, source, path)

    chunks
    |> Enum.with_index()
    |> Enum.each(fn {chunk, idx} ->
      :ets.insert(@table, {{project_id, source, path, idx}, chunk})
    end)

    {:ok, %{embedded: length(chunks), skipped: 0}}
  end

  @impl true
  def delete_path(project_id, source, path) do
    ensure_table()

    pattern = {{project_id, source, path, :_}, :_}
    deleted = :ets.select_delete(@table, [{pattern, [], [true]}])
    {:ok, deleted}
  end

  @impl true
  def search(project_id, query, opts) do
    ensure_table()

    limit = Keyword.get(opts, :limit, 10)
    source = Keyword.get(opts, :source)
    source_prefix = Keyword.get(opts, :source_prefix)

    query_tokens = tokenize(query)

    results =
      :ets.tab2list(@table)
      |> Enum.filter(fn {{pid, src, _path, _idx}, _content} ->
        pid == project_id and source_match?(src, source, source_prefix)
      end)
      |> Enum.map(fn {{_pid, src, path, idx}, content} ->
        score = -overlap_score(query_tokens, content)
        {score, %{source: src, path: path, chunk_index: idx, content: content}}
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.take(limit)
      |> Enum.map(&elem(&1, 1))

    {:ok, results}
  end

  defp source_match?(_src, nil, nil), do: true
  defp source_match?(src, source, nil) when is_binary(source), do: src == source
  defp source_match?(src, nil, prefix) when is_binary(prefix), do: String.starts_with?(src, prefix)

  defp source_match?(src, source, prefix) when is_binary(source) and is_binary(prefix),
    do: src == source or String.starts_with?(src, prefix)

  defp tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> MapSet.new()
  end

  defp overlap_score(query_tokens, content) do
    content_tokens = tokenize(content)
    MapSet.intersection(query_tokens, content_tokens) |> MapSet.size()
  end

  # Mirror the production chunker's behavior so chunked content shape
  # matches between backends (each chunk ≤ @chunk_size with overlap).
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
      if new_size > max_chars, do: {:halt, {acc, new_size}}, else: {:cont, {[line | acc], new_size}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # The ETS-backed test store does its own chunking and storage inside
  # embed_file/4 rather than going through EmbeddingService, so this callback
  # is never reached. Implemented explicitly so the behaviour is satisfied and
  # a future caller gets a clear error rather than an UndefinedFunctionError.
  @impl true
  def store_chunk(_project_id, _source, _path, _index, _chunk, _hash, _file_hash) do
    {:error, :not_supported_by_test_backend}
  end
end
