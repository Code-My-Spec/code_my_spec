defmodule CodeMySpec.Embeddings.PgVectorBackendTest do
  use CodeMySpecTest.DataCase, async: false

  import Ecto.Query
  import CodeMySpec.UsersFixtures
  import CodeMySpec.ProjectsFixtures

  alias CodeMySpec.Dependencies.Dependency
  alias CodeMySpec.Embeddings.DocEmbedding
  alias CodeMySpec.Embeddings.PgVectorBackend
  alias CodeMySpec.Repo

  @vector List.duplicate(0.1, 384)

  setup do
    Application.put_env(:code_my_spec, :embedding_serving, CodeMySpecTest.FakeEmbeddingServing)
    on_exit(fn -> Application.delete_env(:code_my_spec, :embedding_serving) end)

    %{scope: full_scope_fixture()}
  end

  # `put_chunk/4` writes an ordinary (project-owned or unscoped) chunk
  # through the real store path. `put_shared_chunk/6` goes one step further
  # and stamps the identity columns afterward with a raw update — the
  # reconciler (step 3) sets them in the same INSERT instead; this is
  # `search/3`'s own test, which only needs the identity columns present,
  # not the exact write path that put them there.
  defp put_chunk(project_id, source, path, content) do
    :ok =
      PgVectorBackend.store_embedded_chunk(
        project_id,
        source,
        path,
        0,
        content,
        "file-hash",
        @vector
      )
  end

  defp put_shared_chunk(source, path, content, package, version, model) do
    put_chunk(nil, source, path, content)

    {1, _} =
      from(e in DocEmbedding, where: is_nil(e.project_id) and e.source == ^source and e.path == ^path)
      |> Repo.update_all(set: [package: package, version: version, model: model])
  end

  defp lock_dependency(project_id, name, version) do
    %Dependency{}
    |> Dependency.changeset(%{project_id: project_id, name: name, version: version, source: "hex"})
    |> Repo.insert!()
  end

  describe "own project rows" do
    test "a project's own embeddings are found", %{scope: scope} do
      project_id = scope.active_project_id
      put_chunk(project_id, "knowledge", "a.md", "the quick brown fox")

      assert {:ok, [result]} = PgVectorBackend.search(project_id, "fox", [])
      assert result.path == "a.md"
    end

    test "one project never sees another project's rows", %{scope: scope} do
      other = project_fixture(scope)
      put_chunk(other.id, "knowledge", "a.md", "the quick brown fox")

      assert {:ok, []} = PgVectorBackend.search(scope.active_project_id, "fox", [])
    end
  end

  describe "shared rows" do
    test "framework knowledge (package code_my_spec) is visible to every project", %{scope: scope} do
      put_shared_chunk("knowledge", "liveview.md", "LiveView streams", "code_my_spec", "any", "minilm-l6-v2")

      assert {:ok, [result]} = PgVectorBackend.search(scope.active_project_id, "LiveView", [])
      assert result.path == "liveview.md"
    end

    test "a hex package's docs are visible when the project's lock pins that exact version",
         %{scope: scope} do
      project_id = scope.active_project_id
      lock_dependency(project_id, "phoenix", "1.8.1")

      put_shared_chunk("hexdocs:phoenix", "Phoenix.md", "Phoenix channels", "phoenix", "1.8.1", "minilm-l6-v2")

      assert {:ok, [result]} = PgVectorBackend.search(project_id, "channels", [])
      assert result.path == "Phoenix.md"
    end

    test "a different version of the same package is not surfaced — exact versions only",
         %{scope: scope} do
      project_id = scope.active_project_id
      lock_dependency(project_id, "phoenix", "1.8.1")

      put_shared_chunk("hexdocs:phoenix", "Phoenix.md", "Phoenix channels", "phoenix", "1.7.0", "minilm-l6-v2")

      assert {:ok, []} = PgVectorBackend.search(project_id, "channels", [])
    end

    test "a package the project doesn't depend on is not surfaced", %{scope: scope} do
      put_shared_chunk("hexdocs:ecto", "Ecto.md", "Ecto changesets", "ecto", "3.11.0", "minilm-l6-v2")

      assert {:ok, []} = PgVectorBackend.search(scope.active_project_id, "changesets", [])
    end
  end

  describe "delete_path with a nil project_id" do
    test "deletes a shared row, not every row with a matching source/path", %{scope: scope} do
      put_shared_chunk("knowledge", "a.md", "shared", "code_my_spec", "any", "minilm-l6-v2")
      put_chunk(scope.active_project_id, "knowledge", "a.md", "project-owned")

      assert {:ok, 1} = PgVectorBackend.delete_path(nil, "knowledge", "a.md")
      assert {:ok, [result]} = PgVectorBackend.search(scope.active_project_id, "project", [])
      assert result.content == "project-owned"
    end
  end
end
