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

  alias CodeMySpec.ComponentsFixtures
  alias CodeMySpec.Requirements.Shadow
  alias CodeMySpec.Requirements.ShadowProjector

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Application.put_env(:code_my_spec, :graph_shadow_projection, true)

    on_exit(fn ->
      Application.delete_env(:code_my_spec, :graph_shadow_projection)
      Application.delete_env(:code_my_spec, :graph_event_is_source)
    end)

    :ok
  end

  describe "with the event path owning the tables readers read" do
    test "both writers write, and the projections agree on nodes and topology", ctx do
      scope = ctx.scope

      ComponentsFixtures.component_fixture(scope)
      create_story(scope, title: "A story", description: "with requirements and edges")

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
  end
end
