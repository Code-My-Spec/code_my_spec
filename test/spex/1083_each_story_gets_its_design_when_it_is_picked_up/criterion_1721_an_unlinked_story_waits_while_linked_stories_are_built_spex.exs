defmodule CodeMySpecSpex.Story1083.Criterion1721Spex do
  @moduledoc """
  Story 1083 — Each story gets its design when it is picked up
  Criterion 1721 — An unlinked story waits while linked stories are built.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An unlinked story waits while linked stories are built", criterion: 1721 do
    scenario "a linked story offers further work while an unlinked one offers only design" do
      given_ "Sam's story A is linked to a component and story B is not", context do
        app = context.project.module_name || "MyApp"

        component =
          ComponentHelpers.create(context.scope,
            name: "Billing",
            module_name: "#{app}Web.BillingLive",
            type: "liveview"
          )

        story_a =
          StoryHelpers.create_and_link(context.scope, component.module_name,
            title: "Story A — linked",
            description: "Already has a surface component",
            acceptance_criteria: ["Story A criterion"]
          )

        story_b =
          StoryHelpers.create_story(context.scope,
            title: "Story B — unlinked",
            description: "Has no surface component yet",
            acceptance_criteria: ["Story B criterion"]
          )

        {:ok, Map.merge(context, %{story_a: story_a, story_b: story_b})}
      end

      when_ "Sam's agents look for work on each story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response_a, _frame} =
          GetNextRequirement.execute(%{story_number: context.story_a.number}, frame)

        {:reply, response_b, _frame} =
          GetNextRequirement.execute(%{story_number: context.story_b.number}, frame)

        {:ok,
         Map.merge(context, %{
           offer_a: response_text(response_a),
           offer_b: response_text(response_b)
         })}
      end

      then_ "story A's work beyond design is offered", context do
        refute context.offer_a =~ "ArchitectureDesign",
               "linked story A should no longer be offered design work: #{inspect(context.offer_a)}"

        refute context.offer_a =~ "All requirements satisfied",
               "linked story A should still have further work offered: #{inspect(context.offer_a)}"

        {:ok, context}
      end

      then_ "story B is offered only design work", context do
        assert context.offer_b =~ "ArchitectureDesign",
               "unlinked story B should be offered design work: #{inspect(context.offer_b)}"

        {:ok, context}
      end
    end
  end
end
