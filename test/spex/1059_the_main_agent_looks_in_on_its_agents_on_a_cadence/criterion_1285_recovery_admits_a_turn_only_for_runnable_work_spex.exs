defmodule CodeMySpecSpex.Story1059.Criterion3317Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 3317 — Recovery admits a turn only for runnable work.

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

  spex "Recovery requests one unassigned turn only for runnable work", criterion: 1285 do
    scenario "Recovery finds shaping work missed by ordinary admission" do
      given_ "idle continuous main and coding agents have only main-role shaping work available",
             context do
        context = given_a_staffed_checkout(context, "spex_3317")
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
           running_ids: Machine.running(),
           main_id: main.id,
           coding_id: coding.id,
           coding_conversation: response_text(conversation)
         })}
      end

      when_ "the recovery check inspects the existing fleet", context do
        response =
          ToolLibrary.run(
            "check_in",
            %{},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, response), response_text(response)

        HeldProvider.await_request()
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
          tasks =
            ToolLibrary.run("list_tasks", %{}, %{scope: context.scope, agent_id: id})

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
