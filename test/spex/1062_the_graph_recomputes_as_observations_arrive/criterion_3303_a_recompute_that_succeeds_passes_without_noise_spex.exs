defmodule CodeMySpecSpex.Story1062.Criterion3303Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3303 — A recompute that succeeds passes without noise.

  Rule: a recompute that fails is raised loudly rather than retried quietly.

  The ordinary half of the loud-failure rule, and the reason the rule can be
  loud at all. A recompute happens on every write to every graph input, which
  on a busy project is constantly — so if the successful path said anything, the
  noise would bury the failing one and nobody would read either.

  This is the same argument as the empty-message warning that fired 1,620 times
  in a day and made a log unreadable during an incident: a message that appears
  on success as often as on failure carries no signal, and the cost is paid
  when something is actually wrong.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import ExUnit.CaptureLog

  alias CodeMySpec.Issues

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A healthy recompute logs nothing" do
    scenario "a write lands and the graph recomputes normally" do
      given_ "a project whose graph has been served", context do
        {:ok, warm_graph(context) |> Map.put(:before, read_graph(context))}
      end

      when_ "an issue is filed and the graph recomputes", context do
        logged =
          capture_log(fn ->
            {:ok, _issue} =
              Issues.create_issue(context.scope, %{
                title: "an ordinary write",
                description: "nothing wrong with it",
                severity: :low
              })

            :ok = CodeMySpecSpex.Fixtures.settle_graph(context.scope)
          end)

        {:ok, Map.put(context, :logged, logged)}
      end

      then_ "the recompute happened and said nothing about itself", context do
        after_write = read_settled_graph(context)

        refute last_recompute(after_write) == last_recompute(context.before),
               "the recompute must really have happened for its silence to mean anything"

        refute context.logged =~ "[GraphWatcher]",
               """
               A successful recompute logged about itself.

               A recompute happens on every write to every graph input, so
               anything said on the healthy path is said constantly. That is
               how a log becomes unreadable during an incident — and the loud
               failure this rule asks for is only loud if the quiet case is
               quiet.

               logged: #{inspect(context.logged)}
               """

        {:ok, context}
      end
    end
  end
end
