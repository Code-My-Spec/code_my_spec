defmodule CodeMySpecSpex.Story859.Criterion7316Spex do
  @moduledoc """
  Story 859 — Formal release process
  Criterion 7316 — The release waits for the journeys.

  A prod release happens at the end of the cycle, only after the user
  journeys are complete and updated: with the project chain satisfied up
  to (but not including) the journey artifacts, the graph never offers
  the release.

  Surface: `get_next_requirement` MCP tool over a project staged through
  qa_setup with no journey artifacts.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The release waits for the journeys" do
    scenario "release is not offered while the journey chain is unsatisfied" do
      given_ "the project chain is satisfied up to the journeys, which are not", context do
        context =
          context
          |> ProjectStateFixtures.apply_project_setup_steps()
          |> ProjectStateFixtures.apply_technical_strategy()
          |> ProjectStateFixtures.apply_code_generation()
          |> ProjectStateFixtures.apply_qa_integration_plan()
          |> ProjectStateFixtures.apply_devops_setup()
          |> ProjectStateFixtures.apply_architecture()
          |> ProjectStateFixtures.apply_spex_boundary_ready()
          |> ProjectStateFixtures.apply_qa_setup()
          |> ProjectStateFixtures.apply_persona()

        _story =
          StoryHelpers.create_story(context.scope,
            title: "Seed story",
            description: "As a user, I want the app to exist."
          )

        {:ok, context}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, response_text(response))}
      end

      then_ "the release is not among the offered work", context do
        # Anchor: something IS actionable (the response renders directives),
        # it just isn't the release.
        assert context.response_text =~ ~r/\S/,
               "expected actionable work to render"

        refute context.response_text =~ ~r/\brelease\b/i,
               "expected no prod release offered while the journeys are incomplete; got: #{context.response_text}"

        {:ok, context}
      end
    end
  end
end
