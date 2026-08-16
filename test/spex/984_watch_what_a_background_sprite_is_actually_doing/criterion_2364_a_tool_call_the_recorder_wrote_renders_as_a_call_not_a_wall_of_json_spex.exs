defmodule CodeMySpecSpex.Story984.Criterion2364Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 2364 — A tool call the recorder wrote renders as a call, not a wall
  of JSON.

  The recorder stores a call as `"<tool>\\n<json arguments>"` in one text field.
  Rendered whole, a `Write` of a source file became several thousand characters
  of escaped JSON with no line breaks, and the turns either side of it were
  pushed off the screen. The name is the part read every time; the arguments are
  read occasionally and belong behind a disclosure.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A recorded call names its tool" do
    scenario "A tool call the recorder wrote renders as a call, not a wall of JSON" do
      when_ "the agent calls a tool with arguments", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("run the spex suite"),
          Fixtures.model_response([
            Fixtures.tool_block("Bash", %{"command" => "mix spex --stale"})
          ])
        )

        {:ok, context}
      end

      then_ "it renders as a call naming that tool", context do
        {:ok, view, html} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope))

        assert has_element?(view, "[data-test='tool-call'][data-tool='Bash']"),
               "the tool's name is the thing an operator scans for"

        assert html =~ "mix spex --stale",
               "the arguments still have to be reachable — Bash says a command ran, " <>
                 "the arguments say which"

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the name is not fused to its payload", context do
        refute context.html =~ "Bash\n{",
               "rendering the stored string whole is what made this unreadable"

        {:ok, context}
      end
    end
  end
end
