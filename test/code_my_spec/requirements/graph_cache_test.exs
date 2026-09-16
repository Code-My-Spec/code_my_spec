defmodule CodeMySpec.Requirements.GraphCacheTest do
  use ExUnit.Case, async: true

  import CodeMySpec.DevicesFixtures
  import Ecto.Query, only: [from: 2]
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
  alias CodeMySpec.Requirements.{GraphCache, GraphFingerprint, Preloader, RequirementGraph}
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies
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

    # This used to assert that the read rebuilt the graph. It no longer does,
    # and that is the change: a reader repairing the rows is what made a writer
    # that announces nothing indistinguishable from one that works.
    #
    # The worry the old test carried is still real — an empty projection behind
    # a matching fingerprint is a failed write, not a project with no
    # requirements — so it moves from being silently fixed to being reported.
    test "a read serves the rows as they are, and the diagnostic names what is missing" do
      scope = setup_project()

      # A story, because the diagnostic reports per-entity staleness and
      # `stale_entities/2` drops project-level nodes — they are recomputed
      # every pass and carry no fingerprint to disagree with. Without an entity
      # this asserts against a blind spot rather than against the mechanism.
      _story = CodeMySpec.StoriesFixtures.story_fixture(scope, %{ready_for_dev: true})

      RequirementGraph.recompute(scope)
      {nodes, _edges} = RequirementGraph.cached_graph(scope) |> elem(0)
      assert nodes != []

      Repo.delete_all(CodeMySpec.Requirements.Node)

      {served, _edges} =
        RequirementGraph.cached_graph_with_actionable(scope, settle: false)
        |> elem(0)

      assert served == [],
             """
             A read rebuilt the graph behind the caller's back.

             That is the behaviour this whole split removed. A read that
             repairs is a read that hides a writer which said nothing.
             """

      Application.put_env(:code_my_spec, :graph_stale_read_log, true)
      on_exit(fn -> Application.delete_env(:code_my_spec, :graph_stale_read_log) end)

      RequirementGraph.recompute(scope)
      Repo.delete_all(CodeMySpec.Requirements.Node)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          RequirementGraph.cached_graph_with_actionable(scope, settle: false)
        end)

      assert log =~ "STALE READ",
             """
             Every row was deleted and a read said nothing about it.

             `stale_entities/2` counts an entity the context has and the rows
             do not as stale — that is what makes a failed write visible now
             that it is no longer invisibly repaired.

             #{log}
             """
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

    # `code_on_running_copy` asks `Promotion.running_copy_check/2`, which reads
    # the project's working copies: whether this checkout's work is on main, and
    # whether the running one is answering. No other input touches that table,
    # and nothing in the tree changes when it moves — the harness measures it on
    # the machine and reports it after a merge or a restart.
    #
    # The same shape as the deploy gap above, on a node shipped long after this
    # block was written, and it failed in the direction that keeps an agent
    # stuck rather than the one that lets work through: the cached graph went on
    # serving a refusal the agent had already cleared.
    #
    # What clears it has since moved, and this test moved with it. It used to
    # drive `record_git_state` from `ahead: 3` to `ahead: 0` and assert the
    # fingerprint noticed. It no longer can, because `ahead` no longer decides
    # anything: `Promotion.promoted/2` answers from the story's own
    # `promoted_version` stamp, and `not_yet_promoted/1` returns `false`
    # whatever the counts say — `and_serving/2` short-circuits on it, so
    # `serving/2` is not even consulted. The counts reach only the reason text,
    # under a comment in `promotion.ex` saying so: "Informational only now —
    # none of this gates."
    #
    # Asserting them kept `commits_ahead_of_main`, `commits_behind_main` and
    # `tree_dirty` in `asking_copy_inputs/2`, which `Freshness.story/2` hashes
    # into *every* story's fingerprint. All three move whenever anybody edits a
    # file in any checkout, so one keystroke reconsidered every story in the
    # project for a verdict that could not have changed. Measured on dev over an
    # hour: `working_copies` took 22 distinct digests while every other shared
    # input took 2 to 6.
    #
    # `Stories.mark_ready_stories_promoted/2` is explicit that this is the
    # intent — the stamp exists to stop "a checkout dirtied afterward for
    # unrelated work from un-answering a question that already had its answer".
    # The fingerprint was doing precisely that un-answering.
    #
    # So the claim is the same and the transition is the real one: the thing
    # that clears the refusal has to move the fingerprint.
    test "a story being promoted moves it", %{scope: scope} do
      # `specs_ready`, not `ready_for_dev` — the stamp is taken at promotion and
      # only covers stories whose specs have landed.
      {:ok, story} =
        CodeMySpec.Stories.create_story(scope, %{
          title: "ready to go",
          description: "released for development",
          ready_for_dev: true
        })

      {:ok, _} = CodeMySpec.Stories.update_story(scope, story, %{specs_ready: true})

      unpromoted = current_fingerprint(scope)

      {:ok, [_ | _]} = CodeMySpec.Stories.mark_ready_stories_promoted(scope, "v1.2.3")

      refute current_fingerprint(scope) == unpromoted,
             "the promotion landed and stamped the story; a fingerprint blind to " <>
               "that keeps serving the refusal the agent has already cleared"
    end

    # The test that used to sit here drove `record_git_state/2` from clean to
    # dirty and asserted the fingerprint did not move — a guard against those
    # fields being put back into `asking_copy_inputs/2`.
    #
    # It is gone because the columns are. `commits_ahead_of_main`,
    # `commits_behind_main` and `tree_dirty` have been dropped from
    # `working_copies` entirely: a mirror of git that nothing decided on, which
    # `promote` answers live by running git, and which cost a whole-project
    # recompute per keystroke while it sat in the fingerprint. There is no
    # longer a value to set, so there is no longer a way to write this.

    # The other half of the same node. That the code is on the running copy says
    # nothing about whether anything is serving it, and QA needs both — the two
    # came apart within a day of the gate shipping.
    #
    # On the main copy, because "the running application" is by definition the
    # one `WorkingCopies.main/1` answers with — a checkout nobody designated is
    # not serving anything and the gate never looks at it.
    test "the running application going down moves it", %{scope: scope} do
      copy = a_checkout(scope)
      {:ok, copy} = WorkingCopies.designate_main(scope, copy.id)

      {:ok, _} = WorkingCopies.record_preview_status(copy, "serving")
      up = current_fingerprint(scope)

      {:ok, _} = WorkingCopies.record_preview_status(copy, "down")

      refute current_fingerprint(scope) == up,
             "the application stopped answering; a fingerprint blind to that " <>
               "sends QA to test a connection refused"
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

  defp a_checkout(scope) do
    {:ok, copy} =
      WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    copy
  end

  # A cache hit and a cache miss must describe the same graph.
  #
  # Found by QA on story 1062, reproduced three times on the graph page: 2009
  # nodes on a fresh compute, 1844 from the cache, stable, under one
  # `computed_at`, back to 2009 on the next recompute (7a6b92e3). Criterion 3358
  # is the story's record of it.
  #
  # A miss answers with what it computed. A hit answers with `Projection.load/2`
  # — the projection tables read back — so the two agree only if the round trip
  # is lossless. It is not obliged to be: `load/2` rehydrates each row against
  # the preloaded context and drops whatever it cannot rebuild.
  describe "a cache hit and the computation it came from" do
    setup do
      %{scope: setup_project()}
    end

    test "describe the same graph", %{scope: scope} do
      viewing = %{scope | active_working_copy_id: nil}

      # The computation is the write path now. This used to be the first read,
      # back when a read computed its own answer on a miss — which is exactly
      # the coupling that made a silent writer invisible.
      {{computed_nodes, _edges}, _actionable, _at} = RequirementGraph.recompute(viewing)

      {{cached_nodes, _edges, _actionable}, cached} =
        RequirementGraph.cached_graph_with_actionable_metrics(viewing)

      assert cached.served_from == "cache"

      assert length(cached_nodes) == length(computed_nodes),
             """
             The cached read and the computed read describe different graphs.

             computed: #{length(computed_nodes)} nodes
             cached:   #{length(cached_nodes)} nodes

             Both readings are internally coherent, which is why this survived
             until a page showed them next to each other under one timestamp.
             Whatever a computation stored has to be what the read serving it
             back returns, or `computed_at` is a label on two different answers.
             """
    end

    # The fixture above round-trips losslessly, so it cannot produce the
    # shortfall QA measured. This produces it directly: delete some of the
    # projected rows behind the cache's back, leaving the cache row's own
    # `node_count` claiming more than the projection can return.
    #
    # That is the shape of the real failure without needing whatever made
    # rehydration fail on a 2009-node project — the read comes back short, and
    # the only question is whether a short read is served or refused.
    test "a read that comes back short is served as it is, not repaired", %{scope: scope} do
      viewing = %{scope | active_working_copy_id: nil}

      {{computed_nodes, _edges}, _actionable, _at} = RequirementGraph.recompute(viewing)

      assert length(computed_nodes) > 1, "need more than one node to remove one"

      victim =
        Repo.one(
          from r in "requirements",
            where: r.project_id == type(^scope.active_project_id, :binary_id),
            limit: 1,
            select: r.id
        )

      {1, _} = Repo.delete_all(from r in "requirements", where: r.id == ^victim)

      {{served_nodes, _, _}, served} =
        RequirementGraph.cached_graph_with_actionable_metrics(viewing)

      assert length(served_nodes) == length(computed_nodes) - 1,
             """
             A read repaired rows that had gone missing.

             It used to, and that is what changed: `served_graph/3` compared
             the rows against the `node_count` the publish recorded and
             recomputed on a shortfall. A read that repairs is a read that
             hides a writer which announced nothing, so the guard went with the
             rest of the read-side recompute.

             What QA measured on story 1062 (2009 -> 1844 -> 2009) is still a
             real failure. It is now answered by the write path rather than by
             whoever happens to look: the next pass rewrites every row it
             visits, and `graph_stale_read_log` reports the shortfall in the
             meantime for any entity that loses all of its rows.

             served:   #{length(served_nodes)} nodes
             computed: #{length(computed_nodes)} nodes
             """

      {{repaired_nodes, _edges}, _actionable, _at} = RequirementGraph.recompute(viewing)

      assert length(repaired_nodes) == length(computed_nodes),
             "the next pass should restore every node the short read was missing"
    end
  end

  defp setup_project do
    tmp_dir = CodeMySpec.TempFile.owned_dir("graph_cache")
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
