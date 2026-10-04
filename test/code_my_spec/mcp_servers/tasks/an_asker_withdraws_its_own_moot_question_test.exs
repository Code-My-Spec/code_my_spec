defmodule CodeMySpec.McpServers.Tasks.AnAskerWithdrawsItsOwnMootQuestionTest do
  @moduledoc """
  8c91d5bc: a coder blocked story 11's `story_promoted` on its own question,
  which went moot minutes later, and had no way to take it back — the task sat
  blocked 20+ minutes on a customer. The asker withdraws it with a reason,
  which releases the task through the one blocker path.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.McpServers.Tasks.Tools.CheckAnswer
  alias CodeMySpec.McpServers.Tasks.Tools.WithdrawQuestion
  alias CodeMySpec.Notifications
  alias CodeMySpec.TaskOwner
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    scope = %{scope | active_working_copy_id: copy.id}
    coder = agent(scope, copy, :coding)

    {:ok, coder} =
      TaskOwner.add_task(scope, coder, %{status: :active, requirement_name: "story_promoted"})

    task = TaskOwner.active_task(coder)

    {:ok, request} =
      Notifications.create_agent_question_request(
        scope,
        coder.id,
        %{
          "title" => "Criterion 944",
          "holder" => "user",
          "questions" => [%{"question" => "Revert or rewrite?", "options" => []}]
        },
        task.id
      )

    %{scope: scope, copy: copy, coder: coder, task: task, request: request}
  end

  defp agent(scope, copy, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        continuous: true,
        status: :running,
        working_copy: "/tmp/withdraw-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    agent
  end

  defp call(params, scope, agent_id) do
    frame = %Frame{assigns: %{current_scope: scope, agent_id: agent_id}}
    {:reply, response, _frame} = WithdrawQuestion.execute(params, frame)
    protocol = Response.to_protocol(response)
    {protocol["isError"] == true, Enum.map_join(protocol["content"], & &1["text"])}
  end

  test "the asker withdraws it with a reason, and its task is released", ctx do
    {error?, text} =
      call(
        %{question_id: ctx.request.id, reason: "product rewrote criterion 944"},
        ctx.scope,
        ctx.coder.id
      )

    refute error?, text
    assert text =~ ctx.task.id
    assert text =~ "start_task"

    request = Notifications.get_question_request(ctx.request.id)
    assert request.status == "withdrawn"
    assert request.withdrawn_reason == "product rewrote criterion 944"

    task = Agent |> Repo.get!(ctx.coder.id) |> TaskOwner.find_task(ctx.task.id)
    assert %DateTime{} = task.blocker_resolved_at
  end

  test "a withdrawn question leaves every queue, and check_answer says why", ctx do
    {false, _} = call(%{question_id: ctx.request.id, reason: "moot"}, ctx.scope, ctx.coder.id)

    refute Enum.any?(
             MainAgent.list_open_questions(ctx.scope),
             &(&1.id == ctx.request.id)
           )

    frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: ctx.coder.id}}
    {:reply, response, _} = CheckAnswer.execute(%{question_id: ctx.request.id}, frame)

    text =
      response |> Response.to_protocol() |> Map.fetch!("content") |> Enum.map_join(& &1["text"])

    assert text =~ "withdrew"
    assert text =~ "moot"
  end

  test "only the asker may withdraw it", ctx do
    other = agent(ctx.scope, ctx.copy, :qa)

    {error?, _text} =
      call(%{question_id: ctx.request.id, reason: "mine now"}, ctx.scope, other.id)

    assert error?
    assert Notifications.get_question_request(ctx.request.id).status == "pending"
  end

  test "a reason is required", ctx do
    {error?, _text} = call(%{question_id: ctx.request.id, reason: " "}, ctx.scope, ctx.coder.id)

    assert error?
    assert Notifications.get_question_request(ctx.request.id).status == "pending"
  end

  test "an answered question cannot be withdrawn", ctx do
    {:ok, _} =
      Notifications.answer_question_request(ctx.request.id, %{"Revert or rewrite?" => "rewrite"})

    {error?, _text} =
      call(%{question_id: ctx.request.id, reason: "moot"}, ctx.scope, ctx.coder.id)

    assert error?
    assert Notifications.get_question_request(ctx.request.id).status == "answered"
  end

  test "the coding, QA and product roles carry it" do
    for role <- [:coding, :qa, :product] do
      assert RoleProfile.carries?(role, "withdraw_question"), inspect(role)
    end
  end
end
