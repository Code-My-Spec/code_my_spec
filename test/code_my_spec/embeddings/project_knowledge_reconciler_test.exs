defmodule CodeMySpec.Embeddings.ProjectKnowledgeReconcilerTest do
  @moduledoc """
  577de9bb step 5: `doc_embeddings` project knowledge rows reconciled against
  `%{path => fingerprint}`. The reader is a plain function here; the harness
  read and the triggers are in `Files.ProjectKnowledgeReconcileTest`.
  """

  use CodeMySpecTest.DataCase, async: false

  import Ecto.Query
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Embeddings.DocEmbedding
  alias CodeMySpec.Embeddings.EmbeddingService
  alias CodeMySpec.Embeddings.ProjectKnowledgeReconciler, as: Reconciler
  alias CodeMySpec.Repo
  alias CodeMySpecTest.RecordingEmbeddingServing, as: Recording

  setup do
    Application.put_env(:code_my_spec, :embedding_serving, Recording)
    Recording.listen(self())

    start_supervised!(
      {FLAME.Pool, name: CodeMySpec.EmbedPool, min: 0, max: 1, backend: FLAME.LocalBackend}
    )

    on_exit(fn ->
      Application.delete_env(:code_my_spec, :embedding_serving)
      Recording.reset()
    end)

    %{project_id: full_scope_fixture().active_project_id}
  end

  defp fp(content), do: EmbeddingService.content_hash(content)

  defp reader(files), do: fn path -> Map.fetch(files, path) |> found() end
  defp found({:ok, content}), do: {:ok, content}
  defp found(:error), do: {:error, :enoent}

  defp offline(_path), do: {:error, {:harness_not_registered, %{}}}

  defp reconcile(project_id, files),
    do:
      Reconciler.reconcile(project_id, Map.new(files, fn {p, c} -> {p, fp(c)} end), reader(files))

  defp rows(project_id) do
    from(e in DocEmbedding,
      where: e.project_id == ^project_id,
      order_by: [e.path, e.chunk_index],
      select: %{
        path: e.path,
        source: e.source,
        file_hash: e.file_hash,
        model: e.model,
        package: e.package,
        version: e.version,
        content: e.content
      }
    )
    |> Repo.all()
  end

  defp embedded_texts do
    receive do
      {:embedded, texts, _priority} -> texts ++ embedded_texts()
    after
      0 -> []
    end
  end

  @a ".code_my_spec/knowledge/a.md"
  @b ".code_my_spec/knowledge/b.md"

  test "a new file is embedded at bulk priority as model-stamped project rows", %{
    project_id: pid
  } do
    assert {:ok, %{embedded: 1, removed: 0, kept: 0}} = reconcile(pid, %{@a => "alpha"})

    assert_received {:embedded, ["alpha"], :bulk}
    hash = fp("alpha")

    assert [
             %{
               path: @a,
               source: "project_knowledge",
               file_hash: ^hash,
               model: "fake-test-model",
               package: nil,
               version: nil
             }
           ] = rows(pid)
  end

  test "an unchanged file is not read or embedded again", %{project_id: pid} do
    {:ok, _} = reconcile(pid, %{@a => "alpha"})
    _ = embedded_texts()

    assert {:ok, %{embedded: 0, kept: 1}} =
             Reconciler.reconcile(pid, %{@a => fp("alpha")}, &offline/1)

    assert embedded_texts() == []
  end

  test "a changed fingerprint replaces that path's rows alone", %{project_id: pid} do
    {:ok, _} = reconcile(pid, %{@a => "alpha", @b => "bravo"})
    _ = embedded_texts()

    assert {:ok, %{embedded: 1, kept: 1}} = reconcile(pid, %{@a => "alpha", @b => "bravo two"})
    assert embedded_texts() == ["bravo two"]
    assert [%{path: @a, content: "alpha"}, %{path: @b, content: "bravo two"}] = rows(pid)
  end

  test "a path with no desired entry has its rows deleted", %{project_id: pid} do
    {:ok, _} = reconcile(pid, %{@a => "alpha", @b => "bravo"})

    assert {:ok, %{removed: 1}} = Reconciler.reconcile(pid, %{@a => fp("alpha")}, &offline/1)
    assert [%{path: @a}] = rows(pid)
  end

  test "rows at another model count as changed", %{project_id: pid} do
    Recording.model("old-model")
    {:ok, _} = reconcile(pid, %{@a => "alpha"})
    Recording.model("fake-test-model")
    _ = embedded_texts()

    assert {:ok, %{embedded: 1}} = reconcile(pid, %{@a => "alpha"})
    assert embedded_texts() == ["alpha"]
    assert [%{model: "fake-test-model"}] = rows(pid)
  end

  test "a nil fingerprint leaves the path's rows alone", %{project_id: pid} do
    {:ok, _} = reconcile(pid, %{@a => "alpha"})

    assert {:ok, %{embedded: 0, removed: 0}} =
             Reconciler.reconcile(pid, %{@a => nil}, &offline/1)

    assert [%{path: @a}] = rows(pid)
  end

  test "an unreadable file stays pending: nothing written, existing rows kept", %{
    project_id: pid
  } do
    {:ok, _} = reconcile(pid, %{@a => "alpha"})

    assert {:error, {:deferred, {:harness_not_registered, _}}, %{embedded: 0}} =
             Reconciler.reconcile(pid, %{@a => fp("alpha two"), @b => fp("bravo")}, &offline/1)

    assert [%{path: @a, content: "alpha"}] = rows(pid)

    assert {:ok, %{embedded: 2}} = reconcile(pid, %{@a => "alpha two", @b => "bravo"})
    assert [%{content: "alpha two"}, %{path: @b}] = rows(pid)
  end

  test "a failed embed writes nothing for that file", %{project_id: pid} do
    {:ok, _} = reconcile(pid, %{@a => "alpha"})
    Recording.fail(true)

    assert {:error, {:deferred, :serving_down}, _} = reconcile(pid, %{@a => "alpha two"})
    assert [%{content: "alpha"}] = rows(pid)
  end

  test "a large file is embedded in batches of at most 20 chunks", %{project_id: pid} do
    big = Enum.map_join(1..200, "\n", fn i -> "line #{i} " <> String.duplicate("x", 200) end)
    chunk_count = length(EmbeddingService.chunk_text(big))
    assert chunk_count > 20

    {:ok, _} = reconcile(pid, %{@a => big})

    sizes = collect_batch_sizes()
    assert Enum.sum(sizes) == chunk_count
    assert Enum.all?(sizes, &(&1 <= 20))
    assert length(rows(pid)) == chunk_count
  end

  defp collect_batch_sizes do
    receive do
      {:embedded, texts, :bulk} -> [length(texts) | collect_batch_sizes()]
    after
      0 -> []
    end
  end
end
