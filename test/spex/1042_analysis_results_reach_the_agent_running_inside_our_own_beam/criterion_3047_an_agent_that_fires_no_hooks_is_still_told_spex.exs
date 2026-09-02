defmodule CodeMySpecSpex.Story1042.Criterion3047Spex do
  @moduledoc """
  Story 1042 — Analysis results reach the agent running inside our own BEAM.
  Criterion 3047 — An agent that fires no hooks is still told.

  Rule: Delivery rides the agent's own tool results; no hook is involved.

  Story 890 records its delivery surface as a Three Amigos decision —
  "PostToolUse, on every tool call. The MCP tools are ours and already append
  text footers." True, and true only of agents running under Claude Code, which
  fires seven hooks on their behalf. An Alloy agent fires none.

  ## Why this is not a restatement of 3044

  3044 asks whether the agent is told. This asks whether being told depends on a
  hook, and it is checked by giving the agent no session for a hook to be about.
  An implementation that satisfied 3044 by quietly synthesising a hook payload —
  inventing a `session_id` so the existing path could run — would pass that
  criterion and fail this one, which is the point of having both.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Delivery rides the agent's own tool results; no hook is involved" do
    scenario "An agent that fires no hooks is still told" do
      given_ "an agent running under Alloy, which fires no Claude Code hooks", context do
        {:ok, Map.put(context, :agent_id, running_agent(context))}
      end

      given_ "an analyzer run for its working copy has landed with problems", context do
        Fixtures.problem_fixture(context.scope, %{
          source: "credo",
          message: "Modules should have a @moduledoc tag",
          file_path: "lib/example_context.ex"
        })

        {:ok, context}
      end

      when_ "the agent makes its next tool call", context do
        {:ok, Map.put(context, :result, Fixtures.run_script("return 1", agent_context(context)))}
      end

      then_ "the result carries the alert", context do
        assert {:ok, text} = context.result

        assert text =~ "credo", """
        The agent was told nothing, and the reason is that the only delivery
        path in the product is a hook this agent's runtime does not have. That
        is story 890's surface decision holding for one persona and not the
        other.

        Got: #{inspect(text)}
        """

        {:ok, context}
      end

      then_ "and it was reached without a session for a hook to be about", context do
        # An Alloy agent is identified by `agent_id`; it has no `session_id`,
        # which is what a hook payload is keyed on. If delivery here needed one,
        # something would have had to invent it.
        refute Map.has_key?(agent_context(context), :session_id),
               "the agent's own tool context grew a session id, which is a hook's shape"

        {:ok, context}
      end
    end
  end
end
