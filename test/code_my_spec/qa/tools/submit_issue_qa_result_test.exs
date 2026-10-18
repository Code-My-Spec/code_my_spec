defmodule CodeMySpec.Qa.Tools.SubmitIssueQaResultTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.CodeMode.Tools.ToolDocs
  alias CodeMySpec.Qa.IssueQaAttempts
  alias CodeMySpec.TaskOwner

  setup do
    scope = full_scope_fixture()
    issue = issue_fixture(scope, %{status: :accepted})

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        device: CodeMySpec.DevicesFixtures.device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/issue-qa-validation",
        working_copy_id: copy.id,
        role: :qa,
        status: :running
      })

    {:ok, agent} =
      TaskOwner.add_task(scope, agent, %{
        status: :active,
        requirement_name: "qa_complete",
        issue_id: issue.id
      })

    task = TaskOwner.active_task(agent)
    frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}
    params = %{issue_id: issue.id, task_id: task.id, status: "fail", issue_ids: [issue.id]}
    %{scope: scope, issue: issue, agent: agent, task: task, frame: frame, params: params}
  end

  test "missing observation returns an actionable error and permits a corrected submission",
       ctx do
    response = submit(ctx, [%{name: "Delivery", status: "fail", details: "Missing notice"}])
    assert match?({:error, _}, response)
    assert text(response) =~ "Invalid submit_issue_qa_result payload:"
    assert text(response) =~ "#1 observation: can't be blank"
    assert_unsubmitted(ctx)

    response = submit(ctx, [%{name: "Delivery", status: "fail", observation: "Missing notice"}])
    assert match?({:ok, _}, response)

    assert %{status: :fail, scenarios: [%{observation: "Missing notice"}]} =
             IssueQaAttempts.latest(ctx.scope, ctx.issue.id)
  end

  test "missing fields in a later scenario retain its entry number", ctx do
    response =
      submit(ctx, [
        %{name: "Valid", status: "pass", observation: "Observed"},
        %{name: "Invalid", result: "fail", notes: "Missing notice"}
      ])

    assert match?({:error, _}, response)
    [_, second_scenario] = String.split(text(response), "#2 ", parts: 2)
    assert second_scenario =~ "observation: can't be blank"
    assert second_scenario =~ "status: can't be blank"
    assert_unsubmitted(ctx)
  end

  test "flat validation errors remain readable", ctx do
    response = submit(ctx, [])
    assert match?({:error, _}, response)
    assert text(response) =~ "scenarios: must have at least one scenario"
    assert_unsubmitted(ctx)
  end

  test "tool docs identify every required scenario field", ctx do
    {:reply, response, _} = ToolDocs.execute(%{name: "submit_issue_qa_result"}, ctx.frame)
    refute response.isError
    assert text(response) =~ "Required fields in each entry: name, status, observation"
    assert text(response) =~ "'pass'|'partial'|'fail'"
  end

  # 6cb860e7: this field's schema uses `field :status, :string, required: true,
  # doc: "Outcome: 'pass' ..."` -- `doc:` is not a key the vendored component
  # macro recognizes (only `description:` is), so it was silently dropped
  # from the JSON Schema before this fix, leaving `status`, `issue_id` and
  # `task_id` rendered with no text at all. `scenarios` already used
  # `description:`, which is why the test above alone never caught this.
  test "tool docs render the status, issue id and task id fields too", ctx do
    {:reply, response, _} = ToolDocs.execute(%{name: "submit_issue_qa_result"}, ctx.frame)
    refute response.isError

    body = text(response)
    assert body =~ "Outcome: 'pass'", "status's own description must survive"
    assert body =~ "Issue ID being tested", "issue_id's own description must survive"

    assert body =~ "active qa_complete task id",
           "task_id's own description must survive"
  end

  test "story submission rejects an issue task without crashing or recording an attempt", ctx do
    params =
      ctx.params
      |> Map.delete(:issue_id)
      |> Map.put(:status, "pass")
      |> Map.put(:scenarios, [%{name: "Validation", status: "pass", observation: "Observed"}])

    response =
      ToolLibrary.run(
        "submit_qa_result",
        params,
        Map.put(ctx.frame.assigns, :scope, ctx.frame.assigns.current_scope)
      )

    assert match?({:error, _}, response)
    assert text(response) =~ "submit_issue_qa_result"
    assert text(response) =~ ctx.issue.id
    assert_unsubmitted(ctx)

    refute CodeMySpec.Repo.get_by(CodeMySpec.Qa.QaAttempt, task_id: ctx.task.id)
  end

  test "a partial attempt completes the task and keeps the issue with QA (cae2db90)", ctx do
    {:ok, _} = Issues.set_awaiting_role(ctx.scope, ctx.issue, :qa)

    response =
      submit(%{ctx | params: Map.put(ctx.params, :status, "partial")}, [
        %{name: "Browser tooling", status: "partial", observation: "run_browser_script refused"}
      ])

    assert match?({:ok, _}, response)
    assert %{status: :partial} = IssueQaAttempts.latest(ctx.scope, ctx.issue.id)
    assert Issues.get_issue(ctx.scope, ctx.issue.id).awaiting_role == :qa

    {:ok, agent} = AgentsRepository.fetch_agent(ctx.scope, ctx.agent.id)
    refute TaskOwner.active_task(agent)
    assert TaskOwner.find_task(agent, ctx.task.id).status == :completed
  end

  test "a fail attempt completes the task and sends the fix back to the coder (cae2db90)", ctx do
    {:ok, _} = Issues.set_awaiting_role(ctx.scope, ctx.issue, :qa)

    response = submit(ctx, [%{name: "Delivery", status: "fail", observation: "Still broken"}])

    assert match?({:ok, _}, response)
    assert %{status: :fail} = IssueQaAttempts.latest(ctx.scope, ctx.issue.id)
    assert Issues.get_issue(ctx.scope, ctx.issue.id).awaiting_role == :coding

    {:ok, agent} = AgentsRepository.fetch_agent(ctx.scope, ctx.agent.id)
    refute TaskOwner.active_task(agent)
    assert TaskOwner.find_task(agent, ctx.task.id).status == :completed
  end

  defp submit(ctx, scenarios) do
    response =
      ToolLibrary.run(
        "submit_issue_qa_result",
        Map.put(ctx.params, :scenarios, scenarios),
        Map.put(ctx.frame.assigns, :scope, ctx.frame.assigns.current_scope)
      )

    response
  end

  defp assert_unsubmitted(ctx) do
    assert is_nil(IssueQaAttempts.latest(ctx.scope, ctx.issue.id))
    {:ok, agent} = AgentsRepository.fetch_agent(ctx.scope, ctx.agent.id)
    assert TaskOwner.active_task(agent).id == ctx.task.id
  end

  # `tool_docs` is still an MCP component; the QA tools are library tools.
  defp text({_status, text}), do: text
  defp text(response), do: Enum.map_join(response.content, "", & &1["text"])
end
