defmodule CodeMySpec.Agents.AnalysisReportRecipientsTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.AnalysisReport
  alias CodeMySpec.Agents.Mailbox
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    scope = full_scope_fixture()
    RecordingAgentTransport.listen(scope)

    {:ok, running} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "anthropic",
        role: :coding,
        status: :running,
        continuous: true,
        working_copy: "/tmp/analysis-running",
        working_copy_id: scope.active_working_copy_id
      })

    {:ok, stopped} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "anthropic",
        role: :coding,
        status: :stopped,
        continuous: true,
        working_copy: "/tmp/analysis-stopped",
        working_copy_id: scope.active_working_copy_id
      })

    AgentPresence.present(running)
    {:ok, _} = Mailbox.register(scope, running.id, "test-engine")

    %{scope: scope, running: running, stopped: stopped}
  end

  test "findings reach a running agent but do not fan out to a stopped agent", ctx do
    assert :ok =
             AnalysisReport.deliver(ctx.scope, "credo", [%{severity: :error, source: "credo"}])

    assert [_] = Mailbox.entries(ctx.scope, ctx.running.id)
    assert [] = Mailbox.entries(ctx.scope, ctx.stopped.id)
  end

  test "a stopped requester is not sent a completed or failed run", ctx do
    assert :ok = AnalysisReport.deliver(ctx.scope, "credo", [], ctx.stopped.id)

    assert :ok =
             AnalysisReport.deliver_failure(
               ctx.scope,
               "credo",
               "harness restarted",
               ctx.stopped.id
             )

    assert [] = Mailbox.entries(ctx.scope, ctx.stopped.id)
  end
end
