defmodule CodeMySpecSpex.Story1059.Criterion3332Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 3332 — Recovery exposes current evidence without selecting a task.

  Initial story shaping belongs to main, not coding. Observe a real main
  turn and an unchanged coding conversation, while neither role has a task
  automatically claimed on its behalf.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.CheckIn
  alias CodeMySpec.McpServers.MainAgent.Tools.CheckMachinery
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Recovery evidence remains available without choosing the next task", criterion: 1300 do
    scenario "Fleet and question evidence support discovery rather than task preselection" do
      given_ "idle continuous main and coding agents have only main-role shaping work available",
             context do
        context = given_a_staffed_checkout(context, "spex_3332")
        context = ProjectStateFixtures.apply_project_kickoff(context)
        {:reply, response, _} = GetNextRequirement.execute(%{}, frame(context))
        refute response.isError, response_text(response)

        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        assert Fixtures.role_queue_size(context.scope, main.id) > 0
        assert Fixtures.role_queue_size(context.scope, coding.id) == 0
        coding_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coding.id}}

        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              questions: [
                %{
                  question: "Which retention policy applies?",
                  options: [%{label: "Keep records"}, %{label: "Remove records"}]
                }
              ]
            },
            coding_frame
          )

        refute asked.isError, response_text(asked)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(asked))

        base_url = HeldProvider.start()
        HeldProvider.hold()

        for id <- [main.id, coding.id] do
          assert {:ok, _} = Machine.start_agent(id, context.copy, base_url: base_url)
          on_exit(fn -> Machine.stop_agent(id) end)
          assert {:ok, %{busy?: false}} = Machine.status(id)
        end

        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: coding.id}, frame(context))

        refute conversation.isError, response_text(conversation)

        {:ok,
         Map.merge(context, %{
           question_id: question_id,
           running_ids: Machine.running(),
           main_id: main.id,
           coding_id: coding.id,
           coding_conversation: response_text(conversation)
         })}
      end

      when_ "the recovery check inspects the existing fleet", context do
        {:reply, response, _} = CheckIn.execute(%{}, frame(context))
        refute response.isError, response_text(response)

        HeldProvider.await_request()
        {:ok, context}
      end

      then_ "current work, question and machinery evidence can be inspected", context do
        {:reply, work, _} = ListAgentWork.execute(%{}, frame(context))
        refute work.isError, response_text(work)
        assert response_text(work) =~ context.main_id
        assert response_text(work) =~ context.coding_id
        assert response_text(work) =~ ~r/no task|nothing to do|in flight/i
        {:reply, questions, _} = ListNotifications.execute(%{}, frame(context))
        refute questions.isError, response_text(questions)
        assert response_text(questions) =~ context.question_id
        assert response_text(questions) =~ "Which retention policy applies?"
        {:reply, machinery, _} = CheckMachinery.execute(%{}, frame(context))
        refute machinery.isError, response_text(machinery)
        assert response_text(machinery) =~ ~r/working|healthy|answering/i
        {:ok, context}
      end

      then_ "only main is taking a turn and both agents still choose their own tasks", context do
        assert {:ok, %{busy?: true}} = Machine.status(context.main_id)
        assert {:ok, %{busy?: false}} = Machine.status(context.coding_id)
        assert Machine.running() == context.running_ids
        [request] = HeldProvider.seen()
        prompt = Jason.decode!(request)["messages"] |> Jason.encode!()
        assert prompt =~ "start_task"
        refute prompt =~ "The first is:"

        for id <- [context.main_id, context.coding_id] do
          {:reply, tasks, _} =
            ListTasks.execute(%{}, %Frame{assigns: %{current_scope: context.scope, agent_id: id}})

          refute tasks.isError, response_text(tasks)
          assert response_text(tasks) == "No tasks."
        end

        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: context.coding_id}, frame(context))

        refute conversation.isError, response_text(conversation)
        assert response_text(conversation) == context.coding_conversation
        {:ok, context}
      end
    end
  end
end
