defmodule CodeMySpecSpex.Story1065.Criterion3394Spex do
  @moduledoc """
  Story 1065 — Every process an agent is expected to follow is written down
  Criterion 3394 — An agent handed a component to build finds the order.

  The rule:

  > The code process is written down — how a component goes from spec to test
  > to implementation.

  ## What an agent cannot work out for itself

  There are modules for `component_spec`, `component_test`, `component_code`,
  `context_spec`, `develop_context` and `develop_live_view`, and nothing that
  says which comes first or what finishes each one. The order is not guessable
  from the module list: `component_test` before `component_code` is a choice
  this project made, and an agent that assumes the other order writes an
  implementation with nothing holding it to the spec.

  So the two things asserted here are the two an agent is actually missing —
  what order the steps go in, and how it knows a step is done.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Knowledge.Tools.ReadKnowledge

  setup :register_log_in_setup_account
  setup :setup_active_project

  @path "process/code.md"

  spex "An agent handed a component to build finds the order" do
    scenario "an agent looks up how component work is done here" do
      given_ "an agent handed a component to build", context do
        {:ok, context}
      end

      when_ "it looks for how that work is done here", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ReadKnowledge.execute(%{path: @path}, frame)

        {:ok, context |> Map.put(:response, response) |> Map.put(:text, response_text(response))}
      end

      then_ "it finds what order the steps go in", context do
        refute context.response.isError,
               "there is nothing at #{@path}. The code process has six task modules " <>
                 "and no document, so the order between them is something each agent " <>
                 "works out again. Got:\n#{context.text}"

        assert context.text =~ ~r/spec/i and context.text =~ ~r/test/i,
               "the document does not name the steps it is supposed to order."

        {:ok, context}
      end

      then_ "and what each one is finished by", context do
        # "Finished by" rather than "done": every step in this graph ends in
        # something observable — a file that exists, a spec that passes, an
        # evaluation recorded. An agent that knows the order but not the
        # finishing condition stops when it feels done, which is the failure
        # this half is about.
        assert context.text =~ ~r/satisf|complete|evaluat|passes|green/i,
               "the document orders the steps but never says how an agent knows one is " <>
                 "finished, so it stops when it feels finished rather than when the " <>
                 "step's own condition is met."

        {:ok, context}
      end
    end
  end
end
