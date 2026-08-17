defmodule CodeMySpecSpex.Story559.Criterion5899Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5899 — `get_story_gherkin` renders a populated story as a
  plain-text Gherkin feature: Feature header, Rule blocks, Scenario
  titles, and Given/When/Then bodies, in the order rules and
  scenarios were created (`inserted_at`).

  This is the read surface downstream consumers (SexySpex generation,
  codegen, UI viewer) use — proves the deliverable can be assembled
  from the DB without any flat file on disk.

  Depends on:
    - `GetStoryGherkin` MCP tool (new)
    - `BddRules.list_rules_for_story` ✓
    - `AcceptanceCriteria.list_story_criteria` ✓
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.AddScenario
  alias CodeMySpec.McpServers.BddRules.Tools.GetStoryGherkin

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "get_story_gherkin renders the story as a plain-text feature" do
    scenario "feature output contains rule statements, scenario titles, and Given/When/Then bodies" do
      given_ :persona_exists

      given_ "two rules with happy + failure scenarios each", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        rules = [
          {"Suspended cards cannot be used for purchases",
           [
             {"happy_path", "Driver attempts purchase with suspended card",
              "Given the driver's card is suspended\nWhen the driver attempts a purchase\nThen the purchase is declined"},
             {"failure_path", "Suspension status fails to load",
              "Given the driver's card status cannot be retrieved\nWhen the driver attempts a purchase\nThen the purchase is declined for safety"}
           ]},
          {"Suspended drivers receive notification",
           [
             {"happy_path", "Driver receives SMS notification when suspended",
              "Given a driver is suspended\nWhen the suspension takes effect\nThen the driver receives an SMS notification"},
             {"failure_path", "Driver notification fails on invalid phone number",
              "Given a driver has an invalid phone number\nWhen the suspension takes effect\nThen the notification failure is logged"}
           ]}
        ]

        for {rule_statement, scenarios} <- rules do
          {:reply, _add_rule, _frame} =
            AddRule.execute(
              %{story_id: context.story.id, statement: rule_statement},
              frame
            )

          for {kind, title, body} <- scenarios do
            {:reply, _add_scenario, _frame} =
              AddScenario.execute(
                %{
                  story_id: context.story.id,
                  rule_statement: rule_statement,
                  title: title,
                  kind: kind,
                  body: body
                },
                frame
              )
          end
        end

        {:ok, context}
      end

      when_ "the agent calls get_story_gherkin", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          GetStoryGherkin.execute(%{story_id: context.story.id}, frame)

        {:ok, Map.put(context, :gherkin_response, response)}
      end

      then_ "the rendered feature contains the Feature header and the story title", context do
        body = response_text(context.gherkin_response)

        assert body =~ ~r/Feature:/,
               "expected Feature header in rendered Gherkin, got #{inspect(body)}"

        assert body =~ context.story.title,
               "expected story title in feature, got #{inspect(body)}"

        {:ok, context}
      end

      then_ "every rule statement appears as a `Rule:` block", context do
        body = response_text(context.gherkin_response)

        assert body =~ ~r/Rule:\s*Suspended cards cannot be used for purchases/,
               "expected first rule block, got #{inspect(body)}"

        assert body =~ ~r/Rule:\s*Suspended drivers receive notification/,
               "expected second rule block, got #{inspect(body)}"

        {:ok, context}
      end

      then_ "every scenario title and body is present", context do
        body = response_text(context.gherkin_response)

        for title <- [
              "Driver attempts purchase with suspended card",
              "Suspension status fails to load",
              "Driver receives SMS notification when suspended",
              "Driver notification fails on invalid phone number"
            ] do
          assert body =~ ~r/Scenario:\s*#{Regex.escape(title)}/,
                 "expected scenario `#{title}`, got #{inspect(body)}"
        end

        for fragment <- [
              "Given the driver's card is suspended",
              "When the driver attempts a purchase",
              "Then the purchase is declined",
              "Given a driver has an invalid phone number"
            ] do
          assert body =~ fragment,
                 "expected Gherkin body fragment `#{fragment}`, got #{inspect(body)}"
        end

        {:ok, context}
      end
    end
  end
end
