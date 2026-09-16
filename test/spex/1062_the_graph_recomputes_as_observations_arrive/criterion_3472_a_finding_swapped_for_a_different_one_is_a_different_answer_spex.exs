defmodule CodeMySpecSpex.Story1062.Criterion3472Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3472 — A finding swapped for a different one is a different answer.

  Rule: a requirement's freshness is decided by the sources it was computed
  from, not by the project's.

  ## The case a count cannot see

  `Freshness.component/2` used to hash `%{source => count}` — which is what the
  verdict reports, and not what the fingerprint needs. Correct one credo
  violation and introduce another in the same module and it is 1 both times, so
  `recompute_stale/3` skips the component entirely: its rows are kept, its
  `checked_at` stays where it was, and the graph goes on claiming an answer
  computed from problems that are no longer there.

  It is now a digest of `{file_path, line, rule, message}` per source, so a swap
  at equal count moves it.

  ## Why the claim is freshness rather than the verdict

  `problem_verdict/5` reports a count and nothing else, so both arrangements
  below produce the identical sentence — "1 test failure(s)". That is not a
  weakness in the criterion, it is the whole difficulty: the two states are
  indistinguishable from the answer, and the only thing that separates a graph
  that noticed from one that did not is whether the row was recomputed.

  So this asserts `checked_at`, which is what the rule above is about — the row
  must record that its sources moved. A row that says it was computed from
  inputs it was not is the defect, whatever the sentence beside it says.

  ## The swap has to be a replacement, not an addition

  `record_problem/3` appends, and an appended problem takes the count from 1 to
  2 — which a count-keyed fingerprint sees perfectly well. Arranging the case
  that defeats it needs the analyzer's own delete-then-insert path, which is
  why `Fixtures.replace_problems/4` exists.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  # `exunit`, because that is the source a requirement actually reads.
  # `tests_passing` routes to `problem_verdict/5` with it
  # (`RequirementCalculator` line 150); `:no_problems` is a defined check type
  # that no template currently instantiates, so a credo finding moves the
  # fingerprint and no verdict — which would make the count assertion below
  # compare two `nil`s and pass for the wrong reason. It did, on the first run.
  @source "exunit"

  spex "A requirement records that its problems moved" do
    scenario "one finding is corrected and another appears in the same module" do
      given_ :context_with_infrastructure_sibling

      # `tests_passing` only consults exunit problems once a test file exists —
      # without one it short-circuits on "No test file exists yet" and never
      # reaches `problem_verdict/5`, which is what the first three runs of this
      # measured. Written and scanned, because a file the application has not
      # been told about is not a file as far as any requirement is concerned.
      given_ "a test file for the ordinary component", context do
        :ok =
          Fixtures.write_env_file(
            context.environment,
            "test/reservations_test.exs",
            "defmodule ReservationsTest do\n  use ExUnit.Case\nend\n"
          )

        :ok = Fixtures.scan_working_copy(context.scope)

        {:ok, context}
      end

      given_ "a test failure recorded against the ordinary component", context do
        :ok =
          Fixtures.replace_problems(context.scope, context.ordinary.id, @source, [
            %{message: "assertion failed", file_path: "test/reservations_test.exs", line: 61}
          ])

        # Read twice before backdating, and the second one is not redundant.
        # `GraphWatcher.settle/1` answers `:ok` when it has no timer set, which
        # it cannot distinguish from "the announcement has not been delivered
        # yet" — the fail-open barrier issue `b789ed99` documents. So the first
        # read can return before the pass `replace_problems/4` announced has
        # run, and that pass then lands during the baseline read and stamps
        # every row with the current time. Measured: the baseline came back
        # carrying `now` instead of the backdated hour, and both readings then
        # agreed for a reason that had nothing to do with the swap.
        _warm = read_settled_graph(context)
        _settled = read_settled_graph(context)

        # Stamped, not slept. `checked_at` is second-resolution, so two readings
        # inside one second are indistinguishable and a recompute that happened
        # reads as one that did not. The baseline is taken after the backdating
        # for the same reason criterion 3424 takes it there.
        :ok = Fixtures.backdate_requirement_freshness(context.scope)

        before = read_settled_graph(context)

        cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -60, :second)

        assert Enum.all?(freshness(before, context.ordinary.id), fn {_name, at} ->
                 NaiveDateTime.compare(NaiveDateTime.from_iso8601!(at), cutoff) == :lt
               end),
               """
               The baseline is not backdated, so a pass ran while it was being
               taken and every row carries the current time. Any comparison
               against it is between two post-recompute readings and cannot say
               anything about the swap.

               baseline: #{inspect(freshness(before, context.ordinary.id))}
               """

        {:ok, Map.put(context, :before, before)}
      end

      when_ "the analyzer reports a different finding, and only one again", context do
        :ok =
          Fixtures.replace_problems(context.scope, context.ordinary.id, @source, [
            %{message: "expected 3, got 4", file_path: "test/reservations_test.exs", line: 12}
          ])

        {:ok, Map.put(context, :after, read_settled_graph(context))}
      end

      then_ "the count is the same, which is what makes this hard", context do
        before_count = count_of(context.before, context.ordinary.id)
        after_count = count_of(context.after, context.ordinary.id)

        assert before_count == 1 and after_count == 1,
               """
               The premise did not hold, and both ways of failing it matter.

               A count of `nil` means no requirement on this component reads
               problems at all, so the freshness assertion below would be about
               nothing — which is how this first passed, comparing two `nil`s.
               Two different counts mean a count-keyed fingerprint would notice
               unaided, and the scenario stops being about the findings.

               before: #{inspect(before_count)}
               after:  #{inspect(after_count)}
               """

        {:ok, context}
      end

      then_ "and the requirement was recomputed anyway", context do
        refute freshness(context.after, context.ordinary.id) ==
                 freshness(context.before, context.ordinary.id),
               """
               A component's problems were replaced and its requirements were
               not reconsidered.

               The finding it was computed from has been fixed; a different one
               is there now. The row still carries the answer it worked out from
               the old one, and says nothing about the new one — which is a
               requirement claiming a freshness it does not have.

               before: #{inspect(freshness(context.before, context.ordinary.id))}
               after:  #{inspect(freshness(context.after, context.ordinary.id))}
               """

        {:ok, context}
      end
    end
  end

  defp problem_node(graph, component_id) do
    Enum.find(graph["nodes"] || [], fn node ->
      node["entity_type"] == "component" and
        to_string(node["entity_id"]) == to_string(component_id) and
        get_in(node, ["details", "analysis_source"]) == @source
    end)
  end

  defp count_of(graph, component_id), do: count_from(problem_node(graph, component_id))

  defp count_from(nil), do: nil
  defp count_from(node), do: get_in(node, ["details", "count"])

  defp freshness(graph, component_id) do
    graph["nodes"]
    |> Enum.filter(
      &(&1["entity_type"] == "component" and
          to_string(&1["entity_id"]) == to_string(component_id))
    )
    |> Enum.map(&{&1["name"], &1["checked_at"]})
    |> Enum.sort()
  end
end
