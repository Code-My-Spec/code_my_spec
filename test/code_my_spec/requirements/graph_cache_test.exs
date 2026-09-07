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
  alias CodeMySpec.Requirements.Difference
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Requirements.{GraphCache, GraphFingerprint, Preloader, RequirementGraph}
  alias CodeMySpec.Stories
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Repo)
  end

  describe "publishing" do
    # What the `payload` column used to assert, asked of what replaced it.
    #
    # The snapshot held the whole graph as an Erlang term and this test compared
    # it back. The rows are the graph now, so the round trip that matters is
    # through `requirements` and `requirement_edges` — the same one
    # `verify_round_trip/4` runs on every publish in production, and the
    # evidence that let the payload go.
    test "computing a graph publishes it, and the rows round-trip exactly" do
      scope = setup_project()

      {nodes, edges} = RequirementGraph.compute_graph(scope)
      {read_nodes, read_edges} = Projection.load(scope, ctx!(scope))

      assert Difference.describe(read_nodes, read_edges, nodes, edges) == :none

      assert {:ok, node_count, computed_at} = GraphCache.fetch(scope, current_fingerprint(scope))
      assert node_count == length(nodes)
      assert %DateTime{} = computed_at
    end

    test "an unchanged republish does not rewrite the row" do
      scope = setup_project()

      RequirementGraph.compute_graph(scope)
      {:ok, _count, first_at} = GraphCache.fetch(scope, current_fingerprint(scope))

      # Readers call compute_graph/1 too — the UI does, on every render — so a
      # write per call would rewrite the row to say what it already says, and
      # would move `computed_at` to now on a graph computed much earlier.
      RequirementGraph.compute_graph(scope)
      {:ok, _count, second_at} = GraphCache.fetch(scope, current_fingerprint(scope))

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

      assert :miss = GraphCache.fetch(scope, "whatever")
    end

    # The one thing the rows cannot say about themselves, and the reason
    # `node_count` outlived the payload: rows that are empty where the publish
    # counted nodes were never written. `served_graph/3` treats that as a miss
    # and recomputes, because an empty graph tells an agent it has no work.
    test "the count the publish recorded rides along with the hit" do
      scope = setup_project()

      {nodes, _edges} = RequirementGraph.compute_graph(scope)

      assert {:ok, node_count, _at} = GraphCache.fetch(scope, current_fingerprint(scope))
      assert node_count == length(nodes)
      assert node_count > 0
    end

    # Deleting every row leaves a cache row whose fingerprint still matches, so
    # this is exactly the state the payload used to cover. The graph has to come
    # back rather than read as empty.
    test "a hit whose rows were never written recomputes instead of serving nothing" do
      scope = setup_project()

      {nodes, _edges} = RequirementGraph.compute_graph(scope)
      assert nodes != []

      Repo.delete_all(CodeMySpec.Requirements.Node)

      {recomputed, _edges} = RequirementGraph.cached_graph(scope) |> elem(0)

      assert length(recomputed) == length(nodes),
             "an empty projection behind a matching fingerprint is a failed write, " <>
               "not a project with no requirements"
    end
  end

  describe "fingerprint matching" do
    test "fetch/2 hits for the fingerprint the graph was computed from" do
      scope = setup_project()
      RequirementGraph.compute_graph(scope)

      fingerprint = current_fingerprint(scope)

      assert {:ok, node_count, %DateTime{}} = GraphCache.fetch(scope, fingerprint)
      assert is_integer(node_count)
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

  defp ctx!(scope) do
    {:ok, ctx} = Preloader.load(scope)
    ctx
  end

  defp current_fingerprint(scope) do
    GraphFingerprint.compute(
      ctx!(scope),
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

    # `deploy` asks `Deploys.uat_check/3`, which reads `uat_deploy_by_story` — a
    # collection the preloader loads and the fingerprint did not hash. So a
    # deploy landing moved the graph and not the hash, and `cached_graph/1`
    # served the pre-deploy projection as current.
    #
    # This is the exact failure 16a24105 describes — "a cached graph can tell an
    # agent work is finished that a deploy has just reopened" — and the spex it
    # names as having caught it before, `criterion_7321`, no longer exists: that
    # criterion has no row, so it went when its story's criteria were rewritten.
    # (Not lost to the renumbering, as the comment in `requirement_graph.ex` used
    # to guess: "859" is a primary key, the story's number is 973, and
    # `test/spex/973_…` is on disk.)
    #
    # This block is what replaced it, and it had no test for the one input that
    # is not a table the checkers query directly.
    test "a deploy landing moves it", %{scope: scope, before: before} do
      story = story_fixture(scope)
      {:ok, _} = CodeMySpec.Deploys.record(scope, story.id, "uat", status: "succeeded")

      refute current_fingerprint(scope) == before,
             "a deploy reopens `deploy` for its story; a fingerprint blind to it " <>
               "serves the graph from before the deploy"
    end

    # `stories_exist` asks `StoriesChecker`, which calls
    # `Stories.project_has_stories?/1` — every story in the project. The
    # fingerprint hashes `ctx.stories`, which the preloader filters to
    # `ready_for_dev == true`, because only released stories project into the
    # graph. So a project whose only story is parked reads as having none, and
    # creating one does not move the hash.
    #
    # Same shape as the deploy gap one test up, and the reason both existed: the
    # fingerprint hashes what the graph is computed *from*, and a delegate is
    # free to read something the graph is not computed from.
    #
    # Onboarding is exactly when this bites — a first story is created before
    # anyone marks it ready, and the graph is what the agent is following.
    test "a story that is not ready for dev still moves it", %{scope: scope, before: before} do
      {:ok, _story} =
        CodeMySpec.Stories.create_story(scope, %{
          title: "parked",
          description: "not released for development",
          ready_for_dev: false
        })

      refute current_fingerprint(scope) == before,
             "`stories_exist` counts every story; a fingerprint that only sees " <>
               "ready ones serves a graph saying the project has none"
    end

    # `architecture_designed` asks `ArchitectureChecker`, whose `orphans/1` reads
    # `Components.list_components_with_dependencies/1` — a component is not an
    # orphan if something depends on it, and no table carries that: it is the
    # `:dependencies` association preloaded onto each component.
    #
    # It is covered, and by a narrower rule than the comment on `struct_digest/1`
    # reads at a glance. "Associations are dropped" means *not-loaded* ones;
    # loaded ones are summarized by `assoc_id/1`, so a preloaded dependency list
    # is hashed as a list of ids and gains one when an edge is added.
    #
    # Pinned because that is a fine distinction holding up a whole requirement.
    # A change to `struct_digest/1` that dropped loaded associations too — which
    # its own comment could be read as licence for — would silently stop the
    # architecture check being covered, and nothing else would notice.
    test "a dependency between components moves it", %{scope: scope} do
      source = CodeMySpec.ComponentsFixtures.component_fixture(scope)
      target = CodeMySpec.ComponentsFixtures.component_fixture(scope)

      # After the components exist, not before. Taking the baseline from `setup`
      # would let the two `component_fixture` calls move the hash and the test
      # would pass without the edge ever being hashed — which is what the first
      # version of it did.
      before = current_fingerprint(scope)

      {:ok, _} =
        CodeMySpec.Components.create_dependency(scope, %{
          source_component_id: source.id,
          target_component_id: target.id
        })

      refute current_fingerprint(scope) == before,
             "an edge decides whether a component is an orphan, which decides " <>
               "whether the architecture is designed"
    end

    # The input that is not data. Everything else in the fingerprint is what the
    # graph is computed *from*; nothing described how it is computed, so the same
    # inputs under changed code produced the same hash and a payload written by
    # the old code read as current.
    #
    # Observed: scoping the file load to one working copy took this project's
    # graph from 1,357 nodes to 2,783, and `fetch/2` still hit. A reader was
    # served the pre-fix graph, and only the projection comparison noticed.
    test "the code version is part of it", %{scope: scope, before: before} do
      assert before =~ ~r/^[0-9a-f]{64}$/

      {:ok, vsn} = :application.get_key(:code_my_spec, :vsn)

      assert is_list(vsn),
             "the fingerprint mixes in the app version, so a release invalidates " <>
               "every snapshot rather than serving one computed by older code"

      # Same inputs, same version — still stable. The version must not make the
      # fingerprint move on its own, or the cache never hits at all.
      assert current_fingerprint(scope) == before
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
