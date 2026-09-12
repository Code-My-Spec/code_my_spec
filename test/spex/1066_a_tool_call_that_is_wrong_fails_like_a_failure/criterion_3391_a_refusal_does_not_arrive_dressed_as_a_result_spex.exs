defmodule CodeMySpecSpex.Story1066.Criterion3391Spex do
  @moduledoc """
  Story 1066 — A tool call that is wrong fails like a failure
  Criterion 3391 — A refusal does not arrive dressed as a result.

  The rule:

  > A call the sandbox rejects stops the script rather than answering it.

  ## The narrow claim, separate from its siblings

  Three criteria on this story circle the same defect and each pins a different
  edge, so a partial fix cannot look complete:

  - 3390 — execution stops.
  - 3388 — ignoring the failure is not rewarded with a plausible answer.
  - this one — the *packaging*. Whatever comes back is not wearing the clothes
    of a successful return.

  A fix could satisfy the first two by halting and returning nothing, and still
  hand that nothing back under `Returned:` with `isError` unset, which is how
  the original mistake was possible.

  ## Why the wording is about clothes rather than content

  The content was never the problem. The message said exactly what was wrong.
  What misled was the frame around it — a value, returned, looking like every
  other value this tool returns. So the assertion is about the frame: the
  response is marked as an error, and it is not introduced as the script's
  return value.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A refusal does not arrive dressed as a result" do
    scenario "a script makes a tool call the sandbox rejects" do
      given_ "a script making a call the sandbox will refuse", context do
        {:ok,
         Map.put(context, :script, ~s|return add_rule({ story_id = "1066", statement = 7 })|)}
      end

      when_ "the agent reads what came back", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = RunScript.execute(%{script: context.script}, frame)

        {:ok, context |> Map.put(:response, response) |> Map.put(:text, response_text(response))}
      end

      then_ "it reads as a refusal", context do
        assert context.response.isError,
               "the refusal is not marked as one, so every automatic check an agent " <>
                 "might make — and the one the MCP protocol offers — says this went " <>
                 "fine. Got:\n#{context.text}"

        {:ok, context}
      end

      then_ "and not as a result the script returned", context do
        refute context.text =~ ~r/^Returned:/m,
               "the refusal is introduced with the same word a successful script's value " <>
                 "gets. The content is accurate and the frame is a lie, and the frame is " <>
                 "what gets read first."

        {:ok, context}
      end
    end
  end
end
