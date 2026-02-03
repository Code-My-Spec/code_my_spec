defmodule CodeMySpec.Sessions.SessionServerTest do
  use CodeMySpec.DataCase, async: true

  import ExUnit.CaptureLog

  alias CodeMySpec.ComponentsFixtures
  alias CodeMySpec.Sessions.SessionServer
  alias CodeMySpec.SessionsFixtures
  alias CodeMySpec.UsersFixtures

  describe "init/1" do
    test "initializes minimal state with session_id" do
      {:ok, state} = SessionServer.init(123)

      assert state == %{session_id: 123, task: nil, scope: nil}
    end

    test "no task running initially" do
      {:ok, state} = SessionServer.init(456)

      assert state.task == nil
      assert state.scope == nil
    end
  end

  describe "handle_cast({:deliver_result, interaction_id, result, opts}, state)" do
    test "forwards message to waiting task" do
      parent = self()

      task =
        Task.async(fn ->
          receive do
            {:interaction_result, 123, %{status: :ok}, []} ->
              send(parent, :message_received)
          end
        end)

      state = %{session_id: 1, task: task, scope: nil}

      {:noreply, ^state} =
        SessionServer.handle_cast({:deliver_result, 123, %{status: :ok}, []}, state)

      assert_receive :message_received, 100
    end

    test "returns ok if no task running" do
      state = %{session_id: 1, task: nil, scope: nil}

      capture_log(fn ->
        {:noreply, ^state} =
          SessionServer.handle_cast({:deliver_result, 123, %{status: :ok}, []}, state)
      end)
    end
  end

  describe "handle_info({:DOWN, ref, :process, pid, result}, state)" do
    setup do
      scope = UsersFixtures.full_scope_fixture()
      component = ComponentsFixtures.component_fixture(scope)

      session =
        SessionsFixtures.session_fixture(scope, %{
          type: CodeMySpec.Sessions.AgentTasks.ContextSpec,
          component_id: component.id
        })

      %{scope: scope, session: session, component: component}
    end

    test "clears task state on successful completion", %{scope: scope, session: session} do
      task = Task.async(fn -> {:ok, session} end)

      state = %{session_id: session.id, task: task, scope: scope}

      result = Task.await(task)

      capture_log(fn ->
        {:noreply, new_state} =
          SessionServer.handle_info({task.ref, result}, state)

        assert new_state.task == nil
        assert new_state.scope == nil
      end)
    end

    test "handles task errors gracefully", %{session: session} do
      # Trap exits so the failing task doesn't kill the test process
      Process.flag(:trap_exit, true)
      parent = self()

      capture_log(fn ->
        task =
          Task.async(fn ->
            send(parent, :task_started)
            raise "error"
          end)

        state = %{session_id: session.id, task: task, scope: nil}

        # Wait for task to start and fail
        assert_receive :task_started

        # Receive the DOWN message
        receive do
          {:DOWN, ref, :process, pid, reason} when ref == task.ref ->
            {:noreply, new_state} =
              SessionServer.handle_info({:DOWN, ref, :process, pid, reason}, state)

            assert new_state.task == nil
            assert new_state.scope == nil
        after
          1000 -> flunk("Did not receive DOWN message")
        end
      end)
    end
  end

  describe "handle_info(:auto_continue, state)" do
    test "returns noreply without error" do
      state = %{session_id: 1, task: nil, scope: nil}

      {:noreply, ^state} = SessionServer.handle_info(:auto_continue, state)
    end
  end
end
