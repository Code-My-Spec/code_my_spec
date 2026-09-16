defmodule CodeMySpecSpex.Story1062.Criterion3448Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3448 — An analyzer finishing costs nothing for the components it
  found nothing in.

  Rule: a recompute fires only when an observation has moved something the
  graph depends on.

  ## The value that moved everything at once

  `analysis_fresh` is four project-wide booleans saying whether each analyzer
  has been seen against the tree as it is now. As a fingerprint input it flipped
  for the whole project whenever any run finished, so every component's
  fingerprint moved together: measured on this project, **1116 of 1347
  requirements recomputed to correct one term, twice in an hour, at roughly 80×
  the cost of an ordinary read.**

  It is also the wrong direction. The rule underneath all of this is that
  changing files stales the graph and running analyzers freshens it — and as an
  input this did the opposite, making the completion of a run, the event that
  makes the graph *more* trustworthy, the thing that invalidated it.

  `Freshness.component/2` names this criterion in the comment where it excludes
  the value, and `GraphFingerprint.compute/2` carries the same exclusion one
  level up.

  ## Better answers without recomputing, which is the whole shape

  Freshness is not an input to a requirement. It is a qualifier on *serving*
  one: `RequirementGraph.serve/2` applies it from the current context on every
  read, downgrade-only and idempotent, so a cached graph is re-qualified against
  today's freshness without being rebuilt.

  That makes the two halves here inseparable and is why they are asserted
  together. A run landing must *improve an answer* — otherwise "nothing was
  recomputed" is satisfied by a graph that ignored the run entirely — and it
  must improve it **without recomputing anything**, which is the cost claim. A
  system can do either alone; doing both is the design.

  `tests_passing` is the requirement that shows it. With test files written and
  no run seen against them it reads unsatisfied, held down by staleness rather
  than by a failure. The run lands, the downgrade lifts, and no row is touched.

  ## It guards a pair, and only the pair — measured

  `analysis_fresh` is excluded from `Freshness.component/2` *and* from
  `GraphFingerprint.compute/2`, and putting it back in either one alone does
  not fail this criterion. Verified both ways while writing it: with 29
  component requirements in the baseline and the value genuinely flipping from
  all-false to all-true, each single mutation stayed green and the pair failed
  with all 29 recomputed.

  The two are coupled by the write gate. `GraphCache.publish/4` answers
  `:unchanged` when the whole-graph fingerprint has not moved and
  `persist_projection/5` keys its node and edge writes off that answer, so a
  per-entity fingerprint that notices something the global one does not causes
  a recompute whose result is then discarded — work done and thrown away,
  looking from outside exactly like work that never happened. In the other
  direction the cache simply misses and everything is rebuilt.

  So the fingerprints have to agree about what counts as an input, and this is
  what says so. The same coupling is what made the count-keyed
  `problems_digest` worth fixing: there the disagreement was silently
  discarding recomputes the graph had correctly decided to do.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @children [
    {"Reservations.BookingRepo", "test/reservations/booking_repo_test.exs"},
    {"Reservations.PricingService", "test/reservations/pricing_service_test.exs"}
  ]

  spex "A clean analyzer run re-qualifies answers without rebuilding them" do
    scenario "a run lands on a project it finds nothing wrong with" do
      given_ :context_with_three_children_in_satisfied_project

      given_ "test files the analyzer has not been run against yet", context do
        for {module_name, path} <- @children do
          :ok =
            Fixtures.write_env_file(
              context.environment,
              path,
              "defmodule #{module_name}Test do\n  use ExUnit.Case\nend\n"
            )
        end

        :ok = Fixtures.scan_working_copy(context.scope)

        _warm = read_settled_graph(context)
        _settled = read_settled_graph(context)

        :ok = Fixtures.backdate_requirement_freshness(context.scope)

        before = read_settled_graph(context)
        cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -60, :second)

        assert Enum.all?(component_freshness(before), fn {_entity, _name, at} ->
                 NaiveDateTime.compare(NaiveDateTime.from_iso8601!(at), cutoff) == :lt
               end),
               """
               The baseline is not backdated, so a pass ran while it was being
               taken and every row already carries the current time. "Nothing
               was recomputed" is then unobservable.
               """

        {:ok, Map.put(context, :before, before)}
      end

      when_ "the analyzers finish, finding nothing", context do
        Fixtures.fresh_analysis_runs(context.scope)

        {:ok, Map.put(context, :after, read_settled_graph(context))}
      end

      then_ "an answer that was held down by staleness is released", context do
        before_verdicts = verdicts(context.before, "tests_passing")
        after_verdicts = verdicts(context.after, "tests_passing")

        refute after_verdicts == before_verdicts,
               """
               The analyzers finished and no answer changed.

               Without this half the criterion below is satisfied by a graph
               that ignored the run completely — nothing recomputed, because
               nothing happened. `tests_passing` was unsatisfied because no run
               had been seen against these test files, not because anything
               failed, and finishing the run is exactly what lifts that.

               before: #{inspect(before_verdicts)}
               after:  #{inspect(after_verdicts)}
               """

        {:ok, context}
      end

      then_ "and not one component was recomputed to do it", context do
        moved =
          component_freshness(context.after)
          |> Enum.reject(&(&1 in component_freshness(context.before)))

        assert moved == [],
               """
               #{length(moved)} requirement(s) were recomputed because an
               analyzer finished.

               Analysis freshness is project-wide, so as a fingerprint input it
               moves every component at once — measured here at 1116 of 1347
               requirements to correct one term, twice in an hour. It is not an
               input: it qualifies the answer at serve time, downgrade-only, so
               a finished run should re-qualify a cached graph rather than
               rebuild it. Anything recomputed here is the whole project paying
               for the event that was supposed to make it cheaper.

               moved: #{moved |> Enum.take(5) |> inspect()}
               """

        {:ok, context}
      end
    end
  end

  defp verdicts(graph, name) do
    (graph["nodes"] || [])
    |> Enum.filter(&(&1["name"] == name))
    |> Enum.map(&{&1["entity_name"], &1["satisfied"]})
    |> Enum.sort()
  end

  defp component_freshness(graph) do
    (graph["nodes"] || [])
    |> Enum.filter(&(&1["entity_type"] == "component"))
    |> Enum.map(&{&1["entity_name"], &1["name"], &1["checked_at"]})
    |> Enum.sort()
  end
end
