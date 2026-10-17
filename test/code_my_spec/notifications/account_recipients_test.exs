defmodule CodeMySpec.Notifications.AccountRecipientsTest do
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.Accounts.Member
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Notifications
  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures

  setup do
    scope = full_scope_fixture()
    account = Repo.get!(CodeMySpec.Accounts.Account, scope.active_account_id)

    Repo.get_by!(Member, user_id: scope.user.id, account_id: account.id)
    |> Member.update_role_changeset(%{role: :owner})
    |> Repo.update!()

    owner = user_fixture()
    admin = user_fixture()
    member = user_fixture()
    outsider = user_fixture()
    member_fixture(owner, account, :owner)
    member_fixture(admin, account, :admin)
    member_fixture(member, account, :member)
    account_with_owner_fixture(outsider)

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "main",
        continuous: true,
        status: :running,
        working_copy: scope.cwd,
        working_copy_id: scope.active_working_copy_id
      })

    :meck.new(WebPushElixir, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(WebPushElixir) end)
    :meck.expect(WebPushElixir, :send_notification, fn _, _ -> {:ok, %{}} end)

    for user <- [scope.user, owner, admin, member, outsider] do
      {:ok, _} =
        Notifications.subscribe(user.id, %{
          "endpoint" => endpoint(user),
          "p256dh_key" => "fixture",
          "auth_key" => "fixture"
        })
    end

    %{
      scope: scope,
      agent: agent,
      recipients: [scope.user, owner, admin],
      excluded: [member, outsider],
      member: member
    }
  end

  defp endpoint(user), do: "https://push.invalid/#{user.id}"

  defp assert_delivery(ctx, request) do
    for user <- ctx.recipients do
      assert Notifications.recipient?(request, user.id)
      assert Enum.map(Notifications.list_pending_notifications(user.id), & &1.id) == [request.id]
      assert Notifications.count_pending_notifications(user.id) == 1
    end

    for user <- ctx.excluded do
      refute Notifications.recipient?(request, user.id)
      assert Notifications.list_notifications(user.id) == []
      assert Notifications.count_pending_notifications(user.id) == 0
    end

    endpoints =
      for {_, {WebPushElixir, :send_notification, [subscription, _]}, _} <-
            :meck.history(WebPushElixir),
          do: Jason.decode!(subscription)["endpoint"]

    assert Enum.sort(endpoints) == Enum.sort(Enum.map(ctx.recipients, &endpoint/1))
  end

  defp assert_resolved(ctx, request) do
    for user <- ctx.recipients do
      assert Notifications.list_pending_notifications(user.id) == []
      assert Notifications.count_pending_notifications(user.id) == 0
      assert Enum.map(Notifications.list_resolved_notifications(user.id), & &1.id) == [request.id]
    end

    for user <- ctx.excluded do
      assert Notifications.list_resolved_notifications(user.id) == []
    end
  end

  test "agent questions reach owners and admins even when stamped with a plain member", ctx do
    {:ok, request} =
      Notifications.create_question_request(ctx.member.id, %{
        "agent_id" => ctx.agent.id,
        "questions" => [%{"question" => "Proceed?", "options" => []}]
      })

    assert_delivery(ctx, request)

    for user <- ctx.recipients do
      assert Enum.map(Notifications.list_pending_question_requests_for_user(user.id), & &1.id) ==
               [request.id]
    end

    for user <- ctx.excluded do
      assert Notifications.list_pending_question_requests_for_user(user.id) == []
    end

    assert {:ok, _} = Notifications.answer_question_request(request.id, %{"Proceed?" => "yes"})
    assert_resolved(ctx, request)

    assert {:error, {:already_resolved, "answered"}} =
             Notifications.answer_question_request(request.id, %{"Proceed?" => "no"})

    assert Notifications.get_question_request(request.id).answers == %{"Proceed?" => "yes"}
  end

  test "permission requests reach the same recipients and only resolve once", ctx do
    {:ok, request} =
      Notifications.create_permission_request(ctx.member.id, %{
        "agent_id" => ctx.agent.id,
        "tool_name" => "Bash",
        "tool_input" => %{}
      })

    assert_delivery(ctx, request)
    assert {:ok, _} = Notifications.resolve_permission_request(request.id, "allow")
    assert_resolved(ctx, request)

    assert {:error, {:already_resolved, "approved"}} =
             Notifications.resolve_permission_request(request.id, "deny")
  end

  test "concurrent recipient decisions apply and broadcast only once", ctx do
    {:ok, request} =
      Notifications.create_permission_request(ctx.member.id, %{
        "agent_id" => ctx.agent.id,
        "tool_name" => "Bash",
        "tool_input" => %{}
      })

    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "permission_request:#{request.id}")
    [_, owner, admin] = ctx.recipients

    results =
      [{owner.id, "allow"}, {admin.id, "deny"}]
      |> Task.async_stream(fn {user_id, decision} ->
        Notifications.resolve_permission_request(request.id, decision, nil,
          answered_by_user_id: user_id
        )
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))

    assert [{:error, {:already_resolved, status}}] =
             Enum.filter(results, &match?({:error, _}, &1))

    assert status == winner.status
    persisted = Notifications.get_permission_request(request.id)
    assert persisted.decision == winner.decision
    assert persisted.answered_by_user_id == winner.answered_by_user_id
    assert_receive {:permission_decided, %{id: id, decision: decision}}
    assert id == request.id
    assert decision == winner.decision
    refute_receive {:permission_decided, _}
  end

  test "main agent tap-outs reach all recipients and approval stops the loop once", ctx do
    assert {:ok, request} = Notifications.request_agent_tap_out(ctx.scope, ctx.agent.id, nil)
    assert_delivery(ctx, request)
    admin = List.last(ctx.recipients)

    assert {:ok, resolved} =
             Notifications.resolve_permission_request(request.id, "allow", nil,
               answered_by_user_id: admin.id
             )

    assert resolved.answered_by_user_id == admin.id
    assert_resolved(ctx, request)
    refute Repo.get!(CodeMySpec.Agents.Agent, ctx.agent.id).continuous

    assert {:error, {:already_resolved, "approved"}} =
             Notifications.resolve_permission_request(request.id, "deny")

    refute Repo.get!(CodeMySpec.Agents.Agent, ctx.agent.id).continuous
  end
end
