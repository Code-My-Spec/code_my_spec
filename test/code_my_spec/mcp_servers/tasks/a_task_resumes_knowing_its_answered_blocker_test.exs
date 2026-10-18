defmodule CodeMySpec.McpServers.Tasks.ATaskResumesKnowingItsAnsweredBlockerTest do
  @moduledoc """
  Story 1080, criterion 2173 (John, 2026-10-18): an answer that arrives while
  the agent is on other work is not pushed ahead of it. Whatever brings the
  agent back to the released task, `start_task` resumes it with the question
  and the user's answer at the top.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Notifications
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()
    issue = issue_fixture(scope, %{status: :accepted})

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    {:ok, coding} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "anthropic",
        working_copy: "/tmp/answered-resume",
        role: :coding,
        status: :running,
        working_copy_id: copy.id
      })

    AgentPresence.present(coding)
    {:ok, _} = Agents.assign_issue_to_working_copy(scope, issue.id, copy.id)

    frame = %Frame{assigns: %{current_scope: scope, agent_id: coding.id}}
    params = %{requirement_name: "fix_issue", entity_type: "issue", entity_id: issue.id}
    {:reply, started, _} = StartTask.execute(params, frame)
    refute started.isError, inspect(started)

    %{scope: scope, coding: coding, frame: frame, params: params}
  end

  test "resuming a task an answered question released leads with the question and answer",
       ctx do
    [task] = CodeMySpec.Repo.get!(Agents.Agent, ctx.coding.id).tasks

    {:ok, request} =
      Notifications.create_agent_question_request(
        ctx.scope,
        ctx.coding.id,
        %{
          "title" => "Which file owns this fix?",
          "holder" => "user",
          "questions" => [%{"question" => "a.ex or b.ex?", "options" => []}]
        },
        task.id
      )

    {:ok, _} = Notifications.answer_question_request(request.id, %{"a.ex or b.ex?" => "b.ex"})

    {:reply, resumed, _} = StartTask.execute(ctx.params, ctx.frame)
    refute resumed.isError, inspect(resumed)

    text = Enum.map_join(resumed.content, "\n", & &1["text"])
    assert text =~ "This task was blocked on question #{request.id}."
    assert text =~ "Q: a.ex or b.ex?\nA: b.ex"
  end

  test "starting fresh work says nothing about a blocker", ctx do
    {:reply, again, _} = StartTask.execute(ctx.params, ctx.frame)
    text = Enum.map_join(again.content, "\n", & &1["text"])
    refute text =~ "was blocked on question"
  end
end
