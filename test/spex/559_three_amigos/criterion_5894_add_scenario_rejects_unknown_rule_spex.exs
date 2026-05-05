defmodule CodeMySpecSpex.Story559.Criterion5894Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5894 — When `add_scenario` is called with a `rule_statement`
  that doesn't match any existing Rule on the story, the MCP tool
  returns an error response naming "rule" so the agent can correct
  course (e.g., add the rule first or fix the statement typo).

  Covers Rule 7 (validation errors at the MCP boundary) and the
  protocol-ordering principle (scenarios cannot exist without their
  parent rule).

  Depends on:
    - `AddScenario` MCP tool ✓
    - `BddRules.list_rules_for_story` ✓
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.AddScenario

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "add_scenario rejects when rule_statement does not match any rule on the story" do
    scenario "MCP tool returns an error naming the rule lookup failure" do
      given_ :persona_exists

      given_ "one rule exists on the story with a known statement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _add_rule, _frame} =
          AddRule.execute(
            %{
              story_id: context.story.id,
              statement: "The exactly known rule statement"
            },
            frame
          )

        {:ok, context}
      end

      when_ "the agent calls add_scenario with a non-matching rule_statement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AddScenario.execute(
            %{
              story_id: context.story.id,
              rule_statement: "Some rule that was never added",
              title: "Should not be created",
              kind: "happy_path",
              body: "Given...\nWhen...\nThen..."
            },
            frame
          )

        {:ok, Map.put(context, :add_response, response)}
      end

      then_ "the MCP response is flagged as an error and mentions the rule lookup",
            context do
        assert context.add_response.isError == true,
               "expected the response to be flagged as an error, got #{inspect(context.add_response)}"

        body = response_text(context.add_response)

        assert body =~ ~r/rule/i,
               "expected the error to mention the rule lookup, got #{inspect(context.add_response)}"

        {:ok, context}
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: text} -> text
      %{"text" => text} -> text
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
