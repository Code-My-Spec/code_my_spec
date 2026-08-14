defmodule CodeMySpecSpex.Story984.Criterion2369Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 2369 — A call with no arguments offers nothing to expand.

  Some tools take none. The recorder stores those as a bare name with no
  newline and no payload, and a disclosure offering an empty body is a control
  that punishes the operator for using it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "An argumentless call has nothing to open" do
    scenario "A call with no arguments offers nothing to expand" do
      when_ "the agent calls a tool that takes no arguments", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("what is next"),
          Fixtures.model_response([Fixtures.tool_block("get_next_requirement", %{})])
        )

        {:ok, context}
      end

      then_ "it renders as a call naming that tool", context do
        {:ok, view, _html} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope))

        assert has_element?(view, "[data-test='tool-call'][data-tool='get_next_requirement']")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "no arguments disclosure is offered", context do
        refute has_element?(context.view, "[data-test='tool-call'] details"),
               "an empty disclosure is a control that does nothing when used"

        {:ok, context}
      end
    end
  end
end
