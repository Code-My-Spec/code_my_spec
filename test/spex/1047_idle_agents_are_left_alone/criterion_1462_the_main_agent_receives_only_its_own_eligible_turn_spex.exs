defmodule CodeMySpecSpex.Story1047.Criterion3564Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3564 — The main agent receives only its own eligible turn.

  Initial story shaping belongs to main, not coding. Observe a real main
  turn and an unchanged coding conversation, while neither role has a task
  automatically claimed on its behalf.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Main follows the same scoped eligibility contract", criterion: 1462 do
    scenario "Initial shaping work gives main a turn without assigning a task" do
      given_ "idle continuous main and coding agents have only main-role shaping work available",
             context do
        context = given_a_staffed_checkout(context, "spex_3564")
        context = ProjectStateFixtures.apply_project_kickoff(context)

        response =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, response), response_text(response)

        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        assert Fixtures.role_queue_size(context.scope, main.id) > 0
        assert Fixtures.role_queue_size(context.scope, coding.id) == 0
        base_url = HeldProvider.start()
        HeldProvider.hold()

        for id <- [main.id, coding.id] do
          assert {:ok, _} = Machine.start_agent(id, context.copy, base_url: base_url)
          on_exit(fn -> Machine.stop_agent(id) end)
          assert {:ok, %{busy?: false}} = Machine.status(id)
        end

        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: coding.id},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, conversation), response_text(conversation)

        {:ok,
         Map.merge(context, %{
           main_id: main.id,
           coding_id: coding.id,
           coding_conversation: response_text(conversation)
         })}
      end

      when_ "continuous eligibility is reconsidered for both agents", context do
        for id <- [context.main_id, context.coding_id] do
          response =
            ToolLibrary.run(
              "set_agent_continuous",
              %{agent_id: id, continuous: true},
              Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
            )

          assert match?({:ok, _}, response), response_text(response)
        end

        HeldProvider.await_request()
        {:ok, context}
      end

      then_ "only main is taking a turn and both agents still choose their own tasks", context do
        assert {:ok, %{busy?: true}} = Machine.status(context.main_id)
        assert {:ok, %{busy?: false}} = Machine.status(context.coding_id)
        assert length(HeldProvider.seen()) == 1

        for id <- [context.main_id, context.coding_id] do
          tasks =
            ToolLibrary.run(
              "list_tasks",
              %{agent_id: id},
              Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
            )

          assert match?({:ok, _}, tasks), response_text(tasks)
          assert response_text(tasks) == "No tasks."
        end

        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: context.coding_id},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, conversation), response_text(conversation)
        assert response_text(conversation) == context.coding_conversation
        {:ok, context}
      end
    end
  end
end
