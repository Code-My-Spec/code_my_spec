defmodule CodeMySpecSpex.Story858.Criterion7307Spex do
  @moduledoc """
  Story 858 — Agent does my DevOps for me
  Criterion 7307 — A story that clears QA rides to UAT then prod.

  Once devops_setup is complete, deploys are part of the ongoing loop:
  with a story through QA, the graph offers a deploy requirement whose
  order of operations is UAT first, health-verified, then prod.

  Surface: `get_next_requirement` MCP tool over a fully satisfied story.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A story that clears QA rides to UAT then prod" do
    scenario "after QA passes, the loop's next work is the deploy" do
      given_ "devops setup is complete and a story has passed QA", context do
        {:ok, FullSatisfactionFixtures.apply_without_deploy(context)}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, response_text(response))}
      end

      then_ "the graph offers the deploy as next actionable work", context do
        assert context.response_text =~ ~r/deploy/i,
               "expected a deploy requirement to ride the loop after QA; got: #{context.response_text}"

        {:ok, context}
      end

      and_ "the deploy targets UAT and defers prod to the release process", context do
        # Story 859 amendment: per-story deploys stop at UAT; prod
        # promotion belongs to the cycle-end release.
        assert context.response_text =~ ~r/uat/i,
               "expected the deploy directive to target UAT"

        assert context.response_text =~ ~r/release process/i,
               "expected the directive to defer prod promotion to the release process"

        {:ok, context}
      end
    end
  end
end
