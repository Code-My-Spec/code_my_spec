defmodule CodeMySpecSpex.Story1062.Criterion3428Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3428 — Satisfying one requirement makes the next one available.

  Rule: a requirement whose prerequisites move is reconsidered even though its
  own sources did not.

  ## The one thing a per-row fingerprint cannot do

  Every other criterion on this story is served by per-entity freshness: an
  entity's sources move, its fingerprint moves, its rows are recomputed. This
  one is the exception the story's own notes call out — "a requirement whose
  prerequisites move changes although its own sources did not. Edges are
  stored, so this is a walk, but a per-row fingerprint alone will not catch
  it."

  So it is the case where the incremental machinery could be perfectly correct
  and the graph still wrong. Nothing about the story changed: not its criteria,
  not its rules, not its personas, not its spex files. Its fingerprint is
  identical. What changed is two components, and the story's `bdd_specs_passing`
  is gated on the work those components carry. A recompute that consults only
  the entity's own sources leaves the story exactly as it was, and the work it
  now unblocks is never offered.

  The frontier is what moved, and it moved further than expected: finishing the
  children satisfied the parent context's `tests_passing` outright rather than
  offering it, because that requirement reads the same exunit result the
  children do. So the next *available* work is the story's, one entity further
  out — which is a stronger instance of the same rule, not a weaker one. The
  story and the components share no sources at all.

  ## Cross-entity, because within one entity the claim collapses

  Satisfying `test_file` on a component makes `test_spec_alignment` available —
  and writing that test file also *is* `test_spec_alignment`'s own source, so
  the case proves nothing about prerequisites. Inside one entity the two
  explanations are never separable. Parent and child are separate entities with
  separate fingerprints, which is what makes the claim observable at all.

  ## Why the project has to be satisfied first

  On a bare fixture project the actionable set is `["personas_complete"]` and
  nothing else, because the project chain is serial and gates every component.
  Measured while writing this: a context with three children, fully specced and
  implemented, offered exactly that one project-level requirement. A scenario
  built there would assert against a frontier that never reaches a component,
  and it is the same trap a wake criterion on story 1005 fell into — green with
  a fabricated cause, because `personas_complete` was in the set both before
  and after.
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

  spex "Work unblocked by somebody else's work is offered" do
    scenario "a context's children finish their tests" do
      given_ :context_with_three_children_in_satisfied_project

      given_ "a graph whose frontier has reached the children", context do
        _warm = read_settled_graph(context)

        {:ok, Map.put(context, :before, Fixtures.next_actionable_requirements(context.scope))}
      end

      when_ "each child gets its test file and the project scans", context do
        for {module_name, path} <- @children do
          :ok =
            Fixtures.write_env_file(
              context.environment,
              path,
              "defmodule #{module_name}Test do\n  use ExUnit.Case\nend\n"
            )
        end

        :ok = Fixtures.scan_working_copy(context.scope)

        # A test file existing is not a test passing. `RequirementGraph.serve/2`
        # applies analysis freshness at serve time, downgrade-only, so
        # `tests_passing` reads unsatisfied until an exunit run has been seen
        # against the tree as it is now — writing the files moved the tree past
        # the last run. Measured while writing this: with the files written and
        # no fresh run, both children still offered `tests_passing` and the
        # parent was still blocked.
        Fixtures.fresh_analysis_runs(context.scope)

        _settled = read_settled_graph(context)

        {:ok, Map.put(context, :after, Fixtures.next_actionable_requirements(context.scope))}
      end

      then_ "the story's specs were not on offer before", context do
        refute offered?(context.before, "Reservations story", "bdd_specs_passing"),
               """
               The premise did not hold: the story's `bdd_specs_passing` was
               already available before the components finished.

               Then nothing below is about a prerequisite moving — the
               requirement was never blocked, and a graph that ignores
               prerequisites entirely would pass.

               offered before: #{inspect(offered(context.before))}
               """

        {:ok, context}
      end

      then_ "and they are now", context do
        assert offered?(context.after, "Reservations story", "bdd_specs_passing"),
               """
               The components finished and the work that unblocks was not
               offered.

               Nothing about the story changed — same criteria, same rules, same
               personas, same files, same fingerprint. Only the components it
               depends on moved. A pass that recomputes an entity when its own
               sources move and never walks the edges leaves this requirement
               exactly as it was, and an agent asking what to do next is told
               about everything except the thing that just became possible.

               offered after: #{inspect(offered(context.after))}
               """

        {:ok, context}
      end
    end
  end

  defp offered?(requirements, entity_name, name) do
    Enum.any?(requirements, &(&1.entity_name == entity_name and to_string(&1.name) == name))
  end

  defp offered(requirements) do
    requirements |> Enum.map(&{&1.entity_name, to_string(&1.name)}) |> Enum.sort()
  end
end
