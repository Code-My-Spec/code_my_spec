defmodule CodeMySpec.EmbeddingsTest do
  # async: false because `sync_framework_knowledge` reads
  # `Application.get_env(:code_my_spec, :framework_knowledge_dir)` —
  # tests put a per-test value via `Application.put_env` and
  # concurrent tests would race on the global.
  use ExUnit.Case, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Embeddings
  alias CodeMySpec.Embeddings.TestBackend
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Projects
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
    TestBackend.reset()

    # Use a tmp dir as the priv/knowledge stand-in so we can write
    # arbitrary files into it. `sync_framework_knowledge/1` reads
    # this Application env when set; otherwise it falls back to
    # the real priv/knowledge dir of the running app.
    {:ok, knowledge_dir} = Briefly.create(directory: true)
    prior = Application.get_env(:code_my_spec, :framework_knowledge_dir)
    Application.put_env(:code_my_spec, :framework_knowledge_dir, knowledge_dir)

    on_exit(fn ->
      if prior do
        Application.put_env(:code_my_spec, :framework_knowledge_dir, prior)
      else
        Application.delete_env(:code_my_spec, :framework_knowledge_dir)
      end
    end)

    %{knowledge_dir: knowledge_dir}
  end

  describe "sync_framework_knowledge/1" do
    test "embeds every markdown file under priv/knowledge with relative paths",
         %{knowledge_dir: knowledge_dir} do
      scope = setup_scope()

      File.write!(
        Path.join(knowledge_dir, "liveview.md"),
        "Phoenix LiveView is a real-time UI framework using stateful processes."
      )

      File.mkdir_p!(Path.join(knowledge_dir, "bdd"))

      File.write!(
        Path.join([knowledge_dir, "bdd", "spex.md"]),
        "BDD specs use SexySpex with given_/when_/then_ steps."
      )

      assert :ok = Embeddings.sync_framework_knowledge(scope)

      {:ok, results} =
        Embeddings.search(scope, "real-time UI framework",
          source: "knowledge",
          limit: 10
        )

      paths = Enum.map(results, & &1.path)
      assert "liveview.md" in paths
      assert "bdd/spex.md" in paths
    end

    test "is idempotent — re-running on unchanged content adds no duplicates",
         %{knowledge_dir: knowledge_dir} do
      scope = setup_scope()

      File.write!(
        Path.join(knowledge_dir, "boundary.md"),
        "Boundary enforces dependency rules at compile time across modules."
      )

      :ok = Embeddings.sync_framework_knowledge(scope)
      :ok = Embeddings.sync_framework_knowledge(scope)
      :ok = Embeddings.sync_framework_knowledge(scope)

      {:ok, results} =
        Embeddings.search(scope, "Boundary enforces dependency rules",
          source: "knowledge",
          limit: 10
        )

      assert Enum.count(results, &(&1.path == "boundary.md")) == 1
    end

    test "non-markdown files in priv/knowledge are not embedded",
         %{knowledge_dir: knowledge_dir} do
      scope = setup_scope()

      File.write!(Path.join(knowledge_dir, "ignore_me.txt"), "should not embed")
      File.write!(Path.join(knowledge_dir, "real.md"), "real content here")

      :ok = Embeddings.sync_framework_knowledge(scope)

      {:ok, results} =
        Embeddings.search(scope, "should not embed", source: "knowledge", limit: 10)

      refute Enum.any?(results, &(&1.path == "ignore_me.txt"))
    end

    test "returns gracefully when the configured knowledge dir doesn't exist",
         %{knowledge_dir: knowledge_dir} do
      scope = setup_scope()
      File.rm_rf!(knowledge_dir)

      assert :ok = Embeddings.sync_framework_knowledge(scope)
    end

    test "returns {:error, :embeddings_unavailable} when no backend is configured" do
      scope = setup_scope()

      prior = Application.get_env(:code_my_spec, :embeddings_backend)
      Application.delete_env(:code_my_spec, :embeddings_backend)

      try do
        assert {:error, :embeddings_unavailable} =
                 Embeddings.sync_framework_knowledge(scope)
      after
        if prior, do: Application.put_env(:code_my_spec, :embeddings_backend, prior)
      end
    end
  end

  defp setup_scope do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

    %{
      scope
      | active_project: project,
        cwd: tmp_dir,
        environment: Environment.new(:local, tmp_dir)
    }
  end
end
