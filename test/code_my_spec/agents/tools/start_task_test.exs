defmodule CodeMySpec.Agents.Tools.StartTaskTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.TerminalAgentFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Repo
  alias CodeMySpecTest.AgentPresence
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  test "authenticated agents cannot redirect a claim to another durable agent" do
    {scope, _agent, _component, params} = setup_requirement()
    caller = durable_agent(scope)
    other = durable_agent(scope)
    frame = %Frame{assigns: %{current_scope: scope, agent_id: caller.id}}

    response =
      ToolLibrary.run(
        "start_task",
        Map.put(params, :agent_id, other.id),
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:error, _}, response)
    assert response_text(response) =~ "Cannot start another agent's task"
    assert CodeMySpec.Repo.reload!(caller).tasks == []
    assert CodeMySpec.Repo.reload!(other).tasks == []

    own_response =
      ToolLibrary.run(
        "start_task",
        params,
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, own_response)
    assert length(CodeMySpec.Repo.reload!(caller).tasks) == 1
    assert CodeMySpec.Repo.reload!(other).tasks == []
  end

  describe "execute/2 — happy path" do
    test "creates an active task and returns a prompt" do
      {scope, agent, component, req_params} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "start_task",
          Map.put(req_params, :session_id, agent.engine_session_id),
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      content = response_text(response)

      assert is_binary(content)
      assert content =~ "Task ID:"

      # DB state: task is active with correct linkage
      updated = Repo.reload!(agent)
      task = Enum.find(updated.tasks, &(&1.requirement_name == "implementation_file"))
      assert task.status == :active
      assert task.component_id == component.id
      assert task.started_at
    end

    test "resolves the terminal agent by the session id the hook injects" do
      {scope, _agent, _component, req_params} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      external_id = "ext-conv-#{System.unique_integer([:positive])}"
      ext_agent = terminal_agent_fixture(scope, %{engine_session_id: external_id})

      response =
        ToolLibrary.run(
          "start_task",
          Map.put(req_params, :session_id, external_id),
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)

      task =
        Enum.find(Repo.reload!(ext_agent).tasks, &(&1.requirement_name == "implementation_file"))

      assert task.status == :active
    end

    test "a session that never registered as an agent has no owner to start a task on" do
      {scope, _agent, _component, req_params} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "start_task",
          Map.put(
            req_params,
            :session_id,
            "conv-unregistered-#{System.unique_integer([:positive])}"
          ),
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
      assert response_text(response) =~ "No agent found"
    end
  end

  describe "execute/2 — deduplication" do
    test "returns prompt for already-active task without creating a duplicate" do
      {scope, agent, _component, req_params} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      params = Map.put(req_params, :session_id, agent.engine_session_id)

      # First call creates the task
      _ =
        ToolLibrary.run(
          "start_task",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      # Second call should return prompt, not create another task
      response =
        ToolLibrary.run(
          "start_task",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      assert response_text(response) =~ "Task ID:"

      matching =
        Enum.filter(Repo.reload!(agent).tasks, &(&1.requirement_name == "implementation_file"))

      assert length(matching) == 1
    end

    test "resumes a prepared task by activating it" do
      {scope, _agent, component, req_params} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      # A task left prepared (simulates leftover from the old flow).
      agent =
        terminal_agent_fixture(scope, %{
          tasks: [
            %{
              status: :prepared,
              session_type: CodeMySpec.AgentTasks.ComponentCode,
              requirement_name: "implementation_file",
              project_id: scope.active_project_id,
              component_id: component.id
            }
          ]
        })

      prepared_task = hd(agent.tasks)

      response =
        ToolLibrary.run(
          "start_task",
          Map.put(req_params, :session_id, agent.engine_session_id),
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)

      task = Enum.find(Repo.reload!(agent).tasks, &(&1.id == prepared_task.id))
      assert task.status == :active
    end
  end

  describe "execute/2 — error paths" do
    test "returns error for non-existent requirement" do
      scope = full_scope_fixture()
      agent = terminal_agent_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "start_task",
          %{
            requirement_name: "nonexistent",
            entity_type: "component",
            entity_id: Ecto.UUID.generate(),
            session_id: agent.engine_session_id
          },
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
      assert response_text(response) =~ "not found"
    end

    test "returns error when session_id is missing" do
      {scope, _agent, _component, req_params} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "start_task",
          req_params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
      assert response_text(response) =~ "No agent found"
    end

    test "returns error without valid scope" do
      frame = %Frame{assigns: %{}}

      response =
        ToolLibrary.run(
          "start_task",
          %{
            requirement_name: "implementation_file",
            entity_type: "component",
            entity_id: "x",
            session_id: "x"
          },
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # 783f3709: a hold stops a NEW claim only. Work an agent already holds --
  # mid-run when the hold was placed -- must finish and must be resumable.
  describe "a fleet hold" do
    alias CodeMySpec.Analysis.FleetHolds

    test "refuses a new claim, naming why, and lifting lets it proceed" do
      {scope, agent, _component, req_params} = setup_requirement()
      params = Map.put(req_params, :session_id, agent.engine_session_id)
      frame = %Frame{assigns: %{current_scope: scope}}

      {:ok, _hold} = FleetHolds.place(scope, "load 40, five agents running tests")

      held_response =
        ToolLibrary.run("start_task", params, Map.put(frame.assigns, :scope, scope))

      assert match?({:error, _}, held_response)
      assert response_text(held_response) =~ "fleet hold is in force"
      assert response_text(held_response) =~ "load 40, five agents running tests"
      assert Repo.reload!(agent).tasks == []

      {:ok, _} = FleetHolds.lift(scope)

      lifted_response =
        ToolLibrary.run("start_task", params, Map.put(frame.assigns, :scope, scope))

      assert match?({:ok, _}, lifted_response)
      assert [%{status: :active}] = Repo.reload!(agent).tasks
    end

    test "does not disturb resuming a task already claimed before the hold" do
      {scope, agent, _component, req_params} = setup_requirement()
      params = Map.put(req_params, :session_id, agent.engine_session_id)
      frame = %Frame{assigns: %{current_scope: scope}}

      first =
        ToolLibrary.run("start_task", params, Map.put(frame.assigns, :scope, scope))

      assert match?({:ok, _}, first)

      {:ok, _hold} = FleetHolds.place(scope, "load 40")

      resumed =
        ToolLibrary.run("start_task", params, Map.put(frame.assigns, :scope, scope))

      assert match?({:ok, _}, resumed)
      assert [%{status: :active}] = Repo.reload!(agent).tasks
    end
  end

  # d2044280: an agent's own `tap_out` naming no task is supposed to hold the
  # whole agent, pending a decision -- but nothing retired the row once the
  # agent demonstrably stopped waiting on it, which is exactly what let two
  # agents read as frozen while they were actively taking turns.
  describe "a resumed tap-out" do
    alias CodeMySpec.Notifications
    alias CodeMySpec.Notifications.PermissionRequest

    test "claiming a new task retires its agent's pending, task-less tap-out" do
      {scope, _agent, _component, req_params} = setup_requirement()
      agent = durable_agent(scope)
      {:ok, request} = Notifications.request_agent_tap_out(scope, agent.id, nil, "stuck")

      frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}
      response = ToolLibrary.run("start_task", req_params, Map.put(frame.assigns, :scope, scope))

      assert match?({:ok, _}, response)
      assert Repo.get!(PermissionRequest, request.id).status == "expired"
    end

    test "resuming its own active task also retires the pending, task-less tap-out" do
      {scope, _agent, _component, req_params} = setup_requirement()
      agent = durable_agent(scope)
      frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

      assert match?(
               {:ok, _},
               ToolLibrary.run("start_task", req_params, Map.put(frame.assigns, :scope, scope))
             )

      {:ok, request} = Notifications.request_agent_tap_out(scope, agent.id, nil, "stuck")

      # Same params again: an already-active task is returned, not re-created
      # (`handle_existing/6`'s `:active` clause) -- resuming is the signal, not
      # a fresh claim.
      assert match?(
               {:ok, _},
               ToolLibrary.run("start_task", req_params, Map.put(frame.assigns, :scope, scope))
             )

      assert Repo.get!(PermissionRequest, request.id).status == "expired"
    end

    # A tap-out naming a task holds only that task (story 1080): a blocked
    # task's own blocker is refused outright, so the agent is left free to
    # claim different work instead (as it is while any task is blocked) --
    # and doing so is not a contradiction `retire_resumed_tap_out/1` should
    # act on.
    test "a tap-out naming a task is untouched by claiming different work" do
      {scope, _agent, _component, req_params} = setup_requirement()
      other_component = component_fixture(scope)

      other_params = %{
        requirement_name: "implementation_file",
        entity_type: "component",
        entity_id: other_component.id
      }

      CodeMySpec.Requirements.recompute(scope)

      agent = durable_agent(scope)
      frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

      assert match?(
               {:ok, _},
               ToolLibrary.run("start_task", req_params, Map.put(frame.assigns, :scope, scope))
             )

      [task] = Repo.reload!(agent).tasks
      {:ok, request} = Notifications.request_agent_tap_out(scope, agent.id, task.id, "stuck")
      assert Repo.reload!(agent).tasks |> hd() |> Map.get(:status) == :blocked

      assert match?(
               {:ok, _},
               ToolLibrary.run("start_task", other_params, Map.put(frame.assigns, :scope, scope))
             )

      assert Repo.get!(PermissionRequest, request.id).status == "pending"
    end
  end

  defp durable_agent(scope) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        role: "coding",
        working_copy: "/tmp/start-task-test",
        working_copy_id: scope.active_working_copy_id,
        status: :running
      })

    AgentPresence.present(agent)

    agent
  end

  defp setup_requirement do
    # Exercise task dispatch using the component implementation requirement.
    scope = CodeMySpec.ConfigurationsFixtures.ensure_configuration!(full_scope_fixture())
    component = component_fixture(scope)
    agent = terminal_agent_fixture(scope)

    # The graph has to exist before a task can be started against a node in it.
    # Reads serve rows and compute nothing; in production `GraphWatcher` does
    # this when the component sync announces.
    CodeMySpec.Requirements.recompute(scope)

    req_params = %{
      requirement_name: "implementation_file",
      entity_type: "component",
      entity_id: component.id
    }

    {scope, agent, component, req_params}
  end

  defp response_text({_status, text}), do: text
end
