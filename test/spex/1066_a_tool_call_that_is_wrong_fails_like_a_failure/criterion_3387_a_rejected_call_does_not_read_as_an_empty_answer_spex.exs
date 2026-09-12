defmodule CodeMySpecSpex.Story1066.Criterion3387Spex do
  @moduledoc """
  Story 1066 — A tool call that is wrong fails like a failure
  Criterion 3387 — A rejected call does not read as an empty answer.

  The rule:

  > A call that was malformed and a call that found nothing never look the same.

  ## The confusion this pins

  The pair to criterion 3386. That one asserts an empty answer still reads as
  an answer; this one asserts a rejection cannot borrow its appearance.

  What made the original mistake possible was that both arrive as a returned
  value and both are short. `[null, {"message": "..."}]` and an empty list are
  two lines apart on a screen, and an agent scanning for "did that work" sees
  neither a raise nor a result and infers the gentler of the two.

  The assertion is therefore not "the message exists" — it did exist — but that
  a reader can tell *which of the two things* happened without parsing prose.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A rejected call does not read as an empty answer" do
    scenario "a script calls a tool with an argument of the wrong type" do
      given_ "a script that passes a string where an integer is wanted", context do
        {:ok, Map.put(context, :script, ~s|return list_rules({ story_id = "966" })|)}
      end

      when_ "the agent reads the result", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = RunScript.execute(%{script: context.script}, frame)

        {:ok, context |> Map.put(:response, response) |> Map.put(:text, response_text(response))}
      end

      then_ "it can tell the call was rejected", context do
        assert context.response.isError,
               "the call was rejected and came back marked as a result. That is the " <>
                 "whole defect: `[null, {message}]` returned as the script's own value " <>
                 "reads like a tool that found nothing. Got:\n#{context.text}"

        {:ok, context}
      end

      then_ "and it cannot mistake it for the tool having answered with nothing", context do
        refute context.text =~ ~r/^Returned:/m,
               "the rejection is presented under the same heading a successful script " <>
                 "gets. An agent scanning for whether the call worked sees the word it " <>
                 "expects from a call that did."

        {:ok, context}
      end
    end
  end
end
