defmodule CodeMySpecSpex.Story1065.Criterion3395Spex do
  @moduledoc """
  Story 1065 — Every process an agent is expected to follow is written down
  Criterion 3395 — An agent testing a story finds how a result is recorded.

  The rule:

  > The QA process is written down — how a story is tested and how a result is
  > recorded.

  ## The part that is not obvious

  QA has playbooks already — `qa_setup`, `qa_story`, `qa_journey`,
  `qa_integration_plan` all have knowledge folders. What they do not settle is
  the bookkeeping around a result: `qa_complete` is satisfied by "at least one
  valid DB-backed pass attempt", which means an attempt can be *invalid*, and
  an agent that does not know what invalidates one can believe it has finished
  QA that does not count.

  `invalidate_qa_attempt` exists as a tool, so invalidation is a thing that
  happens deliberately. An agent needs to know what makes an attempt valid
  before it spends a browser session producing one.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Knowledge.Tools.ReadKnowledge

  setup :register_log_in_setup_account
  setup :setup_active_project

  @path "process/qa.md"

  spex "An agent testing a story finds how a result is recorded" do
    scenario "an agent about to test a story looks up how the result counts" do
      given_ "an agent about to test a story", context do
        {:ok, context}
      end

      when_ "it looks for how a pass or a failure is recorded", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ReadKnowledge.execute(%{path: @path}, frame)

        {:ok, context |> Map.put(:response, response) |> Map.put(:text, response_text(response))}
      end

      then_ "it finds what counts as a valid attempt", context do
        refute context.response.isError,
               "there is nothing at #{@path}. The per-task QA playbooks describe testing " <>
                 "and not the bookkeeping, so how a result counts is unwritten. " <>
                 "Got:\n#{context.text}"

        assert context.text =~ ~r/attempt/i,
               "the document does not talk about attempts at all, so an agent has no " <>
                 "idea its work is recorded as one, or that more than one may exist."

        {:ok, context}
      end

      then_ "and what invalidates one", context do
        assert context.text =~ ~r/invalidat/i,
               "the document never says an attempt can be invalidated. An agent that " <>
                 "believes a pass is permanent will report a story done and be surprised " <>
                 "when `qa_complete` goes back to unsatisfied."

        {:ok, context}
      end
    end
  end
end
