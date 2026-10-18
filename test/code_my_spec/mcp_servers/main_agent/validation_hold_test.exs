defmodule CodeMySpec.McpServers.MainAgent.Tools.ValidationHoldTest do
  @moduledoc "`validation_hold`, through `execute/2`: main-only access and action dispatch."
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Analysis.ValidationHolds
  alias CodeMySpec.McpServers.MainAgent.Tools.ValidationHold

  setup do
    scope = full_scope_fixture()

    {:ok, working_copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        device: CodeMySpec.DevicesFixtures.device_fixture(scope)
      )

    copy = working_copy.id
    scope = %{scope | active_working_copy_id: copy}
    main = agent(scope, :main)
    next = agent(scope, :coding)

    %{scope: scope, copy: copy, main: main, next: next}
  end

  defp agent(scope, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/validation-hold-#{role}-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id,
        role: role,
        status: :running
      })

    agent
  end

  defp call(scope, caller, params) do
    frame = %Frame{assigns: %{current_scope: scope, agent_id: caller.id}}
    {:reply, response, _frame} = ValidationHold.execute(params, frame)
    protocol = Response.to_protocol(response)
    {protocol["isError"], protocol["content"] |> hd() |> Map.fetch!("text")}
  end

  test "a non-main agent is refused regardless of action", ctx do
    {true, text} = call(ctx.scope, ctx.next, %{action: "list"})
    assert text =~ "Only this project's main agent may manage validation holds."
  end

  test "main creates, authorizes, lists and releases a hold through the tool", ctx do
    {false, created} =
      call(ctx.scope, ctx.main, %{
        action: "create",
        reason: "Serial regression after recovery",
        affected_copy_ids: [ctx.copy],
        next_agent_id: ctx.next.id
      })

    assert created =~ "held"
    assert created =~ ctx.main.id
    [hold] = ValidationHolds.list(ctx.scope)
    assert hold.reason == "Serial regression after recovery"

    {false, authorized} =
      call(ctx.scope, ctx.main, %{
        action: "authorize",
        hold_id: hold.id,
        authorized_copy_id: ctx.copy,
        source: "exunit",
        args: ["test/corrected_test.exs"],
        next_agent_id: ctx.next.id
      })

    assert authorized =~ "authorized"

    {false, listed} = call(ctx.scope, ctx.main, %{action: "list"})
    assert listed =~ hold.id

    {false, released} = call(ctx.scope, ctx.main, %{action: "release", hold_id: hold.id})
    assert released =~ "released"
  end

  test "an invalid action is refused", ctx do
    {true, text} = call(ctx.scope, ctx.main, %{action: "nonsense"})
    assert text =~ "invalid_action"
  end
end
