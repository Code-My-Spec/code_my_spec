defmodule CodeMySpec.Requirements.WhatADrainCostsTest do
  @moduledoc """
  The cost claim, asserted from the measurement rather than described.

  Story 1020's cost rule — "An observation costs work in proportion to what it
  changed, not to the size of the project" — had four scenarios and all of them
  asserted *which entities* were recomputed. None asserted what the work cost,
  so the rule was true by inspection and nothing would have noticed it becoming
  false. `DrainCost` has emitted the numbers since it was written and its own
  moduledoc names this test; until now nothing in `test/` read the event.

  That gap is the one that matters for this feature. Applying an observation is
  only worth the machinery if it is cheaper than recomputing, and "cheaper" is
  a number, not an argument.

  ## Queries, not milliseconds

  `DrainCost` measures duration too and this asserts on none of it, deliberately.
  Watched on a loaded dev box: the same seventeen-query drain ran at 4ms and at
  18ms per query within the same minute, so identical work read as a 4x
  regression depending on what else the machine was doing. Query and row counts
  did not move at all — seventeen for one checkout, thirty-two for two, fifty-one
  when three profiles load, whatever the load average.

  So duration measures the box and counts measure the work. An assertion on
  duration is a flake that fires hardest exactly when the machine is busiest,
  which is when a real regression is least likely to be what changed.
  """
  use CodeMySpecSpex.Case, async: true
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  alias CodeMySpec.Requirements.IncrementalGraph

  @event [:code_my_spec, :requirements, :drain]

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    handler = "drain-cost-#{inspect(self())}"
    test = self()
    project_id = ctx.scope.active_project_id

    # This project's drains only: telemetry is node-wide, and every test
    # running alongside drains too.
    :telemetry.attach(
      handler,
      @event,
      fn
        _e, measurements, %{project_id: ^project_id} = meta, _ ->
          send(test, {:drain, measurements, meta})

        _e, _measurements, _meta, _ ->
          :ok
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, _pid} = IncrementalGraph.ensure_projecting(ctx.scope)
    :ok
  end

  # Everything this process has been told about since the last call, so a test
  # reads the drains its own action caused rather than whatever was last.
  defp drains do
    receive do
      {:drain, measurements, meta} -> [{measurements, meta} | drains()]
    after
      0 -> []
    end
  end

  # A drain that raised before its work finished carries only the metadata the
  # call site started with, so these two are absent rather than zero. Reading
  # them as zero would quietly count a failed drain as a cheap one.
  defp handled(meta), do: Map.get(meta, :handled, 0)
  defp recomputed(meta), do: Map.get(meta, :recomputed, 0)

  defp settle(scope) do
    :ok = IncrementalGraph.settle(scope.active_project_id)
    drains()
  end

  # The drains caused by `fun` and nothing else — the mailbox is emptied first,
  # so an earlier action's drain cannot be read as this one's.
  defp settle_after(scope, fun) do
    drains()
    fun.()
    settle(scope)
  end

  describe "what an observation costs" do
    test "applying an observation costs less than re-deriving it", ctx do
      scope = ctx.scope

      # Both halves come from this projector, deliberately. An earlier draft
      # compared against a `:pass` drain — which `GraphWatcher` emits, not this
      # process — so `settle/1` could never produce one and the test only passed
      # when a stray pass from elsewhere happened to reach the handler. It was
      # green by accident.
      #
      # The honest comparison is inside one component: a kind with a handler
      # against a kind without. `story_created` falls back because handlers
      # settle rows and cannot create them, so its drain is a recompute wearing
      # the event label — which is exactly what applying is supposed to beat.
      create_story(scope, title: "Subject", description: "creation falls back")
      settle(scope)

      fell_back =
        settle_after(scope, fn ->
          create_story(scope, title: "Another", description: "also falls back")
        end)
        |> Enum.filter(fn {_c, m} -> recomputed(m) > 0 end)

      assert fell_back != [], "expected story creation to fall back to a recompute"
      {fallback_cost, _} = Enum.max_by(fell_back, fn {c, _m} -> c.queries end)

      applied =
        settle_after(scope, fn ->
          {:ok, issue} =
            CodeMySpec.Issues.create_issue(scope, %{
              title: "moves one verdict",
              description: "and the graph knows how to apply it",
              severity: :high
            })

          {:ok, _} = CodeMySpec.Issues.accept_issue(scope, issue)
        end)
        |> Enum.filter(fn {_c, m} -> handled(m) > 0 and recomputed(m) == 0 end)

      assert applied != [], "accepting an issue should have been applied, not recomputed"
      {applied_cost, _} = Enum.max_by(applied, fn {c, _m} -> c.queries end)

      assert applied_cost.queries < fallback_cost.queries,
             """
             Applying cost #{applied_cost.queries} queries and falling back cost \
             #{fallback_cost.queries}. Applying an observation has to be cheaper \
             than re-deriving what it touched, or the handler machinery buys \
             nothing over the pass it replaced.
             """
    end

    test "a drain that moves nothing writes nothing", ctx do
      scope = ctx.scope
      create_story(scope, title: "Settled", description: "and then left alone")
      settle(scope)

      {:ok, issue} =
        CodeMySpec.Issues.create_issue(scope, %{
          title: "applied once",
          description: "and then applied again with the same answer",
          severity: :high
        })

      {:ok, _} = CodeMySpec.Issues.accept_issue(scope, issue)
      settle(scope)

      # The same event again. Every verdict it moves is already where it belongs,
      # so the sweep's `IS DISTINCT FROM` should match no row.
      {:ok, _} = CodeMySpec.Issues.update_issue(scope, issue, %{description: "reworded"})

      again = settle(scope) |> Enum.filter(&(elem(&1, 1).kind == :event))
      settled = Enum.filter(again, fn {_cost, meta} -> recomputed(meta) == 0 end)

      # Or the loop below runs zero times and the test asserts nothing.
      assert settled != [],
             "expected a drain that settled without falling back, got: #{inspect(again)}"

      for {cost, _meta} <- settled do
        assert cost.rows_written == 0,
               """
               A drain that changed no verdict wrote #{cost.rows_written} row(s). \
               An unchanged answer must not be rewritten to say the same thing — \
               that is the write amplification the sweep's IS DISTINCT FROM exists \
               to prevent.
               """
      end
    end

    test "an issue update does not query once per promoted story", ctx do
      scope = ctx.scope
      story = create_story(scope, title: "First promoted", description: "query baseline")

      CodeMySpec.Repo.get!(CodeMySpec.Stories.Story, story.id)
      |> Ecto.Changeset.change(promoted_version: "0.1.1")
      |> CodeMySpec.Repo.update!()

      settle(scope)

      {:ok, issue} =
        CodeMySpec.Issues.create_issue(scope, %{
          title: "Measure issue drain",
          description: "first observation",
          severity: :high
        })

      {:ok, issue} = CodeMySpec.Issues.accept_issue(scope, issue)
      settle(scope)

      baseline =
        settle_after(scope, fn ->
          {:ok, _} = CodeMySpec.Issues.update_issue(scope, issue, %{description: "baseline"})
        end)
        |> Enum.filter(fn {_cost, meta} ->
          meta.kind == :event and handled(meta) > 0 and recomputed(meta) == 0
        end)

      assert baseline != []
      {baseline_cost, _} = Enum.max_by(baseline, fn {cost, _meta} -> cost.queries end)

      for n <- 1..12 do
        story = create_story(scope, title: "Promoted #{n}", description: "query scaling")

        CodeMySpec.Repo.get!(CodeMySpec.Stories.Story, story.id)
        |> Ecto.Changeset.change(promoted_version: "0.1.1")
        |> CodeMySpec.Repo.update!()
      end

      settle(scope)

      enlarged =
        settle_after(scope, fn ->
          {:ok, _} = CodeMySpec.Issues.update_issue(scope, issue, %{description: "enlarged"})
        end)
        |> Enum.filter(fn {_cost, meta} ->
          meta.kind == :event and handled(meta) > 0 and recomputed(meta) == 0
        end)

      assert enlarged != []
      {enlarged_cost, _} = Enum.max_by(enlarged, fn {cost, _meta} -> cost.queries end)

      assert enlarged_cost.queries - baseline_cost.queries < 8,
             "issue drain grew from #{baseline_cost.queries} to #{enlarged_cost.queries} queries for twelve stamped stories"
    end

    test "a drain reports how many checkouts it settled", ctx do
      scope = ctx.scope
      story = create_story(scope, title: "Counted", description: "across checkouts")
      settle(scope)

      {:ok, issue} =
        CodeMySpec.Issues.create_issue(scope, %{
          title: "project-wide",
          description: "read from every checkout",
          severity: :high,
          story_id: story.id
        })

      {:ok, _} = CodeMySpec.Issues.accept_issue(scope, issue)

      applied = settle(scope) |> Enum.filter(&(elem(&1, 1).kind == :event))
      assert applied != []

      for {_cost, meta} <- applied do
        assert is_integer(meta.vantages) and meta.vantages > 0,
               "a drain has to say how many checkouts it settled, or the cost of " <>
                 "routing cannot be read at all"
      end
    end
  end
end
