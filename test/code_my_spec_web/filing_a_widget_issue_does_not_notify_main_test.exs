defmodule CodeMySpecWeb.FilingAWidgetIssueDoesNotNotifyMainTest do
  @moduledoc """
  Criterion 1755: filing an issue does not notify main; a new issue reaches
  main as triage work through the graph.

  Both widget doors used to message main (`WidgetIssueNotice`, 6da8e0e5). The
  issue now reaches the fleet as `issues_triaged`, product's requirement.
  """
  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.ChannelTest
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.IssuesChecker
  alias CodeMySpec.Staffing
  alias CodeMySpecTest.RecordingAgentTransport

  @deploy_key :crypto.strong_rand_bytes(64) |> Base.encode16(case: :lower)

  setup %{conn: conn} do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    scope = full_scope_fixture(%{deploy_key: @deploy_key})
    {:ok, _copy} = Staffing.designate_main(scope, scope.active_working_copy_id)

    {:ok, main} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: :main,
        status: :running,
        continuous: true,
        working_copy: "/tmp/widget-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    {:ok, _} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        main.id
      )

    %{conn: put_req_header(conn, "accept", "application/json"), scope: scope, main: main}
  end

  defp await_dispatches do
    CodeMySpec.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref -> assert_receive {:DOWN, ^ref, _, _, _}, 5_000 end)
  end

  defp assert_main_told_nothing_and_triage_is_owed(%{scope: scope, main: %{id: main_id}}) do
    await_dispatches()
    refute_received {:agent_message, ^main_id, _}
    refute_received {:agent_dispatch, ^main_id, _, _}

    assert {false, _} = IssuesChecker.triaged?(scope, nil)
    assert Requirements.offered_to?(:product, "issues_triaged")
    refute Requirements.offered_to?(:main, "issues_triaged")
  end

  test "an issue filed over the widget API sends main nothing", ctx do
    conn =
      ctx.conn
      |> put_req_header("authorization", "Bearer #{@deploy_key}")
      |> post(~p"/api/widget/issues", %{
        "issue" => %{"title" => "the help page is missing", "description" => "404"}
      })

    assert %{"data" => _issue} = json_response(conn, 201)
    assert_main_told_nothing_and_triage_is_owed(ctx)
  end

  test "an issue filed over the widget channel sends main nothing", ctx do
    {:ok, _reply, channel} =
      CodeMySpecWeb.WidgetSocket
      |> socket("widget:eu-1", %{
        project_id: ctx.scope.active_project_id,
        end_user_id: "eu-1",
        end_user_email: "user@example.com"
      })
      |> subscribe_and_join(CodeMySpecWeb.ConversationChannel, "conversation:eu-1", %{})

    ref =
      Phoenix.ChannelTest.push(channel, "submit_feedback", %{
        "title" => "Save button does nothing",
        "description" => "Clicking Save is a no-op",
        "severity" => "medium"
      })

    reply =
      receive do
        %Phoenix.Socket.Reply{ref: ^ref} = reply -> reply
      end

    assert %Phoenix.Socket.Reply{status: :ok, payload: %{id: _issue_id}} = reply
    assert_main_told_nothing_and_triage_is_owed(ctx)
  end
end
