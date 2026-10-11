defmodule CodeMySpecSpex.Story1059.Criterion2118Spex do
  @moduledoc "Requirement progress agrees with the full project graph"
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.CompactCadenceHelpers, as: Compact
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  alias CodeMySpecSpex.ProjectStateFixtures
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok = Fixtures.install_recording_agent_transport()
    Ecto.Adapters.SQL.Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Requirement progress agrees with the full project graph", criterion: 2118 do
    scenario "Requirement progress agrees with the full project graph" do
      given_ "the project has recorded kickoff requirements", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      when_ "main asks for a check-in", context do
        {:ok, Compact.report(context)}
      end

      then_ "the report agrees with the unfiltered project summary without listing nodes",
            context do
        {:ok, groups} = ListRequirements.script_result(%{summary: true}, Compact.frame(context))
        total = Enum.sum(Enum.map(groups, & &1["count"]))
        failing = Enum.sum(Enum.map(groups, & &1["locally_failing"]))
        assert total > 0
        assert context.report =~ "Requirements: #{total - failing}/#{total} satisfied"
        assert context.report =~ "list_requirements({status = \"unsatisfied\", summary = true})"
        assert byte_size(context.report) < 700
        {:ok, context}
      end
    end
  end
end
