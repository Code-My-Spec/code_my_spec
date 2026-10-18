defmodule CodeMySpecSpex.Story599.Criterion1614Spex do
  @moduledoc """
  Story 599 — Issue Triage.
  Criterion 1614 — Product triages issues on a story wherever it is placed.

  a31f1cd6 step 4d. Product owns all triage and lives on the main copy, so an
  issue filed on a story a feature copy's team is building still reaches
  product. The story's verdict is read where it is placed; nothing is
  recomputed from the main copy's tree.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Product triages issues on a story wherever it is placed", criterion: 1614 do
    scenario "An issue on a story placed on a feature copy reaches product on the main copy" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a main checkout with the product agent on it", context do
        context = Slice.main_copy(context)
        product = Fixtures.running_agent(context.main_scope, role: "product", continuous: true)
        {:ok, Map.put(context, :product, product)}
      end

      given_ "a story the feature copy's team is building", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Refund policy",
            description: "A story placed on a feature copy",
            acceptance_criteria: ["The stated behavior is specified"]
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        context = Slice.staff(context)
        Slice.call(context, SetActiveStory, %{story_number: story.number})
        {:ok, Map.put(context, :story, story)}
      end

      given_ "an issue filed on that story, not yet triaged", context do
        filed =
          ToolLibrary.run(
            "create_issue",
            %{
              title: "Refunds round the wrong way",
              description: "Found while testing the refund path",
              severity: "high",
              story_number: context.story.number
            },
            %{scope: context.scope}
          )

        assert match?({:ok, _}, filed), response_text(filed)
        {:ok, context}
      end

      when_ "the product agent on the main copy starts triaging it", context do
        frame = %Frame{
          assigns: %{current_scope: context.main_scope, agent_id: context.product.id}
        }

        _next =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        started =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "story_issues_triaged",
              entity_type: "story",
              entity_id: to_string(context.story.number)
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :started, started)}
      end

      then_ "product holds the triage of that story", context do
        assert match?({:ok, _}, context.started),
               "product on the main copy could not triage a story placed elsewhere: " <>
                 response_text(context.started)

        assert response_text(context.started) =~ "Triage Issues — story #{context.story.number}"
        {:ok, context}
      end
    end
  end
end
