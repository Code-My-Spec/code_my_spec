defmodule CodeMySpecSpex.Story1062.Criterion3352Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3352 — One project's burst does not collapse into another's.

  Rule: a burst of observations collapses into one update.

  The limit on coalescing. One watcher per project is what makes this true, so
  the criterion is really a statement about that shape holding: a project's
  window is its own, and writes to a neighbour neither extend it nor satisfy it.

  Worth pinning because the failure is silent in the direction that matters. If
  two projects shared a window, a quiet project's pass could be consumed by a
  busy one's, and the quiet project's agents would wait — which looks exactly
  like having no work rather than like a bug.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpec.Issues

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Each project's window is its own" do
    scenario "two projects are written to in the same moment" do
      given_ "two projects, each with a graph that has been served", context do
        # A distinct name, because the graph endpoint resolves a project by
        # name — `project_fixture/2` defaults every project to "some name", so
        # a second one makes that lookup ambiguous rather than wrong, and it
        # surfaces as MultipleResultsError from inside the plug.
        other =
          CodeMySpecSpex.Fixtures.project_fixture(context.scope, %{
            name: "the-other-project-#{System.unique_integer([:positive])}"
          })

        # And a local_path, or the scope plug refuses every request for it with
        # "Project has no local_path set — run init first". `setup_active_project`
        # does this for the project it makes; a second one is on its own.
        {:ok, other} =
          CodeMySpecSpex.Fixtures.set_project_local_path(
            other,
            Path.join(System.tmp_dir!(), "spex-3352-#{System.unique_integer([:positive])}")
          )
        # Both the id and the struct. A scope carrying `active_project_id` for
        # one project and `active_project` for another is read inconsistently
        # depending on which the caller reaches for, and the symptom is a write
        # landing on the project you were not looking at.
        other_scope = %{context.scope | active_project_id: other.id, active_project: other}
        other_context = %{context | project: other, scope: other_scope}

        warm_graph(context)
        warm_graph(other_context)

        {:ok,
         context
         |> Map.put(:other_context, other_context)
         |> Map.put(:before, read_graph(context))
         |> Map.put(:other_before, read_graph(other_context))}
      end

      when_ "both projects are written to inside the same window", context do
        {:ok, _} =
          Issues.create_issue(context.scope, %{
            title: "for the first project",
            description: "one of two projects written at once",
            severity: :low
          })

        {:ok, _} =
          Issues.create_issue(context.other_context.scope, %{
            title: "for the second project",
            description: "the other of two projects written at once",
            severity: :low
          })

        {:ok, context}
      end

      then_ "each project's graph moved on its own account", context do
        refute read_graph(context)["computed_at"] == context.before["computed_at"],
               "the first project's graph did not move for its own write"

        refute read_graph(context.other_context)["computed_at"] ==
                 context.other_before["computed_at"],
               """
               The second project's graph did not move for its own write.

               One watcher per project is what keeps a window private. If two
               projects share one, a quiet project's pass can be consumed by a
               busy neighbour's and its agents simply wait — which looks like
               having no work rather than like a fault.
               """

        {:ok, context}
      end
    end
  end
end
