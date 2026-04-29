defmodule CodeMySpecSpex.Story561.Criterion5625Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5625 — A fully-satisfied project returns an empty
  actionable list.

  Surface: get_next_requirement MCP tool.

  Setup composes the `:fully_satisfied_project` shared given which
  uses every existing bridge fixture (SetupFixtures,
  TechnicalStrategyFixtures, CodeGenerationFixtures,
  QaIntegrationPlanFixtures, ArchitectureFixtures) plus MCP-driven
  persona/story/rule creation to land the project in a fully-green
  state. The response should NOT advertise any start_task call —
  the documented empty-state message ("All requirements satisfied"
  or equivalent) is what surfaces.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Fully-satisfied project returns no actionable items" do
    scenario "the response is the documented all-satisfied empty state" do
      given_ :fully_satisfied_project

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the response carries no start_task call signatures",
            context do
        refute context.response_text =~ ~r/start_task/,
               "expected no start_task references in a fully-satisfied response, got: #{context.response_text}"

        {:ok, context}
      end

      and_ "the response is the documented all-satisfied message",
           context do
        assert context.response_text =~ "All requirements satisfied",
               "expected the all-satisfied message, got: #{context.response_text}"

        {:ok, context}
      end
    end
  end
end
