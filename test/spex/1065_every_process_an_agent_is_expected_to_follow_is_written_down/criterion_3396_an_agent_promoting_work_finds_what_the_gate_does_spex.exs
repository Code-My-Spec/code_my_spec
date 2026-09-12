defmodule CodeMySpecSpex.Story1065.Criterion3396Spex do
  @moduledoc """
  Story 1065 — Every process an agent is expected to follow is written down
  Criterion 3396 — An agent promoting work finds what the gate does.

  The rule:

  > The devops process is written down, including how the preview and the dev
  > instance are managed.

  ## This one has a bill attached

  Promotion has three stages an agent cannot see and has to be told about: a
  gate that refuses on uncommitted work or any recorded problem, an analyzer
  sweep that has to be fresh, and a restart of the running application. Each
  has its own timeout and its own way of looking like failure when it is not.

  Measured on 2026-09-12, by an agent that had none of this written down:
  `promote_sync` answered "the merge landed, but the sweep verifying it did not
  finish in time" four times in a row while the merge had in fact landed each
  time; and it answered `{:harness_timeout, promotion_restart}` on calls where
  the restart *did* happen — the channel confirming it dies in the restart it is
  confirming. Both read as failure. Neither was one. The cost was roughly an
  hour of retrying and log-reading to establish what one paragraph would have
  said.

  So the assertions are the three stages and, separately, what a timeout at each
  means — because knowing the stages exist is not what was missing. Knowing that
  a timeout there is not a failure is.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Knowledge.Tools.ReadKnowledge

  setup :register_log_in_setup_account
  setup :setup_active_project

  @path "process/devops.md"

  spex "An agent promoting work finds what the gate does" do
    scenario "an agent with finished work looks up how it reaches the running copy" do
      given_ "an agent that has finished work and wants it on the running copy", context do
        {:ok, context}
      end

      when_ "it looks for how that happens", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ReadKnowledge.execute(%{path: @path}, frame)

        {:ok, context |> Map.put(:response, response) |> Map.put(:text, response_text(response))}
      end

      then_ "it finds what the gate checks, that a sweep runs, and that the app restarts",
            context do
        refute context.response.isError,
               "there is nothing at #{@path}, so promotion is learned by doing it wrong. " <>
                 "Got:\n#{context.text}"

        assert context.text =~ ~r/gate|refus/i,
               "the document does not say the promotion is gated, so an agent reads a " <>
                 "refusal as a fault rather than as the gate doing its job."

        assert context.text =~ ~r/sweep|analy/i,
               "the document does not mention the analyzer sweep, which is the stage " <>
                 "that takes minutes and looks like a hang."

        assert context.text =~ ~r/restart/i,
               "the document does not mention that the application restarts, so an agent " <>
                 "does not know the running copy goes away and comes back."

        {:ok, context}
      end

      then_ "and what a timeout at each of those means", context do
        assert context.text =~ ~r/timeout|time out|did not finish/i,
               "the document describes the stages but not their timeouts. That is the " <>
                 "half that cost an hour: a sweep that did not finish in time and a " <>
                 "restart whose confirmation died in the restart both report as failure " <>
                 "while having succeeded, and an agent with no warning retries them."

        {:ok, context}
      end
    end
  end
end
