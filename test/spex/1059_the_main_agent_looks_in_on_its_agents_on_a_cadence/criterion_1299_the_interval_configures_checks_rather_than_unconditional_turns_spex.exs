defmodule CodeMySpecSpex.Story1059.Criterion3331Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 3331 — The interval configures checks rather than unconditional turns.

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

  spex "Changing the interval reschedules real recovery without unconditional turns",
    criterion: 1299 do
    scenario "A shorter interval applies to an already-running recovery timer" do
      given_ "idle continuous main and coding agents have only main-role shaping work available",
             context do
        context = given_a_staffed_checkout(context, "spex_3331")
        context = ProjectStateFixtures.apply_project_kickoff(context)

        response =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, response), response_text(response)

        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
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

        configured =
          ToolLibrary.run(
            "cadence",
            %{seconds: 120},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, configured), response_text(configured)
        # The original schedule leaves enough room for gate contention; the
        # assertion below still requires the shorter interval to fire first.
        old_fire_at = DateTime.add(DateTime.utc_now(), 120, :second)
        :ok = Fixtures.start_recovery_timer(context.scope)

        timer =
          ToolLibrary.run(
            "cadence",
            %{},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, timer), response_text(timer)
        assert response_text(timer) =~ "running: yes"

        {:ok,
         Map.merge(context, %{
           running_ids: Machine.running(),
           old_fire_at: old_fire_at,
           main_id: main.id,
           coding_id: coding.id,
           coding_conversation: response_text(conversation)
         })}
      end

      when_ "the operator shortens the running cadence to one second", context do
        changed_at = DateTime.utc_now()

        response =
          ToolLibrary.run(
            "cadence",
            %{seconds: 1},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, response), response_text(response)

        # A graph notification is not proof that the recovery timer fired.
        # Require a newer check in the public recovery status as well.
        checked_at =
          Fixtures.await_recovery_check(
            fn ->
              report =
                ToolLibrary.run(
                  "cadence",
                  %{},
                  Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
                )

              assert match?({:ok, _}, report), response_text(report)
              response_text(report)
            end,
            changed_at,
            max(DateTime.diff(context.old_fire_at, DateTime.utc_now(), :millisecond), 0)
          )

        # Before the old 30-second schedule could have fired: the shorter
        # interval reached the running timer. A wall-clock bound tighter than
        # that only measured how loaded the machine was.
        assert DateTime.compare(checked_at, context.old_fire_at) == :lt
        HeldProvider.await_request(CmsHarnessTest.GateWait.event_timeout())
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
