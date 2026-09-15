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
      given_ "a project whose graph says every issue is triaged", context do
        before = read_settled_graph(context)

        assert satisfaction_of(before, "issues_triaged") == true,
               """
               The premise did not hold: this project's graph does not start
               with `issues_triaged` satisfied, so the change under test has
               nowhere to show up.

               issues_triaged: #{inspect(satisfaction_of(before, "issues_triaged"))}
               requirements present: #{inspect(requirement_names(before))}
               """

        {:ok, Map.put(context, :before, before)}
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

      then_ "the graph says there is an issue to triage", context do
        after_filing = read_graph(context)

        assert satisfaction_of(after_filing, "issues_triaged") == false,
               """
               An issue was filed and the graph went on saying every issue is
               triaged.

               This is the ninety minutes of silence: the agent that triages
               issues was waiting to be woken when a product requirement was
               unblocked, and filing an issue is exactly that happening.

               The claim is about the verdict, not about a clock. A pass that
               ran and applied nothing moves `computed_at` exactly as far as
               one that worked, and `checked_at` is second-resolution besides —
               so the only thing that distinguishes a writer that announces
               from one that does not is the answer itself changing.

               issues_triaged before: #{inspect(satisfaction_of(context.before, "issues_triaged"))}
               issues_triaged after:  #{inspect(satisfaction_of(after_filing, "issues_triaged"))}
               """

        {:ok, context}
      end
    end
  end

end
