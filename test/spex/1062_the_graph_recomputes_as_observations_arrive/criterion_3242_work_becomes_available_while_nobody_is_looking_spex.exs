defmodule CodeMySpecSpex.Story1062.Criterion3242Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3242 — Work becomes available while nobody is looking.

  Rule: the graph updates when something is written, not only when something
  reads it.

  The criterion this whole story was written from. Every graph computation in
  the application used to be triggered by a reader — a LiveView rendering,
  `get_next_requirement`, the stop menu. Nothing computed on a write and
  nothing computed on a schedule, so an agent that was not reading never
  learned that work had appeared.

  Watched on 2026-09-07: a product agent stopped correctly with an empty queue,
  saying it would wait to be woken when a product requirement was unblocked,
  and sat for ninety minutes while four issues were filed and `issues_triaged`
  became actionable again.

  So the observation is deliberately made with nothing reading: the write
  happens, and only afterwards does anyone look. If the graph only computes on
  read, the answer would be produced by the looking rather than by the writing,
  and this criterion could not tell the difference. It can, because the
  cached answer carries when it was computed.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpec.Issues

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A write moves the graph with nobody reading" do
    scenario "issues are filed while nothing is looking at the project" do
      given_ "a project whose graph has been served, and then left alone", context do
        _cold = read_graph(context)
        {:ok, Map.put(context, :before, read_graph(context))}
      end

      when_ "issues are filed and nothing reads the graph in the meantime", context do
        for n <- 1..4 do
          {:ok, _issue} =
            Issues.create_issue(context.scope, %{
              title: "finding #{n}",
              description: "filed while nobody was looking",
              severity: :medium
            })
        end

        {:ok, context}
      end

      then_ "the graph already reflects them when somebody finally looks", context do
        after_writes = read_graph(context)

        refute last_recompute(after_writes) == last_recompute(context.before),
               """
               Four issues were filed and the graph went on answering from the
               computation it made before them.

               This is the ninety minutes: the agent that triages issues was
               waiting to be woken when a product requirement was unblocked,
               and filing an issue is exactly that happening. If the graph only
               computes when something reads it, an agent that is not reading
               never learns that work appeared.

               before: #{inspect(last_recompute(context.before))}
               after:  #{inspect(last_recompute(after_writes))}
               """

        {:ok, context}
      end
    end
  end

end
