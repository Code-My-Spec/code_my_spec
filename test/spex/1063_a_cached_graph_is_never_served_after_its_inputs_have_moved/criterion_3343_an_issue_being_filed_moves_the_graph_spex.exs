defmodule CodeMySpecSpex.Story1063.Criterion3343Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3343 — An issue being filed moves the graph.

  Rule: a domain object we own publishes an event when it changes.

  Issues are one of the graph's ten inputs and they are ours — we write them,
  so the graph can be told rather than left to discover them.

  This is the input the whole mechanism was built for. Watched on 2026-09-07: a
  product agent stopped correctly with an empty queue, saying it would wait to
  be woken when a product requirement was unblocked, and sat for ninety minutes
  while four issues were filed and `issues_triaged` became actionable again.
  Nothing recomputed because nothing read.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpec.Issues

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Filing an issue moves the graph" do
    scenario "an issue is filed against the project" do
      given_ "a project whose graph has been served", context do
        _cold = read_graph(context)
        {:ok, Map.put(context, :before, read_graph(context))}
      end

      when_ "an issue is filed against the project", context do
        {:ok, _issue} =
          Issues.create_issue(context.scope, %{
            title: "something is wrong",
            description: "filed while the graph was cached",
            severity: :medium
          })

        {:ok, context}
      end

      then_ "the graph no longer answers from the computation made before it", context do
        after_filing = read_graph(context)

        refute after_filing["computed_at"] == context.before["computed_at"],
               """
               An issue was filed and the graph went on answering from the
               computation it made before.

               This is the ninety minutes of silence: the agent that triages
               issues was waiting to be woken when a product requirement was
               unblocked, and filing an issue is exactly that happening.

               before: #{inspect(context.before["computed_at"])}
               after:  #{inspect(after_filing["computed_at"])}
               """

        {:ok, context}
      end
    end
  end

end
