defmodule CodeMySpecSpex.Story1062.Criterion3518Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3518 — An observation about one checkout costs nothing in the
  others.

  Rule: the checkouts a drain settles are the ones the observation named.

  ## The multiplier this bounds

  Rows are stored per vantage, so every requirement exists once per checkout
  that has read the graph. A drain that settles every vantage therefore costs
  the project's size *times the number of checkouts*, and that second factor is
  invisible in every other cost reading on this story — queries and rows scale
  with it silently, and a criterion written on one checkout passes at any
  multiplier.

  This box serves eleven checkouts of this project. A finding recorded in one
  worktree that settles all eleven does eleven times the work it needs to, and
  ten elevenths of that rewrites answers about trees the observation says
  nothing about.

  ## Why the count and not the rows

  A rows-written figure cannot separate "settled two checkouts cheaply" from
  "settled one checkout expensively". The vantage count is the number the rule
  is actually about, and the drain already carries it — so this reads it rather
  than inferring it from a total. That is the criterion's own distinction
  between a number that is reported and one that has to be deduced.

  ## What counts as named

  An observation recorded from a checkout names that checkout. The `nil` vantage
  — the row-space a reader with no checkout is answered from — is a legitimate
  second one: it is computed from the project's default checkout, so a change
  *in that checkout* genuinely moves it. What must not appear is a third, which
  is some other worktree being settled by an observation that never mentioned
  it.

  ## What it observes

  `last_drain`, served on the same graph endpoint every other criterion here
  reads. `DrainCost.last/1` exists for exactly this — "a claim whose evidence
  lives only in a log line is one nothing can assert against" — and the
  controller publishes it beside the nodes so the cost rule is checkable from
  outside.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @finding %{
    message: "Function body is nested too deep (max_nesting is 2).",
    file_path: "lib/reservations/booking.ex",
    line: 14
  }

  spex "A drain settles the checkouts its observation named", criterion: 1427 do
    scenario "a finding is recorded on one of two checkouts" do
      given_ :synced_context_component

      given_ "a second checkout of the same project", context do
        second_root = CodeMySpec.TempFile.owned_dir("test")
        {reply, _socket} = join_working_copy_socket(context, second_root, "the second checkout")
        second_id = reply["harness_id"] || reply[:working_copy_id]

        refute second_id == context.scope.active_working_copy_id,
               "two checkouts must be two copies; the server issued one id for both"

        {:ok,
         context
         |> Map.put(:first_id, context.scope.active_working_copy_id)
         |> Map.put(:second_id, second_id)}
      end

      given_ "both checkouts' requirements stored", context do
        first = read_settled_graph(context, context.first_id)
        second = read_settled_graph(context, context.second_id)

        assert first["nodes"] != [], "the first checkout stores nothing to settle"
        assert second["nodes"] != [], "the second checkout stores nothing to leave alone"

        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      when_ "an observation about the first checkout is applied", context do
        scope = %{context.scope | active_working_copy_id: context.first_id}

        :ok = Fixtures.replace_problems(scope, context.component.id, "credo", [@finding])
        :ok = Fixtures.settle_graph(scope)

        {:ok, Map.put(context, :drain, read_graph(context)["last_drain"])}
      end

      then_ "the drain reports the number of checkouts it settled", context do
        assert context.drain,
               "the drain reported nothing at all, so there is no count to hold to the rule"

        assert is_integer(context.drain["vantages"]),
               """
               The drain did not say how many checkouts it settled:
               #{inspect(context.drain["vantages"])}.

               This is the one factor no other cost reading on this story can
               see. Rows and queries both scale with the number of checkouts
               silently, so a drain that does not report the count cannot be
               held to a rule about it at all.

               #{report(context.drain)}
               """

        {:ok, context}
      end

      then_ "and that number is the checkouts the observation named", context do
        settled = context.drain["vantages"]

        assert settled <= 2,
               """
               An observation recorded from one checkout settled #{settled}
               vantages.

               Two is the ceiling and both are named: the checkout the
               observation was recorded from, and the `nil` row-space a reader
               with no checkout is answered from, which is computed from the
               project's default checkout and therefore genuinely moves with it.

               Anything beyond that is a worktree the observation never
               mentioned. On this box that is eleven checkouts settled by a
               finding recorded in one of them, with ten elevenths of the work
               rewriting answers about trees nothing has happened in.

               #{report(context.drain)}
               """

        {:ok, context}
      end
    end
  end

  defp report(drain) do
    "#{drain["kind"]} drain — #{drain["queries"]} queries, " <>
      "#{drain["rows_written"]} rows written, " <>
      "#{drain["observations"]} observation(s), " <>
      "#{drain["vantages"]} vantage(s)"
  end
end
