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

  ## The event is a file now, and it has to be

  This used to drive `record_git_state/2` — one checkout reporting itself three
  commits ahead of main. Those columns are gone: a mirror of git that nothing
  decided on, hashed into every story's fingerprint so a keystroke anywhere
  reconsidered every story in the project.

  Files are what is left that is genuinely per-checkout, and they were always
  the stronger example. `Preloader.load/1` scopes its file query to one copy
  and its own moduledoc measures what happens when it does not: 308
  `(component, role)` pairs satisfied here by files that exist only in another
  checkout, 303 of them specs, so an agent is told the spec is written and
  skips the component.

  The remaining working-copy columns cannot carry this claim at all.
  `preview_status` belongs to whichever copy is *main*, so it is shared by
  every vantage by design, and `asking_copy_inputs/2` is now the copy's id and
  nothing else — constant per checkout, so nothing about it can move.
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

        # Scanned as each copy in turn, so both have a file set of their own on
        # file. A scope naming no copy blends them, which is the state this
        # criterion cannot be observed in.
        :ok = scan_as(context, first.working_copy_id)
        :ok = scan_as(context, second.working_copy_id)

        _cold = read_graph(context, second.working_copy_id)

        {:ok,
         context
         |> Map.put(:first_copy_id, first.working_copy_id)
         |> Map.put(:second_copy_id, second.working_copy_id)
         |> Map.put(:second_before, read_graph(context, second.working_copy_id))}
      end

      when_ "a file appears in the first checkout and it scans", context do
        :ok =
          CodeMySpecSpex.Fixtures.write_env_file(
            context.environment,
            "lib/only_in_the_first_checkout.ex",
            "defmodule OnlyInTheFirstCheckout do\n  @moduledoc false\nend\n"
          )

        :ok = scan_as(context, context.first_copy_id)

        {:ok, context}
      end

      then_ "the second checkout still answers from its own computation", context do
        second_after = read_graph(context, context.second_copy_id)

        assert second_after["computed_at"] == context.second_before["computed_at"],
               """
               A file appearing in one checkout moved another checkout's answer.

               A requirement graph is a statement about a checkout. A file
               written in the first copy has nothing to say about the second —
               it is not in the second's tree — and invalidating project-wide
               wakes every agent on every copy each time any of them writes
               anything.

               second before: #{inspect(context.second_before["computed_at"])}
               second after:  #{inspect(second_after["computed_at"])}
               """

        {:ok, context}
      end
    end
  end

  # The scope names the checkout, because that is what `Preloader.load/1` scopes
  # its file query by. Built by putting the id on the scope the scenario already
  # has rather than by naming `CodeMySpec.Users.Scope`, which this boundary may
  # not reach.
  defp scan_as(context, working_copy_id) do
    context.scope
    |> Map.put(:active_working_copy_id, working_copy_id)
    |> CodeMySpecSpex.Fixtures.scan_working_copy()
  end
end
