defmodule CodeMySpecWeb.AccountNotificationRecipientsTest do
  use CodeMySpecTest.ConnCase, async: true
  import Phoenix.LiveViewTest
  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures
  alias CodeMySpec.Notifications
  alias CodeMySpec.Repo

  setup do
    scope = full_scope_fixture()
    account = Repo.get!(CodeMySpec.Accounts.Account, scope.active_account_id)
    owner = user_fixture()
    admin = user_fixture()
    outsider = user_fixture()
    member_fixture(owner, account, :owner)
    member_fixture(admin, account, :admin)

    {:ok, agent} =
      CodeMySpec.Agents.AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "main",
        status: :running,
        working_copy: scope.cwd,
        working_copy_id: scope.active_working_copy_id
      })

    %{scope: scope, agent: agent, owner: owner, admin: admin, outsider: outsider}
  end

  defp connection(user), do: build_conn() |> log_in_user(user)

  defp assert_badge(view, count) do
    eventually(fn ->
      assert has_element?(view, "[data-test='notification-badge'][data-count='#{count}']")
    end)
  end

  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    fun.()
  rescue
    error in [ExUnit.AssertionError] ->
      retry(System.monotonic_time(:millisecond) < deadline, error, __STACKTRACE__, fun, deadline)
  end

  defp retry(true, _error, _stacktrace, fun, deadline) do
    Process.sleep(10)
    eventually(fun, deadline)
  end

  defp retry(false, error, stacktrace, _fun, _deadline), do: reraise(error, stacktrace)

  test "another owner answers and the admin sees the resolved request and answerer", ctx do
    {:ok, inbox, _} = live(connection(ctx.admin), "/app/notifications")

    {:ok, request} =
      Notifications.create_question_request(ctx.scope.user.id, %{
        "agent_id" => ctx.agent.id,
        "questions" => [%{"question" => "Ship the change?", "options" => []}]
      })

    assert render(inbox) =~ "Ship the change?"
    assert_badge(inbox, 1)
    {:ok, answer, _} = live(connection(ctx.owner), "/app/questions/#{request.id}")
    answer |> element("main form") |> render_submit(%{"q_0" => "Ship it"})
    updated = Notifications.get_question_request(request.id)
    assert updated.answered_by_user_id == ctx.owner.id
    assert updated.answers == %{"Ship the change?" => "Ship it"}
    assert inbox |> element("section", "Recent") |> render() =~ ctx.owner.email
    assert Notifications.count_pending_notifications(ctx.admin.id) == 0
    assert_badge(inbox, 0)

    assert {:error, {:already_resolved, "answered"}} =
             Notifications.answer_question_request(request.id, %{"Ship the change?" => "No"},
               answered_by_user_id: ctx.admin.id
             )

    assert Notifications.get_question_request(request.id).answered_by_user_id == ctx.owner.id
  end

  test "an admin approves and the owner sees that person's decision", ctx do
    {:ok, inbox, _} = live(connection(ctx.owner), "/app/notifications")

    {:ok, request} =
      Notifications.create_permission_request(ctx.scope.user.id, %{
        "agent_id" => ctx.agent.id,
        "tool_name" => "Bash",
        "tool_input" => %{"command" => "echo fixture"}
      })

    assert render(inbox) =~ "Bash needs your approval"
    assert_badge(inbox, 1)
    {:ok, approval, _} = live(connection(ctx.admin), "/app/permissions/#{request.id}")
    render_click(approval, "approve", %{"id" => request.id})
    updated = Notifications.get_permission_request(request.id)
    assert updated.status == "approved"
    assert updated.answered_by_user_id == ctx.admin.id
    assert inbox |> element("section", "Recent") |> render() =~ ctx.admin.email
    assert Notifications.count_pending_notifications(ctx.owner.id) == 0
    assert_badge(inbox, 0)

    assert {:error, {:already_resolved, "approved"}} =
             Notifications.resolve_permission_request(request.id, "deny", nil,
               answered_by_user_id: ctx.owner.id
             )

    assert Notifications.get_permission_request(request.id).answered_by_user_id == ctx.admin.id
  end

  test "plain members and outsiders cannot open agent requests even when stamped on the member",
       ctx do
    {:ok, question} =
      Notifications.create_question_request(ctx.scope.user.id, %{
        "agent_id" => ctx.agent.id,
        "questions" => [%{"question" => "Private fixture question?", "options" => []}]
      })

    {:ok, permission} =
      Notifications.create_permission_request(ctx.scope.user.id, %{
        "agent_id" => ctx.agent.id,
        "tool_name" => "Bash",
        "tool_input" => %{"command" => "private-fixture-command"}
      })

    for user <- [ctx.scope.user, ctx.outsider] do
      {:ok, _, question_html} = live(connection(user), "/app/questions/#{question.id}")
      refute question_html =~ "Private fixture question?"
      {:ok, _, permission_html} = live(connection(user), "/app/permissions/#{permission.id}")
      refute permission_html =~ "private-fixture-command"
      {:ok, _, inbox_html} = live(connection(user), "/app/notifications")
      refute inbox_html =~ "Private fixture question?"
      refute inbox_html =~ "private-fixture-command"
    end
  end
end
