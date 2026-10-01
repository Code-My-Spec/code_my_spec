defmodule CodeMySpecSpex.Story1062.Criterion3517Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3517 — A drain that moves nothing writes nothing.

  Rule: an answer that has not changed is not rewritten to say the same thing.

  ## Why writes rather than time

  "Cost is proportional to what changed" is the rule this story exists for, and
  for most of its criteria `checked_at` is a fair reading of it: a row that was
  rewritten has a new stamp. It stops being fair exactly here. A drain can
  settle a requirement to the value it already had — same verdict, same reason,
  new timestamp — and every stamp-based instrument reports that as work done
  correctly, because from the outside it is indistinguishable from a real
  change.

  Rows written is the reading that survives. It says the same thing about a pass
  and about a projection maintained from handlers, which is what lets this
  criterion stay meaningful across the swap the story is building toward.

  ## What "moves nothing" has to mean

  Not an idle drain. A drain with no marks at all trivially writes nothing and
  would let a system that rewrites every row on every observation pass this.

  So the observation here is real and is applied — the same findings are
  recorded a second time. Something genuinely happened, the drain genuinely ran,
  and every verdict it computes lands on the value already stored. That is the
  case where writing is pure cost and the only correct number of rows is zero.

  ## What it observes

  `last_drain`, served on the same graph endpoint every other criterion here
  reads. `DrainCost.last/1` exists for exactly this — "a claim whose evidence
  lives only in a log line is one nothing can assert against" — and the
  controller publishes it beside the nodes so the cost rule is checkable from
  outside.

  Not the `[DrainCost]` log line, which says the same thing and is unreadable
  here: the test environment runs at `level: :warning`, so the `Logger.info`
  never reaches a handler and `capture_log` comes back empty — indistinguishable
  from a drain that reported nothing.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  # Recorded as spex: since 28d72f8a it is the only source whose findings
  # announce an observation at all, so a credo write would leave nothing to
  # drain.
  @finding %{
    message: "Function body is nested too deep (max_nesting is 2).",
    file_path: "lib/reservations/booking.ex",
    line: 14
  }

  spex "An observation that changes no answer costs no writes", criterion: 1426 do
    scenario "the same findings are recorded a second time" do
      given_ :synced_context_component

      given_ "a settled graph that already carries these findings", context do
        :ok = Fixtures.replace_problems(context.scope, context.component.id, "spex", [@finding])
        :ok = Fixtures.settle_graph(context.scope)

        graph = read_settled_graph(context)

        assert graph["nodes"] != [],
               "nothing is stored, so a drain writing nothing would be vacuously true"

        {:ok, context}
      end

      when_ "the same findings are recorded again and the drain runs", context do
        :ok = Fixtures.replace_problems(context.scope, context.component.id, "spex", [@finding])
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :drain, read_graph(context)["last_drain"])}
      end

      then_ "the drain reports what it cost", context do
        assert context.drain,
               """
               The drain ran and reported nothing.

               Every other assertion on this criterion reads that report. A
               drain that is silent about its cost cannot be held to a cost rule
               at all — the number is not wrong, it is absent, and the rule
               becomes unfalsifiable.
               """

        {:ok, context}
      end

      then_ "and it was a drain that had something to apply", context do
        observations = context.drain["observations"]

        assert is_integer(observations) and observations > 0,
               """
               The drain applied nothing: #{inspect(observations)} observation(s).

               An idle drain writes no rows for the uninteresting reason, and it
               would let a system that rewrites every row on every real
               observation pass the assertion below. This criterion is about a
               drain that ran, computed verdicts, and found them all unchanged —
               so there has to have been something to apply.

               #{report(context.drain)}
               """

        {:ok, context}
      end

      then_ "and it reports no rows written", context do
        written = context.drain["rows_written"]

        assert written == 0,
               """
               A drain applied an observation that changed no answer and wrote
               #{inspect(written)} row(s).

               Every verdict it computed was already stored at that value. The
               writes bought nothing: no answer differs afterwards, and the only
               thing that moved is the stamp on rows that were already correct.

               That is also why this cannot be caught by a timestamp. A rewrite
               to the same value looks exactly like a real change to anything
               reading `checked_at`, which is what makes rows written the
               instrument this rule needs.

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
