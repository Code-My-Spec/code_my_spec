defmodule CodeMySpecSpex.Story70.Criterion1399Spex do
  @moduledoc """
  Story 70, criterion 1399: a proposal for entities the project no longer has
  is not an architectural plan for that project.

  This covers the proposal-only case. An authored component would itself be a
  plan under criterion 1641, regardless of the proposal's contents.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers, only: [architecture_designed: 1]

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A proposal for a project that no longer exists does not satisfy architecture_designed",
    criterion: 1399 do
    scenario "the proposal names a retired story and a context absent from the project" do
      given_ "a story was once in the project but has been retired", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Retired feature",
            description: "A feature that was removed",
            acceptance_criteria: ["It works"]
          )

        assert {:ok, reply} =
                 ToolLibrary.run(
                   "retire_story",
                   %{story_number: story.number},
                   %{scope: context.scope}
                 )

        assert reply =~ "retired"
        {:ok, Map.put(context, :retired_story, story)}
      end

      given_ "the proposal still names that story and a context the project no longer has",
             context do
        app = context.project.module_name || "MyApp"

        removed_context =
          ComponentHelpers.create(context.scope,
            name: "RemovedContext",
            module_name: "#{app}.RemovedContext",
            type: "context"
          )

        proposal = """
        # Architecture Proposal

        ## Surface Components

        ### #{app}Web.RetiredFeatureLive

        - **Type:** liveview
        - **Description:** Page for a retired feature
        - **Stories:** #{context.retired_story.number}

        ## Contexts

        ### #{app}.RemovedContext

        - **Type:** context
        - **Description:** Context no longer in this project

        ## Dependencies

        - #{app}Web.RetiredFeatureLive -> #{app}.RemovedContext
        """

        :ok =
          Fixtures.write_env_file(context.execution_context, Fixtures.proposal_path(), proposal)

        assert {:ok, _} = Fixtures.deliver_manifest(context.scope)

        assert {:ok, reply} =
                 ToolLibrary.run("delete_component", %{component_id: removed_context.id}, %{
                   scope: context.scope
                 })

        assert reply =~ "Deleted"
        {:ok, context}
      end

      when_ "the graph reports whether architecture is designed", context do
        {:ok, Map.put(context, :report, architecture_designed(context))}
      end

      then_ "the requirement is unsatisfied because the proposal is out of date",
            context do
        assert context.report =~ "**Status:** Not satisfied"
        assert context.report =~ ~r/out.of.date/i
        refute context.report =~ ~r/orphan/i
        {:ok, context}
      end
    end
  end
end
