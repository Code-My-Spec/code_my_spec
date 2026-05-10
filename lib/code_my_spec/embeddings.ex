defmodule CodeMySpec.Embeddings do
  @moduledoc """
  Context for document embeddings and semantic search.

  Manages embedding generation for project documentation (knowledge,
  specs, rules) and provides vector similarity search across all
  embedded content.

  Storage is dispatched through `Embeddings.Backend` to a configured
  implementation. Two impls ship today:

  * `SqliteVecBackend` — production CLI binary (Ortex + sqlite_vec).
  * `TestBackend` — ETS-backed in-memory store for `:test`.

  When no backend is configured (the Phoenix dev server, or any
  runtime that hasn't opted in), `available?/0` returns false and
  every entry point returns `{:error, :embeddings_unavailable}`.
  """

  alias CodeMySpec.Users.Scope

  @doc """
  Returns `:ok` if a backend is configured, `{:error, :embeddings_unavailable}`
  otherwise.
  """
  def available? do
    backend() != nil
  end

  @doc """
  Embed a single file's content into the project's doc embedding store.

  Used by the file sync pipeline to keep embeddings in step with disk:
  whenever a tracked doc file (spec / rule / knowledge / project_knowledge)
  is added or modified, the sync pipeline calls this to upsert the
  file's chunks. Content-hash deduplication keeps the call cheap when
  nothing actually changed.
  """
  def embed_file(%Scope{active_project_id: project_id}, source, path, content) do
    case backend() do
      nil -> {:error, :embeddings_unavailable}
      mod -> mod.embed_file(project_id, source, path, content)
    end
  end

  @doc """
  Drop all embeddings for a file path.

  Used by the file sync pipeline when a tracked doc file is removed
  from disk so semantic search can't surface stale references.
  """
  def delete_path(%Scope{active_project_id: project_id}, source, path) do
    case backend() do
      nil -> {:error, :embeddings_unavailable}
      mod -> mod.delete_path(project_id, source, path)
    end
  end

  @doc """
  Sync the bundled framework knowledge corpus directly from
  `priv/knowledge/` into the embedding store.

  No working-tree copy. Each markdown file's content is embedded with
  source `"knowledge"` and the file's path relative to the knowledge
  root. Backend dedup skips unchanged content.

  Honors `Application.get_env(:code_my_spec, :framework_knowledge_dir)`
  for tests; otherwise reads `:code.priv_dir(:code_my_spec) ++ "/knowledge"`.
  """
  def sync_framework_knowledge(%Scope{} = scope) do
    case backend() do
      nil ->
        {:error, :embeddings_unavailable}

      _mod ->
        knowledge_dir =
          Application.get_env(:code_my_spec, :framework_knowledge_dir) ||
            Application.app_dir(:code_my_spec, "priv/knowledge")

        do_sync_framework_knowledge(scope, knowledge_dir)
    end
  end

  defp do_sync_framework_knowledge(scope, knowledge_dir) do
    if File.dir?(knowledge_dir) do
      knowledge_dir
      |> walk_markdown_files()
      |> Enum.each(&embed_knowledge_file(scope, knowledge_dir, &1))
    end

    :ok
  end

  defp embed_knowledge_file(scope, knowledge_dir, abs_path) do
    rel = Path.relative_to(abs_path, knowledge_dir)

    case File.read(abs_path) do
      {:ok, content} -> embed_file(scope, "knowledge", rel, content)
      {:error, _} -> :ok
    end
  end

  defp walk_markdown_files(dir) do
    dir
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
  end

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
