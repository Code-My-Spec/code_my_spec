defmodule CodeMySpec.AnalysisDashboardFixtures do
  @moduledoc "Fixture for the analysis dashboard's two-copy, three-execution view."

  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.DevicesFixtures
  alias CodeMySpec.WorkingCopies

  @doc "Create two copies and their in-flight run records."
  def two_copies_in_flight(scope) do
    device = DevicesFixtures.device_fixture(scope)
    {:ok, team} = WorkingCopies.issue(scope, nil, label: "team B", device: device)
    {:ok, team} = WorkingCopies.report_root(team, "/workspace/team-b")
    {:ok, security} = WorkingCopies.issue(scope, nil, label: "security", device: device)
    {:ok, security} = WorkingCopies.report_root(security, "/workspace/security")

    team_scope = %{scope | active_working_copy_id: team.id}
    security_scope = %{scope | active_working_copy_id: security.id}
    spex = AnalysisFixtures.analysis_run_fixture(team_scope, %{source: "spex"})
    agent_request = AnalysisFixtures.analysis_run_fixture(team_scope, %{source: "spex"})
    exunit = AnalysisFixtures.analysis_run_fixture(security_scope, %{source: "exunit"})
    credo = AnalysisFixtures.analysis_run_fixture(security_scope, %{source: "credo"})

    %{
      team: team,
      security: security,
      spex: spex,
      agent_request: agent_request,
      exunit: exunit,
      credo: credo
    }
  end

  @doc "Serve the local harness dashboard response without contacting the host harness."
  def stub_harness(runs) do
    module = CodeMySpecWeb.DevAnalysisLive
    previous = Application.get_env(:code_my_spec, module)
    Application.put_env(:code_my_spec, module, plug: {Req.Test, module})

    Req.Test.stub(module, fn conn ->
      Req.Test.json(conn, %{
        projects: [
          %{
            root: runs.team.root,
            queue: %{
              running: %{
                source: "spex",
                run_id: runs.spex.id,
                tied_run_ids: [runs.agent_request.id]
              },
              queued: []
            }
          },
          %{
            root: runs.security.root,
            queue: %{
              running: %{source: "exunit", run_id: runs.exunit.id, tied_run_ids: []},
              queued: [%{source: "credo", run_id: runs.credo.id, tied_run_ids: []}]
            }
          }
        ]
      })
    end)

    fn ->
      if previous,
        do: Application.put_env(:code_my_spec, module, previous),
        else: Application.delete_env(:code_my_spec, module)
    end
  end
end
