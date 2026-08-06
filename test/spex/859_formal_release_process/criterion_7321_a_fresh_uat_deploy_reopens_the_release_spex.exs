defmodule CodeMySpecSpex.Story859.Criterion7321Spex do
  @moduledoc """
  Story 859 — Formal release process
  Criterion 7321 — A fresh UAT deploy reopens the release.

  Recurrence is content-based: with the last release covering every UAT
  deploy the project reads done, and the moment a new story lands on UAT
  the release requirement reads unsatisfied again — every cycle ends with
  another prod release.

  Surface: `get_next_requirement` MCP tool over a fully released project,
  before and after a new deploy record lands.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A fresh UAT deploy reopens the release" do
    scenario "a covered project reads done until a new deploy lands" do
      given_ "the last release covers every UAT deploy", context do
        {:ok, FullSatisfactionFixtures.apply(context)}
      end

      then_ "the project reads as complete", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        text = response_text(response)

        assert text =~ ~r/all requirements satisfied|no actionable/i,
               "expected the all-done signal while the release covers every deploy; got: #{text}"

        {:ok, context}
      end

      when_ "a new story clears QA and lands on UAT", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/devops/deploys/story_999999.md",
            """
            # Deploy — story 999999

            - Version: def456
            - UAT health check: verified (200 over TLS)
            """
          )

        {:ok, context}
      end

      then_ "the release requirement reopens", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        text = response_text(response)

        assert text =~ ~r/\brelease\b/i,
               "expected the release to reopen after a fresh UAT deploy; got: #{text}"

        {:ok, context}
      end
    end
  end
end
