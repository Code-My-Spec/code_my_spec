defmodule CodeMySpecSpex.Story715.Criterion6307Spex do
  @moduledoc """
  Story 715 — Architect surveys the project
  Criterion 6307 — show_component_requirements lists requirements for a known component by module name.

  When a component exists with a known module name and the agent
  calls `show_component_requirements` with that module name, the
  response text names the component, reports a `done/total`
  satisfaction count, and lists every requirement on that component
  as a checklist line.

  Surface: `ShowComponentRequirements` MCP tool.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.ShowComponentRequirements

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Requirement-query tools resolve their reference and return requirement details or done/total summaries; an unknown reference returns a not-found error rather than crashing" do
    scenario "show_component_requirements lists requirements for a known component by module name" do
      given_ :synced_context_component

      when_ ~s|the agent calls show_component_requirements with module name "ExampleContext"|,
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ShowComponentRequirements.execute(%{component: "ExampleContext"}, frame)

        {:ok, Map.put(context, :body, response_text(response))}
      end

      then_ "the response names the component", context do
        assert context.body =~ ~r/^#\s+ExampleContext/m,
               "expected `# ExampleContext` header, got:\n#{context.body}"

        {:ok, context}
      end

      and_ "the response reports a done/total satisfaction count", context do
        assert context.body =~ ~r/\*\*Requirements:\*\*\s+\d+\/\d+\s+satisfied/,
               "expected `**Requirements:** N/M satisfied`, got:\n#{context.body}"

        {:ok, context}
      end

      and_ "every requirement on the component appears as a checklist line", context do
        assert context.body =~ ~r/^-\s+\[[ x]\]\s+\*\*[a-z_]+\*\*/m,
               "expected at least one checklist line for a requirement, got:\n#{context.body}"

        {:ok, context}
      end
    end
  end
end
