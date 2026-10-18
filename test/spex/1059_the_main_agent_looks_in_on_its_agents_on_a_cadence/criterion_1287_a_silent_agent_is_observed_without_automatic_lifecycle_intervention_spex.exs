defmodule CodeMySpecSpex.Story1059.Criterion3319Spex do
  @moduledoc """
  Recovery exposes a silent agent without restarting it or manufacturing work.
  A continuous-off main agent cannot be woken merely because a fault exists.
  Existing task and message history are setup; the recovery action uses MCP.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.CheckIn
  alias CodeMySpec.McpServers.MainAgent.Tools.CheckMachinery
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Recovery observes silence without overriding lifecycle or continuous intent",
    criterion: 1287 do
    scenario "A silent coding agent remains stopped and main remains autonomous-off" do
      given_ "a coding agent has stopped reporting while holding a task", context do
        context = given_a_staffed_checkout(context, "spex_3319")
        main = Fixtures.running_agent(context.scope, role: "main", continuous: false)
        quiet = Fixtures.running_agent(context.scope, role: "coding", continuous: true)

        {quiet, task} =
          Fixtures.agent_task_fixture(context.scope, quiet,
            requirement_name: "implementation_file",
            started_at: DateTime.add(DateTime.utc_now(), -10_800, :second)
          )

        :ok = Fixtures.agent_said(context.scope, quiet, "starting on the exporter")
        :ok = Fixtures.age_agent_messages(context.scope, quiet, 10_800)
        base_url = HeldProvider.start()
        HeldProvider.hold()

        for id <- [main.id, quiet.id] do
          assert {:ok, _} = Machine.start_agent(id, context.copy, base_url: base_url)
          on_exit(fn -> Machine.stop_agent(id) end)
        end

        assert :ok = Machine.stop_agent(quiet.id)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}}
        quiet_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: quiet.id}}

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(quiet_frame.assigns, :scope, quiet_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) =~ task.id

        {:ok,
         Map.merge(context, %{
           frame: frame,
           quiet_frame: quiet_frame,
           main_id: main.id,
           quiet_id: quiet.id,
           task_id: task.id,
           tasks_before: response_text(tasks),
           running_ids: Machine.running()
         })}
      end

      when_ "recovery inspects the fleet", context do
        {:reply, response, _} = CheckIn.execute(%{}, context.frame)
        refute response.isError, response_text(response)
        {:ok, context}
      end

      then_ "work and machinery evidence identify the silent agent", context do
        {:reply, work, _} = ListAgentWork.execute(%{}, context.frame)
        refute work.isError, response_text(work)
        assert response_text(work) =~ context.quiet_id
        assert response_text(work) =~ "implementation_file"
        assert response_text(work) =~ ~r/last said|silent|stale/i
        {:reply, machinery, _} = CheckMachinery.execute(%{}, context.frame)
        refute machinery.isError, response_text(machinery)

        assert response_text(machinery) =~
                 ~r/not.running|unavailable|unreachable|not answering|missing|down/i

        {:ok, context}
      end

      then_ "no agent is restarted, assigned a replacement task or given a bypass turn",
            context do
        assert {:error, :not_running} = Machine.status(context.quiet_id)
        assert Machine.running() == context.running_ids

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.quiet_frame.assigns,
              :scope,
              context.quiet_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) == context.tasks_before

        main_tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, main_tasks), response_text(main_tasks)
        assert response_text(main_tasks) == "No tasks."
        assert {:ok, %{busy?: false}} = Machine.status(context.main_id)
        assert HeldProvider.seen() == []
        {:ok, context}
      end
    end
  end
end
