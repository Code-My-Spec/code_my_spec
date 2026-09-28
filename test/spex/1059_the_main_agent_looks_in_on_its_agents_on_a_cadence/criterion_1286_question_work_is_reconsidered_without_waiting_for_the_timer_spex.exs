defmodule CodeMySpecSpex.Story1059.Criterion3318Spex do
  @moduledoc """
  A persisted question reaches normal work admission before a recovery tick.
  Recovery overlapping that held turn cannot add a second pending turn.
  The question is created through MCP, never pre-seeded as an outcome.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.CheckIn
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Question admission does not wait for recovery or duplicate its turn", criterion: 1286 do
    scenario "Recovery overlaps the turn admitted by a newly persisted question" do
      given_ "an idle task-free main agent and a coding agent holding a task", context do
        context = given_a_staffed_checkout(context, "spex_3318")
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        {coding, task} = Fixtures.agent_task_fixture(context.scope, coding)
        main_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}}
        coding_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coding.id}}
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(main.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(main.id) end)
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(main.id)
        {:reply, tasks, _} = ListTasks.execute(%{}, main_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == "No tasks."

        {:ok,
         Map.merge(context, %{
           main_id: main.id,
           main_frame: main_frame,
           coding_frame: coding_frame,
           task_id: task.id,
           running_ids: Machine.running()
         })}
      end

      when_ "the coding agent asks before the next check-in", context do
        {:reply, response, _} =
          AskUserQuestion.execute(
            %{
              task_id: context.task_id,
              questions: [
                %{
                  question: "Should we retain the old column?",
                  options: [%{label: "Retain"}, %{label: "Remove"}]
                }
              ]
            },
            context.coding_frame
          )

        refute response.isError, response_text(response)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(response))
        _ = HeldProvider.await_request()
        {:ok, Map.put(context, :question_id, question_id)}
      end

      then_ "the question is durably visible and a turn has arrived without a tick", context do
        {:reply, inbox, _} = ListNotifications.execute(%{}, context.main_frame)
        refute inbox.isError, response_text(inbox)
        assert response_text(inbox) =~ context.question_id
        assert {:ok, %{busy?: true, queued: 0}} = Machine.status(context.main_id)
        assert length(HeldProvider.seen()) == 1
        {:ok, context}
      end

      when_ "recovery runs while the admitted turn is still in flight", context do
        {:reply, response, _} = CheckIn.execute(%{}, context.main_frame)
        refute response.isError, response_text(response)
        {:ok, context}
      end

      then_ "there is still one unassigned turn and no queued wake message", context do
        assert {:ok, %{busy?: true, queued: 0}} = Machine.status(context.main_id)
        assert Machine.running() == context.running_ids
        [request] = HeldProvider.seen()
        prompt = Jason.decode!(request)["messages"] |> Jason.encode!()
        assert prompt =~ "start_task"
        refute prompt =~ "The first is:"
        {:reply, tasks, _} = ListTasks.execute(%{}, context.main_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == "No tasks."
        {:ok, context}
      end
    end
  end
end
