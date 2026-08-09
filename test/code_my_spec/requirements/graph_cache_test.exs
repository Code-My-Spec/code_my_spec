defmodule CodeMySpec.Requirements.GraphCacheTest do
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.BddRules
  alias CodeMySpec.Configurations
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Issues
  alias CodeMySpec.Paths
  alias CodeMySpec.Personas
  alias CodeMySpec.Projects
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.CachedGraph
  alias CodeMySpec.Requirements.{GraphCache, GraphFingerprint, Preloader, RequirementGraph}
  alias CodeMySpec.Stories
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Repo)
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

    test "an unchanged republish does not rewrite the row" do
      scope = setup_project()

      RequirementGraph.compute_graph(scope)
      {:ok, _graph, first_at} = GraphCache.fetch_any(scope)

      # Readers call compute_graph/1 too — the UI does, on every render — so a
      # write per call would be a ~30KB upsert to say what the row already says.
      RequirementGraph.compute_graph(scope)
      {:ok, _graph, second_at} = GraphCache.fetch_any(scope)

      assert first_at == second_at
    end

    test "republishing replaces the row rather than accumulating snapshots" do
      scope = setup_project()

      RequirementGraph.compute_graph(scope)
      RequirementGraph.compute_graph(scope)

      assert 1 = Repo.aggregate(CachedGraph, :count)
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

      assert {:ok, {_nodes, _edges}, %DateTime{}} = GraphCache.fetch(scope, fingerprint)
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
      {:ok, _} = FileSync.sync(scope, base_dir: scope.cwd)

      refute current_fingerprint(scope) == before
    end
  end

  defp current_fingerprint(scope) do
    GraphFingerprint.compute(
      Preloader.load(scope),
      Configurations.get_or_create(scope)
    )
  end

  # The fingerprint decides whether a published graph may be served instead of
  # recomputed, so anything it cannot see is something an agent can be told is
  # still true after it stopped being true.
  #
  # Node inputs — files, components, stories — were covered from the start. The
  # inputs the `:delegate` requirements read were not: `three_amigos_complete`
  # asks `BddRulesChecker`, which reads rules, criteria and questions;
  # `personas_complete` asks about personas; `issues_triaged` and
  # `issues_resolved` read issues. None of those five appear anywhere else in
  # the preloader, so the fingerprint was blind to all of them.
  #
  # One test per input. A hand-written list of dependencies rots silently, and
  # the way it rots is that the graph stops noticing something.
  describe "the fingerprint covers what the delegate checkers read" do
    setup do
      scope = setup_project()
      %{scope: scope, before: current_fingerprint(scope)}
    end

    test "a new rule moves it", %{scope: scope, before: before} do
      story = story_fixture(scope)
      persona = persona_fixture(scope)
      # A rule needs its story to have a voice — `create_rule/3` refuses with
      # `:persona_linkage_required` otherwise.
      {:ok, _} = Personas.link_persona_to_story(scope, persona.id, story.id)

      {:ok, _} = BddRules.create_rule(scope, story.id, %{statement: "a new rule"})

      refute current_fingerprint(scope) == before
    end

    test "a new persona moves it", %{scope: scope, before: before} do
      persona_fixture(scope)

      refute current_fingerprint(scope) == before
    end

    test "a new issue moves it", %{scope: scope, before: before} do
      {:ok, _} =
        Issues.create_issue(scope, %{
          title: "something is wrong",
          description: "details",
          severity: :high
        })

      refute current_fingerprint(scope) == before
    end

    # `QaIntegrationPlan` reads these, so the fingerprint has to see them move.
    #
    # It once could not: `Scanner.classify/1` had no rule for the integrations
    # directory, so the walker descended into it and `stream_files/1` dropped
    # every file it found. `DelegateFiles` hashed them off disk to close that.
    # Classify claims them now (`{&Paths.integrations_dir/0, :integration}`),
    # they sync like anything else, and `files_digest` carries each row's
    # content hash — so the coverage comes from the file table and the
    # side-channel digest is gone.
    #
    # Written *and synced*, because that is the sequence in production: the
    # harness scans, rows land, the fingerprint moves. A test that only wrote
    # to disk was asserting the side channel rather than the behaviour.
    test "an integration spec appearing moves it", %{scope: scope, before: before} do
      write_integration_spec(scope, "status: pending")

      refute current_fingerprint(scope) == before
    end

    test "an integration spec changing in place moves it", %{scope: scope} do
      write_integration_spec(scope, "status: pending")
      pending = current_fingerprint(scope)

      # Same path, so a digest over names alone would not move. The status is
      # the whole of what the check reads, which is why the row's content
      # fingerprint — not its path — is what has to carry this.
      write_integration_spec(scope, "status: verified")

      refute current_fingerprint(scope) == pending
    end

    test "nothing changing leaves it alone", %{scope: scope, before: before} do
      assert current_fingerprint(scope) == before,
             "an unchanged project must produce a stable fingerprint, or the cache " <>
               "never hits and the whole projection is dead weight"
    end
  end

  defp write_integration_spec(scope, body) do
    spec = Path.join([scope.cwd, Paths.integrations_dir(), "stripe.md"])
    File.mkdir_p!(Path.dirname(spec))
    File.write!(spec, "# Stripe\n\n#{body}\n")
    {:ok, _} = FileSync.sync(scope, base_dir: scope.cwd)
  end

  defp persona_fixture(scope) do
    n = System.unique_integer([:positive])

    {:ok, persona} =
      Personas.create_persona(scope, %{
        name: "Sam #{n}",
        slug: "sam-#{n}",
        description: "the operator"
      })

    persona
  end

  defp story_fixture(scope) do
    {:ok, story} =
      Stories.create_story(scope, %{
        title: "A story #{System.unique_integer([:positive])}",
        description: "for the rule to hang off"
      })

    story
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
