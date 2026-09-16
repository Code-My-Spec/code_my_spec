defmodule CodeMySpecSpex.Story1062.Criterion3473Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3473 — An analyzer that finds the same problems again costs nothing.

  Rule: a recompute fires only when an observation has moved something the
  graph depends on.

  ## The other half of 3472, and the reason it is a separate criterion

  3472 says a finding swapped for a different one must move the fingerprint.
  On its own that is satisfiable by a fingerprint that moves for anything at
  all — including one keyed on the problem *rows*, which is the obvious
  implementation and the wrong one.

  Every `ProblemRepository` write path is delete-then-insert, so an analyzer
  that ran and found exactly what it found last time still produces new ids and
  new `updated_at` on every row. Keyed on those, a clean re-run costs a full
  recompute of every component the analyzer touched, forever, for no change.
  That is what this criterion holds the line against, and it is why the digest
  is over `{file_path, line, rule, message}` rather than over the rows.

  ## What it observes

  `checked_at` per requirement, compared against a backdated baseline — a
  recompute stamps it, so a row still carrying the old time is a row nothing
  spent work on. The verdict cannot be used here: it reads "1 test failure(s)"
  before and after by construction, which is the premise rather than the claim.

  Paired with 3472 deliberately. Asserting only this one is satisfied by a
  graph that never recomputes anything.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @source "exunit"
  @finding %{message: "assertion failed", file_path: "test/reservations_test.exs", line: 61}

  spex "A re-run that found the same things is not a change" do
    scenario "the analyzer reports exactly what it reported before" do
      given_ :context_with_infrastructure_sibling

      # `tests_passing` only consults exunit problems once a test file exists;
      # without one it short-circuits on "No test file exists yet" and the
      # scenario is about a requirement that never reads a problem.
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

      given_ "a test failure recorded against it, and a settled graph", context do
        :ok = Fixtures.replace_problems(context.scope, context.ordinary.id, @source, [@finding])

        # Twice, because `GraphWatcher.settle/1` answers `:ok` when it has no
        # timer set and cannot tell that from "the announcement has not arrived
        # yet" — so the first read can return before the pass it should have
        # waited for, and that pass then lands during the baseline read.
        _warm = read_settled_graph(context)
        _settled = read_settled_graph(context)

        :ok = Fixtures.backdate_requirement_freshness(context.scope)

        before = read_settled_graph(context)
        cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -60, :second)

        assert Enum.all?(freshness(before, context.ordinary.id), fn {_name, at} ->
                 NaiveDateTime.compare(NaiveDateTime.from_iso8601!(at), cutoff) == :lt
               end),
               """
               The baseline is not backdated, so a pass ran while it was being
               taken. Every row carries the current time, and "nothing was
               recomputed" can no longer be told from "everything was".

               baseline: #{inspect(freshness(before, context.ordinary.id))}
               """

        {:ok, Map.put(context, :before, before)}
      end

      when_ "the analyzer runs again and finds the same failure", context do
        # The same finding, through the same delete-then-insert path a real run
        # takes. The rows are new; what they say is not.
        :ok = Fixtures.replace_problems(context.scope, context.ordinary.id, @source, [@finding])

        {:ok, Map.put(context, :after, read_settled_graph(context))}
      end

      then_ "the requirements are left exactly as they were", context do
        assert freshness(context.after, context.ordinary.id) ==
                 freshness(context.before, context.ordinary.id),
               """
               An analyzer that found nothing new cost a recompute.

               Every problem row was deleted and written again, so their ids and
               timestamps moved — but the findings did not, and the findings are
               what any requirement reads. A fingerprint that cannot tell those
               apart charges a component's full recompute to every clean
               analyzer run, on every run, forever.

               before: #{inspect(freshness(context.before, context.ordinary.id))}
               after:  #{inspect(freshness(context.after, context.ordinary.id))}
               """

        {:ok, context}
      end
    end
  end

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
