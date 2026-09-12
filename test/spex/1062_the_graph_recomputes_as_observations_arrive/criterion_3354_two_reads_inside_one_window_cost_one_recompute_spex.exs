defmodule CodeMySpecSpex.Story1062.Criterion3354Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3354 — Two reads inside one window cost one recompute.

  Rule: a read with observations still pending recomputes before it answers.

  The efficiency half of the read-triggered flush. A read folds in what is
  pending — but having folded it in, there is nothing pending any more, so the
  next read is an ordinary cached read.

  Without this, "settle before answering" degrades into "recompute per read"
  the moment two readers arrive together, which on a busy project is the normal
  case: a LiveView rendering while an agent asks for its next requirement while
  a stop hook counts problems.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpec.Issues

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A flush serves every reader behind it" do
    scenario "two reads follow one write" do
      given_ "a project whose graph has been served", context do
        {:ok, warm_graph(context) |> Map.put(:before, read_graph(context))}
      end

      when_ "an issue is filed and the graph is read twice in succession", context do
        {:ok, _issue} =
          Issues.create_issue(context.scope, %{
            title: "read twice after this",
            description: "inside one collection window",
            severity: :low
          })

        first = read_graph(context)
        second = read_graph(context)

        {:ok, context |> Map.put(:first, first) |> Map.put(:second, second)}
      end

      then_ "both reads answer from the same computation", context do
        refute context.first["computed_at"] == context.before["computed_at"],
               "the first read must fold the write in, or this criterion is about nothing"

        assert context.first["computed_at"] == context.second["computed_at"],
               """
               Two reads after one write produced two computations.

               The first read folds in what is pending; having done so there is
               nothing pending, and the second is an ordinary cached read. If
               each read recomputes, "settle before answering" has become
               "recompute per read" — which is what this story replaced.

               first:  #{inspect(context.first["computed_at"])}
               second: #{inspect(context.second["computed_at"])}
               """

        {:ok, context}
      end
    end
  end
end
