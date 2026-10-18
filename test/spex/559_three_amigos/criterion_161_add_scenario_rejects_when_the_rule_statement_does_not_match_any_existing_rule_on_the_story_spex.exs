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

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "add_scenario rejects when rule_statement does not match any rule on the story",
    criterion: 161 do
    scenario "MCP tool returns an error naming the rule lookup failure" do
      given_ :persona_exists

      given_ "one rule exists on the story with a known statement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        _add_rule =
          ToolLibrary.run(
            "add_rule",
            %{
              story_number: context.story.number,
              statement: "The exactly known rule statement"
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, context}
      end

      when_ "the agent calls add_scenario with a non-matching rule_statement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "add_scenario",
            %{
              story_number: context.story.number,
              rule_statement: "Some rule that was never added",
              title: "Should not be created",
              kind: "happy_path",
              body: "Given...\nWhen...\nThen..."
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :add_response, response)}
      end

      then_ "the MCP response is flagged as an error and mentions the rule lookup",
            context do
        assert match?({:error, _}, context.add_response),
               "expected the response to be flagged as an error, got #{inspect(context.add_response)}"

        body = response_text(context.add_response)

        assert body =~ ~r/rule/i,
               "expected the error to mention the rule lookup, got #{inspect(context.add_response)}"

        {:ok, context}
      end
    end
  end
end
