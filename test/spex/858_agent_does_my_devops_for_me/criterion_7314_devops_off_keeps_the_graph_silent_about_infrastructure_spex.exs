defmodule CodeMySpecSpex.Story858.Criterion7314Spex do
  @moduledoc """
  Story 858 — Agent does my DevOps for me
  Criterion 7314 — DevOps off keeps the graph silent about infrastructure.

  Some users don't want the harness deploying at all. With the project's
  DevOps level set to `:off`, neither `devops_setup` nor `deploy` is ever
  demanded — a project state that would otherwise be waiting on a deploy
  reads as done, and the user ships on their own terms.

  Surface: `get_next_requirement` MCP tool over a project that is fully
  satisfied EXCEPT its deploy — which DevOps-off must erase entirely.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "DevOps off keeps the graph silent about infrastructure" do
    scenario "a state that would demand a deploy reads done with DevOps off" do
      given_ "a project satisfied through QA with its deploy still pending", context do
        {:ok, FullSatisfactionFixtures.apply_without_deploy(context)}
      end

      given_ "Sam has turned DevOps off for the project", context do
        {:ok, _config} = Fixtures.update_project_configuration(context.scope, %{devops: :off})
        {:ok, context}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, response_text(response))}
      end

      then_ "no infrastructure work is demanded", context do
        refute context.response_text =~ "devops_setup",
               "expected devops_setup to vanish from the graph with DevOps off"

        refute context.response_text =~ ~r/\bdeploy\b/i,
               "expected no deploy requirement with DevOps off; got: #{context.response_text}"

        {:ok, context}
      end

      then_ "the project reads as complete", context do
        # Anchor: the response is the all-satisfied signal, not an empty
        # string — DevOps off erased the pending deploy rather than
        # leaving it dangling.
        assert context.response_text =~ ~r/all requirements satisfied|no actionable/i,
               "expected the all-done signal; got: #{context.response_text}"

        {:ok, context}
      end
    end
  end
end
