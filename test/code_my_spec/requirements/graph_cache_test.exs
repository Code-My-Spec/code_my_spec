defmodule CodeMySpec.Requirements.GraphCacheTest do
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Projects
  alias CodeMySpec.Requirements.{GraphCache, GraphFingerprint, Preloader, RequirementGraph}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "publishing" do
    test "computing a graph publishes it, and the snapshot round-trips exactly" do
      scope = setup_project()

      {nodes, edges} = RequirementGraph.compute_graph(scope)

      assert {:ok, {cached_nodes, cached_edges}, computed_at} = GraphCache.fetch_any(scope)

      # Requirement structs and `{entity_type, entity_id, name}` edge tuples both
      # survive the round trip. This is the property that justifies storing the
      # payload as an Erlang term instead of hand-writing a JSON codec — a codec
      # that silently dropped a field would surface as a malformed requirement
      # handed to an agent, not as a decode error.
      assert cached_nodes == nodes
      assert cached_edges == edges
      assert %DateTime{} = computed_at
    end

    test "republishing replaces the row rather than accumulating snapshots" do
      scope = setup_project()

      RequirementGraph.compute_graph(scope)
      RequirementGraph.compute_graph(scope)

      assert 1 = CodeMySpec.Repo.aggregate(CodeMySpec.Requirements.CachedGraph, :count)
    end

    test "a project with no published graph reports a miss rather than raising" do
      scope = setup_project()

      assert :miss = GraphCache.fetch_any(scope)
      assert :miss = GraphCache.fetch(scope, "whatever")
    end
  end

  describe "fingerprint matching" do
    test "fetch/2 hits for the fingerprint the graph was computed from" do
      scope = setup_project()
      RequirementGraph.compute_graph(scope)

      fingerprint = current_fingerprint(scope)

      assert {:ok, {_nodes, _edges}} = GraphCache.fetch(scope, fingerprint)
    end

    test "fetch/2 misses for any other fingerprint" do
      scope = setup_project()
      RequirementGraph.compute_graph(scope)

      assert :miss = GraphCache.fetch(scope, "not-the-fingerprint")
    end

    test "the fingerprint is stable across independent loads of unchanged inputs" do
      scope = setup_project()

      # Two separate preloads. Nothing changed between them, so the digest must
      # agree — otherwise the snapshot would be reported stale on every read and
      # the fingerprint would carry no information at all.
      assert current_fingerprint(scope) == current_fingerprint(scope)
    end

    test "the fingerprint moves when a file changes" do
      scope = setup_project()
      before = current_fingerprint(scope)

      File.write!(Path.join(scope.cwd, "mix.exs"), "defmodule App.MixProject do\nend\n")
      {:ok, _} = CodeMySpec.Files.FileSync.sync(scope, base_dir: scope.cwd)

      refute current_fingerprint(scope) == before
    end
  end

  defp current_fingerprint(scope) do
    GraphFingerprint.compute(
      Preloader.load(scope),
      CodeMySpec.Configurations.get_or_create(scope)
    )
  end

  defp setup_project do
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
