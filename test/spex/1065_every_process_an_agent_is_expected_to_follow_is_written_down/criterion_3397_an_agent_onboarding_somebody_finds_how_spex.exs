defmodule CodeMySpecSpex.Story1065.Criterion3397Spex do
  @moduledoc """
  Story 1065 — Every process an agent is expected to follow is written down
  Criterion 3397 — An agent onboarding somebody finds how.

  The rule:

  > The sales and onboarding process is written down, because an agent runs it
  > rather than a page.

  ## This process only exists because story 1030 moved it

  Onboarding used to be a wizard. A form does not need its process written
  down — the form *is* the process, and the order is whatever order the fields
  are in. Story 1030 hands it to the agent, and the moment it does, everything
  the form silently knew becomes something an agent has to be taught:
  which questions settle the matter, and what has to exist before it can hand
  the person over to the project's own agent.

  That is a general lesson worth stating once: handing work to agents converts
  UI into documentation. The form was the spec; take the form away and the spec
  has to be written somewhere.

  ## What has to exist before the hand-off

  Not incidental. `Agents.ensure_main_agent/1` answers
  `{:error, :no_main_working_copy}` until there is a checkout, so an agent that
  tries to hand off too early hands off to nothing. The document has to say
  what the preconditions are, or the hand-off is discovered by failing.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Knowledge.Tools.ReadKnowledge

  setup :register_log_in_setup_account
  setup :setup_active_project

  @path "process/onboarding.md"

  spex "An agent onboarding somebody finds how" do
    scenario "an agent put in front of a new arrival looks up what to do" do
      given_ "an agent put in front of somebody who has just arrived", context do
        # given: already true — `process/onboarding.md` is committed to the
        # repository. "Somebody who has just arrived" has no rows by
        # definition: an intake plan or a half-filled form would be a visitor
        # part-way through, which is the opposite of the scenario.
        {:ok, context}
      end

      when_ "it looks for how to take them from nothing to a working project", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ReadKnowledge.execute(%{path: @path}, frame)

        {:ok, context |> Map.put(:response, response) |> Map.put(:text, response_text(response))}
      end

      then_ "it finds the questions to settle", context do
        refute context.response.isError,
               "there is nothing at #{@path}. Onboarding was a form, the form is going " <>
                 "away, and nothing was written down in its place — so the agent that " <>
                 "replaces it has to invent the questions. Got:\n#{context.text}"

        assert context.text =~ ~r/question/i,
               "the document does not name the questions onboarding settles, which is " <>
                 "the one thing the form used to carry for free."

        {:ok, context}
      end

      then_ "and what has to exist before it can hand off", context do
        assert context.text =~ ~r/working cop|checkout|project/i,
               "the document does not say what must exist before the hand-off. An agent " <>
                 "that hands over too early hands over to nothing: there is no main " <>
                 "agent until there is a checkout for it to run in."

        {:ok, context}
      end
    end
  end
end
