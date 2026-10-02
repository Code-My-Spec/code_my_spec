defmodule CodeMySpec.Files.ProjectKnowledgeReconcileTest do
  @moduledoc """
  577de9bb step 5's triggers: a manifest that moves a `project_knowledge` row
  on the main copy, and `LockfileSweep` as the backstop. Content is read over
  the real harness transport, answered by a process registered in
  `HarnessRegistry` under the copy's id — the lookup the channel itself
  answers. No registration is the offline harness.
  """

  use CodeMySpecTest.DataCase, async: false

  @moduletag :capture_log

  import Ecto.Query
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Dependencies
  alias CodeMySpec.Embeddings
  alias CodeMySpec.Embeddings.DocEmbedding
  alias CodeMySpec.Embeddings.EmbeddingService
  alias CodeMySpec.Embeddings.PgVectorBackend
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Files.LockfileSweep
  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Projects
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.RecordingEmbeddingServing, as: Recording

  @path ".code_my_spec/knowledge/decisions.md"

  setup do
    Application.put_env(:code_my_spec, :embeddings_backend, PgVectorBackend)
    Application.put_env(:code_my_spec, :embedding_serving, Recording)
    Recording.listen(self())

    start_supervised!(
      {FLAME.Pool, name: CodeMySpec.EmbedPool, min: 0, max: 1, backend: FLAME.LocalBackend}
    )

    on_exit(fn ->
      Application.put_env(:code_my_spec, :embeddings_backend, CodeMySpec.Embeddings.TestBackend)
      Application.delete_env(:code_my_spec, :embedding_serving)
      Recording.reset()
    end)

    :ok
  end

  describe "a manifest" do
    test "that adds a knowledge file on the main copy embeds it, read over the harness" do
      %{scope: scope, dir: dir} = copy(main?: true)
      write(dir, "We chose Postgres.")
      serve_harness(scope, dir)

      manifest(scope, dir)

      assert_received {:embedded, ["We chose Postgres."], :bulk}
      hash = EmbeddingService.content_hash("We chose Postgres.")
      assert [%{path: @path, file_hash: ^hash}] = rows(scope)
      assert search_paths(scope) == [@path]
    end

    test "on a copy that is not main embeds nothing" do
      %{scope: scope, dir: dir} = copy(main?: false)
      write(dir, "We chose Postgres.")
      serve_harness(scope, dir)

      manifest(scope, dir)

      refute_received {:embedded, _, _}
      assert rows(scope) == []
    end

    test "that removes the file deletes its rows" do
      %{scope: scope, dir: dir} = copy(main?: true)
      write(dir, "We chose Postgres.")
      serve_harness(scope, dir)
      manifest(scope, dir)
      assert [_] = rows(scope)

      File.rm!(Path.join(dir, @path))
      manifest(scope, dir)

      assert rows(scope) == []
    end

    test "with the harness offline leaves the file pending and the sweep picks it up" do
      %{scope: scope, dir: dir} = copy(main?: true)
      write(dir, "first")
      harness = serve_harness(scope, dir)
      manifest(scope, dir)

      stop_harness(harness)
      write(dir, "second")
      manifest(scope, dir)

      assert [%{content: "first"}] = rows(scope)

      serve_harness(scope, dir)
      assert :ok = LockfileSweep.sweep_now()

      assert [%{content: "second"}] = rows(scope)
    end
  end

  describe "a manifest that changes mix.lock" do
    @lock ~s(%{"jason": {:hex, :jason, "1.4.4", "c5eb0cab91f094599f94d55bc63409236a8ec69a21a67814529e8d5f6cc90b3b", [:mix], [], "hexpm", "fbd2a0e24876b27c1e9b8d3b1fdc52b5f8c0edc9f6ac96d2c5d0d68b1cb9cf3b"}}\n)

    test "on the main copy updates the project's dependencies without the sweep" do
      %{scope: scope, dir: dir} = copy(main?: true)
      File.write!(Path.join(dir, "mix.lock"), @lock)
      serve_harness(scope, dir)

      manifest(scope, dir)

      assert [%{name: "jason", version: "1.4.4"}] =
               scope
               |> Dependencies.list_dependencies()
               |> Enum.map(&Map.take(&1, [:name, :version]))
    end
  end

  describe "LockfileSweep.sweep_now/0" do
    test "with the harness offline keeps existing rows and does not crash" do
      %{scope: scope, dir: dir} = copy(main?: true)
      write(dir, "first")
      harness = serve_harness(scope, dir)
      manifest(scope, dir)
      stop_harness(harness)

      write(dir, "second")
      Files.upsert_files(scope, observe(scope, dir))

      assert :ok = LockfileSweep.sweep_now()
      assert [%{content: "first"}] = rows(scope)
    end

    test "re-embeds an unchanged file whose rows are at another model" do
      %{scope: scope, dir: dir} = copy(main?: true)
      write(dir, "first")
      serve_harness(scope, dir)
      Recording.model("old-model")
      manifest(scope, dir)
      Recording.model("fake-test-model")

      assert search_paths(scope) == []

      LockfileSweep.sweep_now()

      assert [%{model: "fake-test-model"}] = rows(scope)
      assert search_paths(scope) == [@path]
    end
  end

  describe "the per-project embed path on Postgres" do
    test "writes and deletes no project_knowledge rows" do
      %{scope: scope} = copy(main?: true)

      assert {:ok, %{skipped: :reconciled}} =
               Embeddings.embed_file(scope, "project_knowledge", @path, "content")

      assert rows(scope) == []
      assert {:ok, 0} = Embeddings.delete_path(scope, "project_knowledge", @path)
    end
  end

  # A project, one checkout of it, and a harness-addressed scope for that
  # checkout — what the channel and `main_copy_scopes/0` both hand FileSync.
  defp copy(opts) do
    {:ok, dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: dir})
    scope = %{scope | active_project: project}

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, label: "test copy", device: device_fixture(scope))

    designate(scope, copy, opts[:main?])

    %{scope: WorkingCopies.put_scope(scope, copy), dir: dir}
  end

  defp designate(scope, copy, true), do: {:ok, _} = WorkingCopies.designate_main(scope, copy.id)
  defp designate(_scope, _copy, false), do: :ok

  defp write(dir, content) do
    path = Path.join(dir, @path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  # What a harness scans and sends, landed through the channel's own entry.
  defp manifest(scope, dir), do: FileSync.reconcile_and_project(scope, observe(scope, dir))

  defp observe(scope, dir) do
    {:ok, observations} = Scanner.observe(Environment.new(:local, dir), Files.read_model(scope))
    observations
  end

  defp serve_harness(scope, dir) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(HarnessRegistry, scope.active_working_copy_id, :test)
        send(test, :harness_up)
        answer(dir, scope.active_working_copy_id)
      end)

    assert_receive :harness_up
    pid
  end

  defp answer(dir, key) do
    receive do
      {:"$gen_call", from, {:fs_request, "read_file", %{"path" => path}}} ->
        GenServer.reply(from, File.read(Path.join(dir, path)))
        answer(dir, key)

      {:stop, test} ->
        Registry.unregister(HarnessRegistry, key)
        send(test, :harness_down)
    end
  end

  defp stop_harness(pid) do
    send(pid, {:stop, self()})
    assert_receive :harness_down
  end

  defp rows(scope) do
    from(e in DocEmbedding,
      where: e.project_id == ^scope.active_project_id and e.source == "project_knowledge",
      order_by: [e.path, e.chunk_index],
      select: %{path: e.path, file_hash: e.file_hash, model: e.model, content: e.content}
    )
    |> Repo.all()
  end

  defp search_paths(scope) do
    {:ok, results} = PgVectorBackend.search(scope.active_project_id, "postgres", limit: 50)
    results |> Enum.map(& &1.path) |> Enum.uniq()
  end
end
