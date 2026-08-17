defmodule CodeMySpecSpex.Story715.Criterion6309Spex do
  @moduledoc """
  Story 715 — Architect surveys the project
  Criterion 6309 — Unknown requirement/component/story reference returns a not-found error.

  When no component exists with module name "DoesNotExist.Module"
  and the agent calls `show_component_requirements` with that
  module name, the response is an error whose message names the
  missing reference and includes "not found".

  Surface: `ShowComponentRequirements` MCP tool — representative of
  the failure path shared by all three requirement-query tools
  (show_requirement, show_component_requirements, show_story_requirements).
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.ShowComponentRequirements

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Requirement-query tools resolve their reference and return requirement details or done/total summaries; an unknown reference returns a not-found error rather than crashing" do
    scenario "Unknown requirement/component/story reference returns a not-found error" do
      given_ "no component exists with module name `DoesNotExist.Module`", context do
        {:ok, context}
      end

      when_ "the agent calls show_component_requirements with `DoesNotExist.Module`", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ShowComponentRequirements.execute(%{component: "DoesNotExist.Module"}, frame)

        {:ok, Map.put(context, :body, response_text(response))}
      end

      then_ "the response message names the missing reference", context do
        assert context.body =~ "DoesNotExist.Module",
               "expected error to name the missing reference, got:\n#{context.body}"

        {:ok, context}
      end

      and_ ~s|the response message includes "not found"|, context do
        assert context.body =~ ~r/not found/i,
               "expected `not found` in error message, got:\n#{context.body}"

        {:ok, context}
      end
    end
  end
end
