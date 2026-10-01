defmodule CodeMySpecWeb.WidgetIssueNoticeTest do
  @moduledoc """
  6da8e0e5: John filed an issue from the widget and asked main to fix it, and
  main never found it. Main is now told the id as the issue is filed.
  """
  use CodeMySpecSpex.Case, async: false

  import CodeMySpec.IssuesFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Staffing
  alias CodeMySpecTest.RecordingAgentTransport
  alias CodeMySpecWeb.WidgetIssueNotice

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    {:ok, _copy} = Staffing.designate_main(ctx.scope, ctx.scope.active_working_copy_id)
    :ok
  end

  defp agent(scope, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "claude-code",
        engine: :alloy,
        role: role,
        status: :running,
        # Step 4b: a non-continuous main is woken only by a person and its own
        # replies, so a widget issue reaches a continuous one.
        continuous: true,
        working_copy: "/tmp/widget-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    agent
  end

  test "main is told the new issue's id", %{scope: scope} do
    main = agent(scope, "main")
    issue = issue_fixture(scope, %{title: "the help page is missing"})

    WidgetIssueNotice.send(scope.active_account_id, scope.active_project_id, issue)

    main_id = main.id
    assert_receive {:agent_message, ^main_id, notice}, 2_000
    assert notice =~ issue.id
    assert notice =~ "the help page is missing"
  end

  test "with no main agent running, nothing is sent", %{scope: scope} do
    agent(scope, "coding")
    issue = issue_fixture(scope)

    assert :ok = WidgetIssueNotice.send(scope.active_account_id, scope.active_project_id, issue)
    refute_receive {:agent_message, _, _}, 300
  end
end
