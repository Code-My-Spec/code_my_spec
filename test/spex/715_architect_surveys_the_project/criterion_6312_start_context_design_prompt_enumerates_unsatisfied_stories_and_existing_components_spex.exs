defmodule CodeMySpecSpex.Story715.Criterion6312Spex do
  @moduledoc """
  Story 715 — Architect surveys the project
  Criterion 6312 — start_context_design prompt enumerates unsatisfied stories and existing components.

  When the project has at least one unsatisfied story (no linked
  component) and at least one existing component, `start_context_design`
  returns a prompt that:
    1. Lists the unsatisfied story's title under "Unsatisfied User Stories".
    2. Lists the existing component's name under "Existing Components".
    3. Frames the agent as an Elixir architect specializing in
       Phoenix contexts.

  Surface: `StartContextDesign` MCP tool.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.StartContextDesign
  alias CodeMySpecSpex.StoryHelpers

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "start_context_design returns a design-conversation prompt enumerating unsatisfied stories and existing components" do
    scenario "start_context_design prompt enumerates unsatisfied stories and existing components" do
      given_ :synced_context_component

      given_ "an unsatisfied story exists with no linked component", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Architect designs a new domain",
            description: "I want to spec a new bounded context for inventory.",
            acceptance_criteria: ["Inventory context exists"]
          )

        {:ok, Map.put(context, :unsatisfied_story, story)}
      end

      when_ "the agent calls start_context_design", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = StartContextDesign.execute(%{}, frame)
        {:ok, Map.put(context, :body, response_text(response))}
      end

      then_ "the prompt lists the unsatisfied story's title under Unsatisfied User Stories",
            context do
        assert context.body =~ "Unsatisfied User Stories",
               "expected `Unsatisfied User Stories` section, got:\n#{context.body}"

        assert context.body =~ context.unsatisfied_story.title,
               "expected unsatisfied story title in prompt, got:\n#{context.body}"

        {:ok, context}
      end

      and_ "the prompt lists the existing component's name under Existing Components", context do
        assert context.body =~ "Existing Components",
               "expected `Existing Components` section, got:\n#{context.body}"

        assert context.body =~ "ExampleContext",
               "expected ExampleContext in prompt, got:\n#{context.body}"

        {:ok, context}
      end

      and_ "the prompt frames the agent as an Elixir architect for Phoenix contexts",
           context do
        assert context.body =~ ~r/Elixir architect/i,
               "expected `Elixir architect` framing, got:\n#{context.body}"

        assert context.body =~ ~r/Phoenix contexts/i,
               "expected `Phoenix contexts` framing, got:\n#{context.body}"

        {:ok, context}
      end
    end
  end
end
