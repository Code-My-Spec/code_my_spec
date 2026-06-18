defmodule CodeMySpecSpex.Story559.Criterion6544Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 6544 — The agent revises a Rule's statement through the
  `update_rule` MCP tool: the new wording surfaces in `list_rules` and
  the original wording no longer appears.

  Proves the rule mutation surface is symmetric with `add_rule` /
  `delete_rule` — the agent edits a persisted Rule record in place
  through the same domain API the UI uses, without recreating the rule
  or losing its linked scenarios.

  Depends on:
    - `UpdateRule` MCP tool at `CodeMySpec.McpServers.BddRules.Tools.UpdateRule`
    - `AddRule` / `ListRules` MCP tools ✓
    - `:persona_exists` shared given (story with a persona linked) ✓
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.ListRules
  alias CodeMySpec.McpServers.BddRules.Tools.UpdateRule

  @original "Suspended cards cannot be used for purchases"
  @revised "Suspended cards are declined at authorization"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "agent revises a rule's statement via update_rule" do
    scenario "the revised statement replaces the original in list_rules" do
      given_ :persona_exists

      given_ "a rule exists on the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AddRule.execute(
            %{story_id: context.story.id, statement: @original},
            frame
          )

        rule_id = extract_rule_id(response)

        {:ok, Map.put(context, :rule_id, rule_id)}
      end

      when_ "the agent calls update_rule with a new statement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          UpdateRule.execute(
            %{rule_id: context.rule_id, statement: @revised},
            frame
          )

        {:ok, Map.put(context, :update_response, response)}
      end

      then_ "the update response confirms the revised statement", context do
        refute context.update_response.isError == true,
               "expected a successful update, got #{inspect(context.update_response)}"

        body = response_text(context.update_response)

        assert body =~ @revised,
               "expected the revised statement in the update response, got #{inspect(body)}"

        {:ok, context}
      end

      then_ "list_rules surfaces the revised statement and drops the original", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, list_response, _frame} =
          ListRules.execute(%{story_id: context.story.id}, frame)

        body = response_text(list_response)

        assert body =~ @revised,
               "expected the revised statement in list_rules, got #{inspect(body)}"

        refute body =~ @original,
               "expected the original statement to be gone from list_rules, got #{inspect(body)}"

        {:ok, context}
      end
    end
  end

  defp extract_rule_id(response) do
    response
    |> response_text()
    |> then(fn text ->
      case Regex.run(~r/id: `([^`]+)`/, text) do
        [_, id] -> id
        _ -> flunk("could not extract rule id from add_rule response: #{inspect(text)}")
      end
    end)
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
