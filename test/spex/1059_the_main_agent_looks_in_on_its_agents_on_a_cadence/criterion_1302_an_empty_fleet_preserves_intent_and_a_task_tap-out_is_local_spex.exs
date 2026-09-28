defmodule CodeMySpecSpex.Story1059.Criterion3334Spex do
  @moduledoc """
  An exhausted fleet retains continuous intent, and a later task tap-out stays local.
  Empty role queues are verified before the action, not inferred from idleness.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.Cadence
  alias CodeMySpec.McpServers.MainAgent.Tools.CheckIn
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Empty work and a later task tap-out preserve continuous intent", criterion: 1302 do
    scenario "A finished fleet remains continuous when main later blocks a new task" do
      given_ "main, coding and QA have healthy idle engines and no eligible work", context do
        context = given_a_staffed_checkout(context, "spex_3334")
        context = FullSatisfactionFixtures.apply(context)
        {:reply, available, _} = GetNextRequirement.execute(%{}, frame(context))
        refute available.isError, response_text(available)
        base_url = HeldProvider.start()
        HeldProvider.hold()

        agents =
          Enum.map(["main", "coding", "qa"], fn role ->
            agent = Fixtures.running_agent(context.scope, role: role, continuous: true)
            assert Fixtures.role_queue_size(context.scope, agent.id) == 0
            assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
            on_exit(fn -> Machine.stop_agent(agent.id) end)
            assert {:ok, %{busy?: false, queued: 0}} = Machine.status(agent.id)
            agent_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
            {:reply, tasks, _} = ListTasks.execute(%{}, agent_frame)
            refute tasks.isError, response_text(tasks)
            assert response_text(tasks) == "No tasks."

            {:reply, conversation, _} =
              ReadAgentConversation.execute(%{agent_id: agent.id}, frame(context))

            refute conversation.isError, response_text(conversation)
            %{agent: agent, frame: agent_frame, conversation: response_text(conversation)}
          end)

        {:reply, inbox, _} = ListNotifications.execute(%{}, frame(context))
        refute inbox.isError, response_text(inbox)

        {:ok,
         Map.merge(context, %{
           agents: agents,
           inbox_before: response_text(inbox),
           running_ids: Machine.running()
         })}
      end

      when_ "three recovery checks inspect the unchanged fleet", context do
        for _ <- 1..3 do
          {:reply, response, _} = CheckIn.execute(%{}, frame(context))
          refute response.isError, response_text(response)
        end

        {:ok, context}
      end

      then_ "no model turn, task, conversation message or notification has been created",
            context do
        assert HeldProvider.seen() == []
        assert Machine.running() == context.running_ids

        for snapshot <- context.agents do
          assert {:ok, %{busy?: false, queued: 0}} = Machine.status(snapshot.agent.id)
          assert Fixtures.role_queue_size(context.scope, snapshot.agent.id) == 0
          {:reply, tasks, _} = ListTasks.execute(%{}, snapshot.frame)
          refute tasks.isError, response_text(tasks)
          assert response_text(tasks) == "No tasks."

          {:reply, conversation, _} =
            ReadAgentConversation.execute(%{agent_id: snapshot.agent.id}, frame(context))

          refute conversation.isError, response_text(conversation)
          assert response_text(conversation) == snapshot.conversation

          {:ok, view, _} =
            live(context.conn, Fixtures.agent_conversation_path(context.scope, snapshot.agent))

          assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        end

        {:reply, inbox, _} = ListNotifications.execute(%{}, frame(context))
        refute inbox.isError, response_text(inbox)
        assert response_text(inbox) == context.inbox_before
        {:ok, context}
      end

      when_ "new product work is claimed and main requests a task-scoped tap-out", context do
        # `:main`, not `"main"`. `agents.role` is an `Ecto.Enum`, so the string
        # this was written with matched nothing and `main` was nil — read three
        # steps later as `BadMapError` on `main.frame`, which says nothing about
        # the comparison that produced it.
        main = Enum.find(context.agents, &(&1.agent.role == :main))

        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Clarify the next export format",
            description: "New product work after the previous fleet work finished",
            acceptance_criteria: ["The export format is agreed"]
          )

        {:reply, started, _} =
          StartTask.execute(
            %{
              entity_type: "story",
              entity_id: to_string(story.number),
              requirement_name: "three_amigos_complete"
            },
            main.frame
          )

        refute started.isError, response_text(started)
        task_id = extract_task_id!(started)
        {:reply, cadence, _} = Cadence.execute(%{seconds: 1200}, main.frame)
        refute cadence.isError, response_text(cadence)
        {:reply, tapped, _} = TapOut.execute(%{task_id: task_id}, main.frame)
        refute tapped.isError, response_text(tapped)

        {:ok,
         Map.merge(context, %{
           main: main,
           task_id: task_id,
           cadence_before: response_text(cadence)
         })}
      end

      then_ "the task is blocked without changing cadence or continuous intent", context do
        {:reply, cadence, _} = Cadence.execute(%{}, context.main.frame)
        refute cadence.isError, response_text(cadence)
        assert response_text(cadence) == context.cadence_before
        {:reply, tasks, _} = ListTasks.execute(%{}, context.main.frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[blocked]"

        {:ok, view, _} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope, context.main.agent))

        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        assert Machine.running() == context.running_ids
        {:ok, context}
      end
    end
  end
end
