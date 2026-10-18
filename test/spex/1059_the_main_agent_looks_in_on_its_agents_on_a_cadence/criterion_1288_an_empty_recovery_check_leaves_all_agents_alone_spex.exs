defmodule CodeMySpecSpex.Story1059.Criterion3320Spex do
  @moduledoc """
  Repeated recovery checks of an exhausted fleet create no work or messages.
  Empty role queues are verified before the action, not inferred from idleness.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Empty recovery checks leave the durable fleet alone", criterion: 1288 do
    scenario "Three checks preserve idle engines, intent and all communication surfaces" do
      given_ "main, coding and QA have healthy idle engines and no eligible work", context do
        context = given_a_staffed_checkout(context, "spex_3320")
        context = FullSatisfactionFixtures.apply(context)

        available =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, available), response_text(available)
        base_url = HeldProvider.start()
        HeldProvider.hold()

        agents =
          Enum.map(["main", "coding", "qa"], fn role ->
            agent = Fixtures.running_agent(context.scope, role: role, continuous: true)
            assert Fixtures.role_queue_size(context.scope, agent.id) == 0
            assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
            on_exit(fn -> Machine.stop_agent(agent.id) end)
            assert {:ok, %{busy?: false}} = Machine.status(agent.id)
            agent_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

            tasks =
              ToolLibrary.run(
                "list_tasks",
                %{},
                Map.put(agent_frame.assigns, :scope, agent_frame.assigns[:current_scope])
              )

            assert match?({:ok, _}, tasks), response_text(tasks)
            assert response_text(tasks) == "No tasks."

            conversation =
              ToolLibrary.run(
                "read_agent_conversation",
                %{agent_id: agent.id},
                Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
              )

            assert match?({:ok, _}, conversation), response_text(conversation)
            %{agent: agent, frame: agent_frame, conversation: response_text(conversation)}
          end)

        inbox =
          ToolLibrary.run(
            "list_notifications",
            %{},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, inbox), response_text(inbox)

        {:ok,
         Map.merge(context, %{
           agents: agents,
           inbox_before: response_text(inbox),
           running_ids: Machine.running()
         })}
      end

      when_ "three recovery checks inspect the unchanged fleet", context do
        for _ <- 1..3 do
          response =
            ToolLibrary.run(
              "check_in",
              %{},
              Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
            )

          assert match?({:ok, _}, response), response_text(response)
        end

        {:ok, context}
      end

      then_ "no model turn, task, conversation message or notification has been created",
            context do
        assert HeldProvider.seen() == []
        assert Machine.running() == context.running_ids

        for snapshot <- context.agents do
          assert {:ok, %{busy?: false}} = Machine.status(snapshot.agent.id)
          assert Fixtures.role_queue_size(context.scope, snapshot.agent.id) == 0

          tasks =
            ToolLibrary.run(
              "list_tasks",
              %{},
              Map.put(snapshot.frame.assigns, :scope, snapshot.frame.assigns[:current_scope])
            )

          assert match?({:ok, _}, tasks), response_text(tasks)
          assert response_text(tasks) == "No tasks."

          conversation =
            ToolLibrary.run(
              "read_agent_conversation",
              %{agent_id: snapshot.agent.id},
              Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
            )

          assert match?({:ok, _}, conversation), response_text(conversation)
          assert response_text(conversation) == snapshot.conversation

          {:ok, view, _} =
            live(context.conn, Fixtures.agent_conversation_path(context.scope, snapshot.agent))

          assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        end

        inbox =
          ToolLibrary.run(
            "list_notifications",
            %{},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, inbox), response_text(inbox)
        assert response_text(inbox) == context.inbox_before
        {:ok, context}
      end
    end
  end
end
