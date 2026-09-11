defmodule CodeMySpecSpex.Story1063.Criterion3240Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3240 — An event for work on another working copy does not disturb
  mine.

  Rule: a domain event updates only the part of the graph it affects.

  The working-copy dimension of incremental updates. A requirement graph is a
  statement about a checkout — the preloader says so, warning that reading
  every checkout's files together makes a file present in one and absent in
  another read as present, and calling an agent path that does so a bug.

  So an event about one checkout has no business moving another's answer. Two
  worktrees on this machine at once is the ordinary case, not an edge one, and
  a project-wide invalidation would wake every agent on every copy each time
  any of them reported anything.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "One checkout's report leaves the other checkout's answer alone" do
    scenario "two checkouts, one reports" do
      given_ "two checkouts, each with a graph that has been served", context do
        first = join_working_copy(context, "/tmp/spex-3240-a", "the first checkout")
        second = join_working_copy(context, "/tmp/spex-3240-b", "the second checkout")

        :ok =
          CodeMySpecSpex.Fixtures.record_git_state(first.working_copy_id, %{
            ahead: 0,
            behind: 0,
            dirty: false
          })

        :ok =
          CodeMySpecSpex.Fixtures.record_git_state(second.working_copy_id, %{
            ahead: 0,
            behind: 0,
            dirty: false
          })

        _cold = read_graph(context, second.working_copy_id)

        {:ok,
         context
         |> Map.put(:first_copy_id, first.working_copy_id)
         |> Map.put(:second_copy_id, second.working_copy_id)
         |> Map.put(:second_before, read_graph(context, second.working_copy_id))}
      end

      when_ "the first checkout reports work main has not seen", context do
        :ok =
          CodeMySpecSpex.Fixtures.record_git_state(context.first_copy_id, %{
            ahead: 3,
            behind: 0,
            dirty: false
          })

        {:ok, context}
      end

      then_ "the second checkout still answers from its own computation", context do
        second_after = read_graph(context, context.second_copy_id)

        assert second_after["computed_at"] == context.second_before["computed_at"],
               """
               A report about one checkout moved another checkout's answer.

               A requirement graph is a statement about a checkout. An event
               carrying the first copy's commit count has nothing to say about
               the second, and invalidating project-wide wakes every agent on
               every copy each time any of them reports anything.

               second before: #{inspect(context.second_before["computed_at"])}
               second after:  #{inspect(second_after["computed_at"])}
               """

        {:ok, context}
      end
    end
  end

end
