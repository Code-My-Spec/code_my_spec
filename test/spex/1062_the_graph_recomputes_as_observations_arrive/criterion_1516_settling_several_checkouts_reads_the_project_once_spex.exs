defmodule CodeMySpecSpex.Story1062.Criterion3620Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3620 — Settling several checkouts reads the project once.

  Rule: an observation costs work in proportion to what it changed, not to the
  size of the project.

  ## The last cost that multiplies

  Everything else a pass does is now narrowed. What is left is paid before the
  narrowing starts: `RequirementGraph.recompute/1` opens with
  `Preloader.load(scope)`, and `GraphWatcher.recompute_vantage/2` calls it once
  per vantage. So a drain settling three checkouts reads the project three
  times, and its own comment concedes the shape — "the preload is the half that
  runs whether or not the pass finds anything to do".

  Measured on dev, 2026-09-21, by vantage count on one project:

      vantages: 1    32 queries
      vantages: 2    64 queries
      vantages: 3   133-163 queries

  Linear in checkouts, on a project that has not changed between them. Most of
  what it re-reads is the same rows: the components with their dependencies and
  children, the rules, the questions, the issue stamps. Only the files are
  per-checkout, which is the whole reason a vantage exists.

  ## What it observes, and why the comparison is shaped like this

  `queries`, off the drain's own cost report.

  Not "fewer than last time", which would measure the machine. Two drains in
  one scenario, both against a settled graph with nothing stale, differing only
  in how many checkouts they name — so the difference between them is the
  multiplier and nothing else. A pass that found work to do would confound it,
  which is why both arms settle first.

  `< 2x` rather than `== 1x` deliberately. Files, stories and the delegated
  stamps are genuinely per-checkout and must be read again; a second vantage is
  not free and this criterion does not claim it is. It claims the project is not
  re-read wholesale to answer for a checkout that shares it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @moduletag timeout: 60_000

  spex "A second checkout costs its own files, not the whole project again", criterion: 1516 do
    scenario "one drain settles two checkouts and another settles one" do
      given_ :synced_context_component

      given_ "one checkout, stored and settled", context do
        first = context.scope.active_working_copy_id

        assert read_settled_graph(context, first)["nodes"] != [],
               "the first checkout stores nothing, so a pass for it is not a pass"

        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :first_id, first)}
      end

      given_ "a drain measured before a second checkout exists", context do
        scope = %{context.scope | active_working_copy_id: context.first_id}

        # A project-wide writer, and it has to be. `replace_problems/4`
        # announces `:this_checkout`, so the drain settles that copy and `nil`
        # and never the other one — which is criterion 3518 working, and makes
        # it useless for counting checkouts. An issue reaches every checkout
        # (criterion 3505), so the drain covers every live vantage.
        :ok = file_an_issue(scope, "before the second checkout")
        :ok = Fixtures.settle_graph(scope)

        {:ok, Map.put(context, :fewer, drain_of(context, context.first_id))}
      end

      when_ "a second checkout joins and the next drain settles it too", context do
        second_root = CodeMySpec.TempFile.owned_dir("test")
        {reply, _socket} = join_working_copy_socket(context, second_root, "the second checkout")
        second_id = reply["harness_id"] || reply[:working_copy_id]

        refute second_id == context.first_id,
               "two checkouts must be two copies; the server issued one id for both"

        # Settled to current *before* the measurement, so the extra vantage is
        # not being charged for its first computation. Both drains then find
        # nothing stale and differ only in how many checkouts they cover.
        assert read_settled_graph(context, second_id)["nodes"] != [],
               "the second checkout stores nothing, so there is no second vantage to settle"

        :ok = Fixtures.settle_graph(%{context.scope | active_working_copy_id: second_id})

        scope = %{context.scope | active_working_copy_id: context.first_id}
        :ok = file_an_issue(scope, "after the second checkout")
        :ok = Fixtures.settle_graph(scope)

        {:ok,
         context
         |> Map.put(:second_id, second_id)
         |> Map.put(:more, drain_of(context, context.first_id))}
      end

      then_ "both drains are measured, and the second covered more checkouts", context do
        assert is_integer(queries(context.fewer)) and is_integer(queries(context.more)),
               """
               One of the two drains did not report what it cost, so there is
               nothing to compare.

               fewer: #{inspect(context.fewer)}
               more:  #{inspect(context.more)}
               """

        assert vantages(context.more) > vantages(context.fewer),
               """
               The second drain did not cover more checkouts than the first, so
               the comparison below is between two drains of the same shape and
               says nothing about the multiplier.

               `Projection.live_vantages/2` decides this, and a vantage enters it
               only once something has computed for it.

               fewer: #{vantages(context.fewer)} vantage(s), #{queries(context.fewer)} queries
               more:  #{vantages(context.more)} vantage(s), #{queries(context.more)} queries
               """

        {:ok, context}
      end

      then_ "and it read the project once, not once per checkout", context do
        preloads = preloads(context.more)

        # At most once, not exactly once. The event path settles an issue by
        # sweeping the rows it already holds and reads the project zero
        # times; the claim here is that the shared half is not re-read per
        # checkout, and zero reads satisfies it more thoroughly than one.
        assert is_integer(preloads) and preloads <= 1,
               """
               A drain covering #{vantages(context.more)} checkouts read the
               project's vantage-invariant half #{inspect(preloads)} time(s).

               Every checkout of a project shares those rows exactly — the same
               components, the same dependencies, the same children, the same
               rules and questions and issue stamps. What differs per vantage is
               the files, and the files are the reason a vantage exists.

               `RequirementGraph.recompute/1` opens with `Preloader.load(scope)`
               and `GraphWatcher.recompute_vantage/2` calls it once per vantage,
               so the shared half is paid once per checkout. Measured on dev:
               32 queries at one vantage, 64 at two, 133-163 at three, on a
               project that had not changed between them.

               A ratio was tried here first and could not tell the two apart:
               marginal 50.0 queries against an average of 50.5, passing by half
               a query, because only about seven of fifty queries per vantage are
               the shared half. Counting the thing itself is exact.

               fewer: #{vantages(context.fewer)} vantage(s), #{preloads(context.fewer)} preload(s)
               more:  #{vantages(context.more)} vantage(s), #{preloads} preload(s)
               """

        {:ok, context}
      end
    end
  end

  # The last pass drain for this project, read at a vantage that has one. Only a
  # `pass` — the event path reports its own cost separately and comparing the two
  # is criterion 3516's question, not this one's.
  defp drain_of(context, vantage), do: read_graph(context, vantage)["last_drain"]

  # Project-wide by construction: `Issues` names no checkout, so every live
  # vantage is settled and the drain's `vantages` is the count this criterion
  # is about.
  defp file_an_issue(scope, title) do
    frame = %Frame{assigns: %{current_scope: scope}}

    {:reply, filed, _frame} =
      CreateIssue.execute(
        %{
          title: title,
          description: "so the drain has something to be about",
          severity: "medium"
        },
        frame
      )

    refute filed.isError, inspect(filed)
    :ok
  end

  defp queries(%{"queries" => queries}), do: queries
  defp queries(_other), do: nil

  defp vantages(%{"vantages" => vantages}), do: vantages
  defp vantages(_other), do: nil

  defp preloads(%{"project_preloads" => count}), do: count
  defp preloads(_other), do: nil
end
