defmodule CodeMySpecSpex.Story559.Criterion5160Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5160 — When the agent calls `add_rule` on a story that has
  no personas linked, the MCP tool returns a validation error and the
  rule does not appear in the subsequent `list_rules` call for that
  story.

  Enforces Three Amigos rule "Persona linkage required" at the MCP
  boundary — protocol ordering is not just an agent-behavior
  convention, it's structurally rejected by the tool surface.

  DRAFT. Depends on:
    - `Rules` context with a `Rule` schema and a `create_rule` API that
      validates a `persona_stories` row exists for the target story.
    - `AddRule` MCP tool at `CodeMySpec.McpServers.Rules.Tools.AddRule`.
    - `ListRules` MCP tool at `CodeMySpec.McpServers.Rules.Tools.ListRules`.
    - Server-side and write-through stack for the new `Rules` context
      (Personas-pattern: RemoteClient, BootSync, RemoteSync,
      `:rules_implementation` config).
    - A `:story_without_personas` shared given that creates a story
      with no `persona_stories` rows. Could be inlined here via
      `StoryHelpers.create_story/2` if the shared given is overkill
      for one spec.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.ListRules
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "add_rule rejects on a story with no linked personas" do
    scenario "MCP tool returns a validation error and no rule is created" do
      given_ "a story exists with no personas linked", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Story with no persona",
            description: "Drives the persona-linkage rejection path.",
            acceptance_criteria: ["Persona linkage is enforced at add_rule"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      when_ "the agent calls add_rule on that story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AddRule.execute(
            %{
              story_id: context.story.id,
              statement: "Suspended cards cannot be used"
            },
            frame
          )

        {:ok, Map.put(context, :add_response, response)}
      end

      then_ "the MCP response surfaces a persona-linkage validation error", context do
        assert context.add_response.isError == true,
               "expected the response to be flagged as an error, got #{inspect(context.add_response)}"

        body = response_text(context.add_response)

        assert body =~ ~r/persona/i,
               "expected the error to mention persona linkage, got #{inspect(context.add_response)}"

        {:ok, context}
      end

      then_ "the rule does not appear in list_rules for the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, list_response, _frame} =
          ListRules.execute(
            %{story_id: context.story.id},
            frame
          )

        body = response_text(list_response)

        refute body =~ "Suspended cards cannot be used",
               "expected no rules on the story, got #{inspect(list_response)}"

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
