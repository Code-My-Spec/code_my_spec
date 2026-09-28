defmodule CodeMySpecSpex.Story1053.Criterion3265Spex do
  @moduledoc """
  Question persistence reconsiders work through guarded admission, not a wake.
  Each execution state is tested independently so a runnable-case failure
  cannot hide a bypass in the busy, offline, continuous-off or active-task cases.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
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

  spex "Question admission respects a runnable main agent", criterion: 1235 do
    scenario "The durable inbox is updated without bypassing runnable eligibility" do
      given_ "the existing main agent is runnable", context do
        context = given_a_staffed_checkout(context, "spex_3265_runnable")
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(main.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(main.id) end)
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(main.id)

        main_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}}
        coding_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coding.id}}
        {:reply, tasks, _} = ListTasks.execute(%{}, main_frame)
        refute tasks.isError, response_text(tasks)

        {:ok,
         Map.merge(context, %{
           main_id: main.id,
           main_frame: main_frame,
           coding_frame: coding_frame,
           tasks_before: response_text(tasks),
           running_ids: Machine.running()
         })}
      end

      when_ "coding commits a question without a cadence check", context do
        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              questions: [
                %{
                  question: "Which export format should coding use?",
                  options: [%{label: "CSV"}, %{label: "JSON"}]
                }
              ]
            },
            context.coding_frame
          )

        refute asked.isError, response_text(asked)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(asked))
        {:ok, Map.put(context, :question_id, question_id)}
      end

      then_ "the inbox retains the question and admission respects the main agent's state",
            context do
        {:reply, inbox, _} = ListNotifications.execute(%{}, context.main_frame)
        refute inbox.isError, response_text(inbox)
        assert response_text(inbox) =~ context.question_id
        assert response_text(inbox) =~ "Which export format should coding use?"
        assert Machine.running() == context.running_ids
        {:reply, tasks, _} = ListTasks.execute(%{}, context.main_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        assert {:ok, %{busy?: true, queued: 0}} = Machine.status(context.main_id)
        HeldProvider.await_request()
        [request] = HeldProvider.seen()
        prompt = Jason.decode!(request)["messages"] |> Jason.encode!()
        assert prompt =~ "start_task"
        refute prompt =~ "The first is:"

        {:ok, context}
      end
    end
  end

  spex "Question admission respects a busy main agent" do
    scenario "The durable inbox is updated without bypassing busy eligibility" do
      given_ "the existing main agent is busy", context do
        context = given_a_staffed_checkout(context, "spex_3265_busy")
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(main.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(main.id) end)
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(main.id)

        assert {:ok, :started} =
                 Machine.send_message(
                   main.id,
                   "user-3265",
                   "Keep working on this explicit request"
                 )

        HeldProvider.await_request()
        assert {:ok, %{busy?: true, queued: 0}} = Machine.status(main.id)

        main_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}}
        coding_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coding.id}}
        {:reply, tasks, _} = ListTasks.execute(%{}, main_frame)
        refute tasks.isError, response_text(tasks)

        {:ok,
         Map.merge(context, %{
           main_id: main.id,
           main_frame: main_frame,
           coding_frame: coding_frame,
           tasks_before: response_text(tasks),
           running_ids: Machine.running()
         })}
      end

      when_ "coding commits a question without a cadence check", context do
        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              questions: [
                %{
                  question: "Which export format should coding use?",
                  options: [%{label: "CSV"}, %{label: "JSON"}]
                }
              ]
            },
            context.coding_frame
          )

        refute asked.isError, response_text(asked)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(asked))
        {:ok, Map.put(context, :question_id, question_id)}
      end

      then_ "the inbox retains the question and admission respects the main agent's state",
            context do
        {:reply, inbox, _} = ListNotifications.execute(%{}, context.main_frame)
        refute inbox.isError, response_text(inbox)
        assert response_text(inbox) =~ context.question_id
        assert response_text(inbox) =~ "Which export format should coding use?"
        assert Machine.running() == context.running_ids
        {:reply, tasks, _} = ListTasks.execute(%{}, context.main_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        assert {:ok, %{busy?: true, queued: 0}} = Machine.status(context.main_id)
        [request] = HeldProvider.seen()
        assert request =~ "Keep working on this explicit request"

        {:ok, context}
      end
    end
  end

  spex "Question admission respects a disconnected main agent" do
    scenario "The durable inbox is updated without bypassing disconnected eligibility" do
      given_ "the existing main agent is disconnected", context do
        context = given_a_staffed_checkout(context, "spex_3265_disconnected")
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        HeldProvider.start()
        HeldProvider.hold()
        assert {:error, :not_running} = Machine.status(main.id)

        main_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}}
        coding_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coding.id}}
        {:reply, tasks, _} = ListTasks.execute(%{}, main_frame)
        refute tasks.isError, response_text(tasks)

        {:ok,
         Map.merge(context, %{
           main_id: main.id,
           main_frame: main_frame,
           coding_frame: coding_frame,
           tasks_before: response_text(tasks),
           running_ids: Machine.running()
         })}
      end

      when_ "coding commits a question without a cadence check", context do
        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              questions: [
                %{
                  question: "Which export format should coding use?",
                  options: [%{label: "CSV"}, %{label: "JSON"}]
                }
              ]
            },
            context.coding_frame
          )

        refute asked.isError, response_text(asked)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(asked))
        {:ok, Map.put(context, :question_id, question_id)}
      end

      then_ "the inbox retains the question and admission respects the main agent's state",
            context do
        {:reply, inbox, _} = ListNotifications.execute(%{}, context.main_frame)
        refute inbox.isError, response_text(inbox)
        assert response_text(inbox) =~ context.question_id
        assert response_text(inbox) =~ "Which export format should coding use?"
        assert Machine.running() == context.running_ids
        {:reply, tasks, _} = ListTasks.execute(%{}, context.main_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        assert {:error, :not_running} = Machine.status(context.main_id)
        assert HeldProvider.seen() == []

        {:ok, context}
      end
    end
  end

  spex "Question admission respects a continuous-off main agent" do
    scenario "The durable inbox is updated without bypassing continuous-off eligibility" do
      given_ "the existing main agent is continuous-off", context do
        context = given_a_staffed_checkout(context, "spex_3265_continuous-off")
        main = Fixtures.running_agent(context.scope, role: "main", continuous: false)
        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(main.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(main.id) end)
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(main.id)

        main_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}}
        coding_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coding.id}}
        {:reply, tasks, _} = ListTasks.execute(%{}, main_frame)
        refute tasks.isError, response_text(tasks)

        {:ok,
         Map.merge(context, %{
           main_id: main.id,
           main_frame: main_frame,
           coding_frame: coding_frame,
           tasks_before: response_text(tasks),
           running_ids: Machine.running()
         })}
      end

      when_ "coding commits a question without a cadence check", context do
        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              questions: [
                %{
                  question: "Which export format should coding use?",
                  options: [%{label: "CSV"}, %{label: "JSON"}]
                }
              ]
            },
            context.coding_frame
          )

        refute asked.isError, response_text(asked)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(asked))
        {:ok, Map.put(context, :question_id, question_id)}
      end

      then_ "the inbox retains the question and admission respects the main agent's state",
            context do
        {:reply, inbox, _} = ListNotifications.execute(%{}, context.main_frame)
        refute inbox.isError, response_text(inbox)
        assert response_text(inbox) =~ context.question_id
        assert response_text(inbox) =~ "Which export format should coding use?"
        assert Machine.running() == context.running_ids
        {:reply, tasks, _} = ListTasks.execute(%{}, context.main_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.main_id)
        assert HeldProvider.seen() == []

        {:ok, context}
      end
    end
  end

  spex "Question admission respects a active-task main agent" do
    scenario "The durable inbox is updated without bypassing active-task eligibility" do
      given_ "the existing main agent is active-task", context do
        context = given_a_staffed_checkout(context, "spex_3265_active-task")
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        base_url = HeldProvider.start()
        HeldProvider.hold()
        {main, _task} = Fixtures.agent_task_fixture(context.scope, main)
        assert {:ok, _} = Machine.start_agent(main.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(main.id) end)
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(main.id)

        main_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}}
        coding_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coding.id}}
        {:reply, tasks, _} = ListTasks.execute(%{}, main_frame)
        refute tasks.isError, response_text(tasks)

        {:ok,
         Map.merge(context, %{
           main_id: main.id,
           main_frame: main_frame,
           coding_frame: coding_frame,
           tasks_before: response_text(tasks),
           running_ids: Machine.running()
         })}
      end

      when_ "coding commits a question without a cadence check", context do
        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              questions: [
                %{
                  question: "Which export format should coding use?",
                  options: [%{label: "CSV"}, %{label: "JSON"}]
                }
              ]
            },
            context.coding_frame
          )

        refute asked.isError, response_text(asked)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(asked))
        {:ok, Map.put(context, :question_id, question_id)}
      end

      then_ "the inbox retains the question and admission respects the main agent's state",
            context do
        {:reply, inbox, _} = ListNotifications.execute(%{}, context.main_frame)
        refute inbox.isError, response_text(inbox)
        assert response_text(inbox) =~ context.question_id
        assert response_text(inbox) =~ "Which export format should coding use?"
        assert Machine.running() == context.running_ids
        {:reply, tasks, _} = ListTasks.execute(%{}, context.main_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.main_id)
        assert HeldProvider.seen() == []

        {:ok, context}
      end
    end
  end
end
