defmodule CodeMySpec.Requirements.TheFlagIsASwitchNotATrapTest do
  @moduledoc """
  With `graph_event_is_source` on, both writers write and the two projections
  still agree.

  `inverted?/0` documents the flag as the change that cannot be half-made: if
  the event path is wrong about one requirement, every reader is wrong about
  it. What its docstring also said, until today, is that flipping it was not
  safe — the two edge tables were different shapes, so the event path's writer
  would have raised on eight columns `requirement_edges` does not have, and the
  pass would have written `shadow_requirement_edges`, which no reader reads.
  Nodes would have come from the event path and been correct while every
  reader's topology froze at the moment of the flip: a graph that looks right
  and stops moving on shape.

  Both tables are four columns now — two row ids, a key and a timestamp — so
  this asserts what that bought. It is the rehearsal, not the swap: the flag
  goes back off at the end of the test, and turning it on for real is a
  decision about evidence rather than about mechanism.

  ## Two assertions, because there are two ways to be wrong

  `Shadow.diff/1` compares row set to row set and never asks whether either is
  *readable* — `Projection.rehydrate/2` drops a row whose entity it cannot place
  or whose definition it cannot find, and a dropped row is an agent told it has
  less work than it has. So the diff is one assertion and the reader is the
  other: `verify_round_trip/4` compares what a fresh computation produced
  against what `Projection.load/2` returns, which inverted is the event path's
  rows as every reader sees them.

  ## The flip is a transition, and the check says so

  Both warn on the *first* round and neither warns on the second. At the instant
  of the flip each writer publishes against tables the other has not filled yet,
  so a graph computed from scratch differs from what the reader can see — which
  is true, and worth being told. It converges as soon as both sides have written
  once.

  That is measured here rather than asserted away, because it is the live-flip
  question in miniature: flipping on a running system means ordering the two
  writers, not hoping. A check that fires during a transition is not a check
  that lies, which is why it is no longer skipped when inverted.
  """
  use CodeMySpecSpex.Case

  import ExUnit.CaptureLog
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  import Ecto.Query

  alias CodeMySpec.ComponentsFixtures
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.Shadow
  alias CodeMySpec.Requirements.ShadowProjector

  setup :register_log_in_setup_account
  setup :setup_active_project

  # Restored to what the config said, never deleted: the test config sets both
  # flags, and deleting the key would strip that for every test after this one.
  # Each test here starts on the pass and flips inside itself, so it forces the
  # starting side rather than assuming it.
  setup do
    projection = Application.get_env(:code_my_spec, :graph_shadow_projection, false)
    source = Application.get_env(:code_my_spec, :graph_event_is_source, false)
    Application.put_env(:code_my_spec, :graph_shadow_projection, true)
    Application.put_env(:code_my_spec, :graph_event_is_source, false)

    on_exit(fn ->
      Application.put_env(:code_my_spec, :graph_shadow_projection, projection)
      Application.put_env(:code_my_spec, :graph_event_is_source, source)
    end)

    :ok
  end

  # The table the pass is about to inherit, emptied before it inherits it.
  #
  # Called before the flip, so `event_target/0` is still the shadow — which is
  # the pass's table the moment the flag moves. The event path's new table is
  # deliberately left alone: it is event-driven, so clearing it leaves it
  # nothing to rebuild from and it stays empty.
  #
  # This is the transition the moduledoc describes, made a step instead of an
  # assumption. The claim above — "neither has rows in the other's table to be
  # confused by" — was never true here: `graph_shadow_projection` is on from
  # `setup`, so by now each writer has filled what the other is about to own.
  #
  # A whole-graph pass hid that by rewriting every row it read, whichever table
  # it read from, so both sides converged on the second round from any starting
  # state. A pass that recomputes only what moved cannot: it reads the rows it
  # inherited, finds them current — they are — and writes nothing. Handing it an
  # empty table is what makes "both sides have written once" true rather than
  # hoped for, and it is what flipping for real would have to do.
  #
  # The cache row goes with it, or the first publish answers `:unchanged`
  # against a fingerprint computed before the flip and persists nothing.
  #
  # Every id stays inside SQL as a subquery: the edge tables are named rather
  # than schema-backed, so Ecto has no field definition to cast a uuid against
  # and a bare list reaches Postgrex as text — "expected a binary of 16 bytes".
  defp empty_the_passs_new_table(scope) do
    project_id = scope.active_project_id
    {table, _schema} = Shadow.event_target()
    edges = Shadow.event_edges()

    components =
      from(c in "components", where: c.project_id == type(^project_id, :binary_id), select: c.id)

    stories =
      from(st in "stories", where: st.project_id == type(^project_id, :binary_id), select: st.id)

    ids =
      from(n in table,
        where:
          n.project_id == type(^project_id, :binary_id) or
            n.component_id in subquery(components) or
            n.story_id in subquery(stories),
        select: n.id
      )

    from(e in edges,
      where: e.from_requirement_id in subquery(ids) or e.to_requirement_id in subquery(ids)
    )
    |> Repo.delete_all()

    from(n in table, where: n.id in subquery(ids)) |> Repo.delete_all()

    from(g in "requirement_graphs", where: g.project_id == type(^project_id, :binary_id))
    |> Repo.delete_all()

    :ok
  end

  # This project's writers only — the pass's watcher and the projector.
  # `stop_graph_watchers/0` takes every project's, and these files run
  # concurrently.
  #
  # The projector matters as much as the watcher and is easier to forget: it is
  # already running by here, because `graph_shadow_projection` is on from
  # `setup` and the fixtures above announced. Left alive, it refills the table
  # emptied below between the delete and the flip — 22 rows back in
  # `shadow_requirements`, which then reads to the pass as a projection that is
  # already complete and current, so the pass writes nothing and the transition
  # never happens.
  defp stop_writers(project_id) do
    for key <- [project_id, {project_id, :shadow}],
        {pid, _} <- Registry.lookup(CodeMySpec.Requirements.Registry, key) do
      DynamicSupervisor.terminate_child(CodeMySpec.Requirements.WatcherSupervisor, pid)
    end

    :ok
  end

  describe "with the event path owning the tables readers read" do
    test "both writers write, and the projections agree on nodes and topology", ctx do
      scope = ctx.scope

      ComponentsFixtures.component_fixture(scope)
      create_story(scope, title: "A story", description: "with requirements and edges")

      # The pass's new table emptied, and both writers stopped so nothing
      # refills it behind the flip. `empty_the_passs_new_table/1` says why both are
      # needed — in short, a pass that recomputes only what moved does not
      # rewrite rows it inherited, so the transition has to be arranged rather
      # than swept up on the next round.
      stop_writers(scope.active_project_id)
      empty_the_passs_new_table(scope)

      # On before either writer runs, so neither has rows in the other's table
      # to be confused by. A flip on a live system is the harder case and is a
      # separate question — this one asks whether the mechanism works at all.
      Application.put_env(:code_my_spec, :graph_event_is_source, true)

      # The event path first. Inverted, it owns the tables `Projection.load/2`
      # reads, and the pass's `verify_round_trip/4` reads them the moment it
      # publishes — so recomputing first compares a fresh graph against tables
      # the event path has not filled yet and warns, correctly, about a
      # transition rather than about the mechanism.
      {:ok, _pid} = ShadowProjector.ensure_projecting(scope)
      :ok = ShadowProjector.settle(scope.active_project_id)
      CodeMySpec.Requirements.recompute(scope)

      # Both sides have written once now, so the transition is over and the
      # reader's view has to match a graph computed from scratch.
      settled =
        capture_log(fn ->
          :ok = ShadowProjector.settle(scope.active_project_id)
          CodeMySpec.Requirements.recompute(scope)
        end)

      refute settled =~ "does not round-trip",
             """
             Inverted and settled, what a fresh computation produces is not what
             `Projection.load/2` returns.

             That reader is every consumer of the graph, and it is reading the
             event path's rows now. A difference here that does not resolve is
             the event path holding something the reader cannot serve — which
             `Shadow.diff/1` cannot see, because it compares rows to rows.

             #{settled}
             """

      _ = settled
      report = Shadow.diff(scope)

      assert report.live > 0,
             "neither writer wrote a node, so agreement here means nothing"

      assert report.live_edges > 0,
             "neither writer wrote an edge, so the topology comparison proves nothing"

      assert report.missing == 0 and report.extra == 0 and report.disagree == 0,
             """
             Inverted, the two projections disagree on nodes: #{inspect(report.sample)}

             Both writers ask for their table by role, so neither should notice
             which way round the flag is. One that does is a call site reaching
             for a table by name.
             """

      assert report.edges_missing == 0 and report.edges_extra == 0,
             """
             Inverted, the two projections disagree on topology —
             missing #{report.edges_missing}, extra #{report.edges_extra}
             (live #{report.live_edges}, shadow #{report.shadow_edges}):
             #{inspect(report.edge_sample)}

             This is the failure the flag was unsafe for. An edge writer that
             cannot write the table it has been handed leaves every reader's
             topology frozen at the moment of the flip, and the graph goes on
             looking right.
             """
    end

    # Two things a reader depends on that only the pass provided, asserted the
    # way a reader would notice their absence.
    #
    # Inverted, every read is served from the projector's table — so a read has
    # to settle the *projector* before it answers, and a drain that moved
    # something has to announce it or nothing wakes. Both were hard-wired to
    # `GraphWatcher`: `cached_graph_with_actionable/2` named it outright, and
    # `newly_actionable/2` and `maybe_request_work/2` lived only there. A flip
    # would have left every read current-looking and served from rows nothing
    # had settled, with every agent asleep.
    test "a read settles the projector, and a drain announces", ctx do
      scope = ctx.scope
      ComponentsFixtures.component_fixture(scope)
      story = create_story(scope, title: "A story", description: "whose verdict will move")

      stop_writers(scope.active_project_id)
      empty_the_passs_new_table(scope)
      Application.put_env(:code_my_spec, :graph_event_is_source, true)

      # Both writers once, so the transition is over before the claim is made.
      {:ok, _pid} = ShadowProjector.ensure_projecting(scope)
      :ok = ShadowProjector.settle(scope.active_project_id)
      CodeMySpec.Requirements.recompute(scope)
      :ok = ShadowProjector.settle(scope.active_project_id)

      GraphInputs.subscribe(scope.active_project_id)

      # An observation that moves exactly one verdict on the event side —
      # `story_issues_resolved` on this story goes true → false — and is
      # *not* followed by an explicit projector settle. The read is what has
      # to do that.
      {:ok, issue} =
        CodeMySpec.Issues.create_issue(scope, %{
          title: "breaks the story",
          description: "accepted, so the verdict moves",
          severity: :high,
          story_id: story.id
        })

      {:ok, _} = CodeMySpec.Issues.accept_issue(scope, issue)

      {nodes, _at} = CodeMySpec.Requirements.cached_all(scope)

      verdict =
        Enum.find(
          nodes,
          &(&1.entity_type == "story" and &1.entity_id == story.id and
              &1.name == "story_issues_resolved")
        )

      assert verdict,
             "the read served no `story_issues_resolved` for the story, so nothing below is about a verdict"

      refute verdict.satisfied,
             """
             Inverted, a read was served `story_issues_resolved: true` after an
             issue was accepted against the story.

             The read is served from the projector's table, so it has to settle
             the projector before it answers. It settled the pass — which now
             writes the shadow — and was served rows nothing had touched since
             the issue landed. `settle_owner/1` is what routes it.
             """

      assert_receive {:graph_updated, _project_id}, 2_000, """
      The drain that moved the verdict announced nothing.

      `GraphWatcher` broadcasts `{:graph_updated, project_id}` after a
      pass that consumed something; the projector did not, so inverted
      nobody listening on the project's topic — and nobody being
      considered for a wake — hears about a graph that moved.
      """
    end
  end
end
