defmodule CodeMySpec.Embeddings.FrameworkKnowledgeReconcilerTest do
  @moduledoc """
  577de9bb step 4: `priv/knowledge` reconciled into shared rows on boot.
  A temp dir stands in for the release's knowledge dir; `RecordingServing`
  stands in for Ortex and reports every batch it embeds.
  """

  use CodeMySpecTest.DataCase, async: false

  # Pgvector: Postgres only.
  @moduletag :postgres

  import Ecto.Query
  import CodeMySpec.UsersFixtures
  import CodeMySpec.ProjectsFixtures

  alias CodeMySpec.Embeddings.DocEmbedding
  alias CodeMySpec.Embeddings.DocPackage
  alias CodeMySpec.Embeddings.FrameworkKnowledgeReconciler, as: Reconciler
  alias CodeMySpec.Embeddings.PgVectorBackend
  alias CodeMySpec.Repo

  defmodule RecordingServing do
    @moduledoc false
    @behaviour CodeMySpec.Embeddings.Serving

    @vector List.duplicate(0.1, 384)

    @impl true
    def start_link(_opts), do: :ignore

    @impl true
    def embed(_text, _priority), do: {:ok, @vector}

    @impl true
    def embed_batch(texts, priority) do
      send(:persistent_term.get({__MODULE__, :pid}), {:embedded, texts, priority})

      respond(texts, :persistent_term.get({__MODULE__, :fail}, false))
    end

    defp respond(_texts, true), do: {:error, :serving_down}
    defp respond(texts, false), do: {:ok, Enum.map(texts, fn _ -> @vector end)}

    @impl true
    def model_name, do: "fake-test-model"
  end

  setup do
    dir = CodeMySpec.TempFile.owned_dir("test")
    Application.put_env(:code_my_spec, :framework_knowledge_dir, dir)
    Application.put_env(:code_my_spec, :embedding_serving, RecordingServing)
    :persistent_term.put({RecordingServing, :pid}, self())
    :persistent_term.put({RecordingServing, :fail}, false)

    start_supervised!(
      {FLAME.Pool, name: CodeMySpec.EmbedPool, min: 0, max: 1, backend: FLAME.LocalBackend}
    )

    on_exit(fn ->
      Application.delete_env(:code_my_spec, :framework_knowledge_dir)
      Application.delete_env(:code_my_spec, :embedding_serving)
      :persistent_term.erase({RecordingServing, :pid})
      :persistent_term.erase({RecordingServing, :fail})
    end)

    %{dir: dir, scope: full_scope_fixture()}
  end

  defp write(dir, rel, content) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp rows do
    from(e in DocEmbedding,
      where: e.package == "code_my_spec",
      order_by: [e.path, e.chunk_index],
      select: %{
        path: e.path,
        project_id: e.project_id,
        source: e.source,
        version: e.version,
        model: e.model,
        content: e.content
      }
    )
    |> Repo.all()
  end

  defp markers, do: Repo.all(from(p in DocPackage, where: p.package == "code_my_spec"))

  defp embedded_texts do
    receive do
      {:embedded, texts, _priority} -> texts ++ embedded_texts()
    after
      0 -> []
    end
  end

  defp search_paths(project_id, query) do
    {:ok, results} = PgVectorBackend.search(project_id, query, limit: 50)
    results |> Enum.map(& &1.path) |> Enum.sort()
  end

  test "first boot embeds every markdown file as shared, model-stamped rows under one marker",
       %{dir: dir} do
    write(dir, "liveview.md", "LiveView streams")
    write(dir, "bdd/spex.md", "Spex given when then")
    write(dir, "script.sh", "echo not embedded")

    assert {:ok, %{embedded: 2, kept: 0, removed: 0, chunk_count: 2, version: version}} =
             Reconciler.reconcile()

    assert version == Reconciler.corpus_version(Reconciler.desired_files(dir))

    assert [
             %{
               path: "bdd/spex.md",
               project_id: nil,
               source: "knowledge",
               version: ^version,
               model: "fake-test-model"
             },
             %{path: "liveview.md", project_id: nil, version: ^version, model: "fake-test-model"}
           ] = rows()

    assert [
             %DocPackage{
               version: ^version,
               model: "fake-test-model",
               status: "embedded",
               chunk_count: 2
             }
           ] =
             markers()
  end

  test "embedding runs at bulk priority", %{dir: dir} do
    write(dir, "a.md", "alpha")
    {:ok, _} = Reconciler.reconcile()
    assert_received {:embedded, ["alpha"], :bulk}
  end

  test "a second boot with nothing changed does no embedding work", %{dir: dir} do
    write(dir, "a.md", "alpha")
    {:ok, _} = Reconciler.reconcile()
    _ = embedded_texts()
    before = rows()

    assert {:ok, :up_to_date} = Reconciler.reconcile()
    assert embedded_texts() == []
    assert rows() == before
  end

  test "a changed file is re-embedded alone; unchanged files keep their vectors under the new version",
       %{dir: dir} do
    write(dir, "a.md", "alpha")
    write(dir, "b.md", "bravo")
    {:ok, %{version: v1}} = Reconciler.reconcile()
    _ = embedded_texts()

    write(dir, "b.md", "bravo two")

    assert {:ok, %{embedded: 1, kept: 1, removed: 0, version: v2}} = Reconciler.reconcile()
    assert v2 != v1
    assert embedded_texts() == ["bravo two"]

    assert [%{path: "a.md", version: ^v2}, %{path: "b.md", version: ^v2, content: "bravo two"}] =
             rows()

    assert [%DocPackage{version: ^v2}] = markers()
  end

  test "a removed file's rows are pruned", %{dir: dir, scope: scope} do
    write(dir, "a.md", "alpha")
    write(dir, "gone.md", "going away")
    {:ok, _} = Reconciler.reconcile()

    File.rm!(Path.join(dir, "gone.md"))

    assert {:ok, %{embedded: 0, kept: 1, removed: 1}} = Reconciler.reconcile()
    assert [%{path: "a.md"}] = rows()
    assert search_paths(scope.active_project_id, "going away") == ["a.md"]
  end

  test "search returns framework knowledge for any project", %{dir: dir, scope: scope} do
    write(dir, "liveview.md", "LiveView streams")
    {:ok, _} = Reconciler.reconcile()

    other = project_fixture(scope)

    assert search_paths(scope.active_project_id, "streams") == ["liveview.md"]
    assert search_paths(other.id, "streams") == ["liveview.md"]
  end

  test "a failed embed writes nothing and leaves the previous corpus searchable", %{
    dir: dir,
    scope: scope
  } do
    write(dir, "a.md", "alpha")
    {:ok, %{version: v1}} = Reconciler.reconcile()

    write(dir, "b.md", "bravo")
    :persistent_term.put({RecordingServing, :fail}, true)

    assert {:error, :serving_down} = Reconciler.reconcile()
    assert [%{path: "a.md", version: ^v1}] = rows()
    assert [%DocPackage{version: ^v1}] = markers()
    assert search_paths(scope.active_project_id, "alpha") == ["a.md"]

    :persistent_term.put({RecordingServing, :fail}, false)
    assert {:ok, %{embedded: 1, kept: 1}} = Reconciler.reconcile()
    assert search_paths(scope.active_project_id, "alpha") == ["a.md", "b.md"]
  end

  test "rows without a complete marker are not searchable and are replaced on the next run",
       %{dir: dir, scope: scope} do
    write(dir, "a.md", "alpha")
    version = Reconciler.corpus_version(Reconciler.desired_files(dir))

    :ok =
      PgVectorBackend.store_embedded_chunk(
        nil,
        "knowledge",
        "half.md",
        0,
        "half",
        "h",
        List.duplicate(0.1, 384),
        package: "code_my_spec",
        version: version,
        model: "fake-test-model"
      )

    assert search_paths(scope.active_project_id, "half") == []

    assert {:ok, %{embedded: 1}} = Reconciler.reconcile()
    assert [%{path: "a.md"}] = rows()
  end

  test "a missing knowledge dir marks an empty corpus without crashing", %{dir: dir} do
    File.rm_rf!(dir)

    assert {:ok, %{embedded: 0, chunk_count: 0}} = Reconciler.reconcile()
    assert [%DocPackage{status: "no_docs"}] = markers()
    assert {:ok, :up_to_date} = Reconciler.reconcile()
  end

  test "the boot child is a temporary task that reconciles once and exits", %{dir: dir} do
    write(dir, "a.md", "alpha")

    assert %{restart: :temporary} = Supervisor.child_spec(Reconciler, [])

    pid = start_supervised!(Reconciler)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    assert [%DocPackage{status: "embedded"}] = markers()
  end

  test "reconcile_on_boot never raises on failure", %{dir: dir} do
    write(dir, "a.md", "alpha")
    :persistent_term.put({RecordingServing, :fail}, true)

    assert :ok = Reconciler.reconcile_on_boot()
    assert markers() == []
  end
end
