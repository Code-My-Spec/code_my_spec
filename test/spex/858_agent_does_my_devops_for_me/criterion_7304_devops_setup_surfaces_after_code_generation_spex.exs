defmodule CodeMySpecSpex.Story858.Criterion7304Spex do
  @moduledoc """
  Story 858 — Agent does my DevOps for me
  Criterion 7304 — DevOps setup surfaces after code generation.

  Once code generation has completed on a project, the requirement graph
  offers devops_setup as actionable — the one-time provisioning step
  slots into the serial project chain right after the app exists.

  Surface: `get_next_requirement` MCP tool over a project staged through
  code_generation.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.ProjectStateFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "DevOps setup surfaces after code generation" do
    scenario "with code generation complete, the graph offers devops_setup" do
      given_ "the project chain is satisfied through code generation", context do
        context =
          context
          |> ProjectStateFixtures.apply_project_setup_steps()
          |> ProjectStateFixtures.apply_technical_strategy()
          |> ProjectStateFixtures.apply_code_generation()

        {:ok, context}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, response_text(response))}
      end

      then_ "devops_setup is among the actionable requirements", context do
        assert context.response_text =~ "devops_setup",
               "expected devops_setup to surface once code generation is complete; got: #{context.response_text}"

        {:ok, context}
      end
    end
  end
end
