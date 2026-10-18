defmodule CodeMySpec.Agents.Tools.StartTaskTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.SessionsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Sessions
  alias CodeMySpecTest.AgentPresence
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  test "authenticated agents cannot redirect a claim to another durable agent" do
    {scope, _session, _component, params} = setup_requirement()
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
      {scope, session, component, req_params} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "start_task",
          Map.put(req_params, :session_id, session.id),
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      content = response_text(response)

      assert is_binary(content)
      assert content =~ "Task ID:"

      # DB state: task is active with correct linkage
      updated_session = Sessions.get_session(scope, session.id)
      task = Enum.find(updated_session.tasks, &(&1.requirement_name == "implementation_file"))
      assert task.status == :active
      assert task.component_id == component.id
      assert task.started_at
    end

    test "assigns agent_id to the created task" do
      {scope, session, _component, req_params} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "start_task",
          req_params |> Map.put(:session_id, session.id) |> Map.put(:agent_id, "agent-42"),
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)

      updated_session = Sessions.get_session(scope, session.id)
      task = Enum.find(updated_session.tasks, &(&1.requirement_name == "implementation_file"))
      assert task.agent_id == "agent-42"
    end

    test "resolves session by external_conversation_id" do
      {scope, _session, _component, req_params} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      external_id = "ext-conv-#{System.unique_integer([:positive])}"
      {:ok, ext_session} = Sessions.find_or_create_session(scope, external_id)

      response =
        ToolLibrary.run(
          "start_task",
          Map.put(req_params, :session_id, external_id),
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)

      updated_session = Sessions.get_session(scope, ext_session.id)
      task = Enum.find(updated_session.tasks, &(&1.requirement_name == "implementation_file"))
      assert task.status == :active
    end

    test "lazily registers the session when the SessionStart hook never ran" do
      # First-session case: the conversation's session_id has no row because
      # the SessionStart hook hadn't fired (Claude Code loads hooks once at
      # session start). start_task must self-heal, not dead-end.
      {scope, _session, _component, req_params} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      external_id = "conv-unregistered-#{System.unique_integer([:positive])}"
      refute Sessions.get_by_external_id(scope, external_id)

      response =
        ToolLibrary.run(
          "start_task",
          Map.put(req_params, :session_id, external_id),
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)

      created = Sessions.get_by_external_id(scope, external_id)
      assert created, "start_task should have registered the missing session"

      updated_session = Sessions.get_session(scope, created.id)
      task = Enum.find(updated_session.tasks, &(&1.requirement_name == "implementation_file"))
      assert task.status == :active
    end
  end

  describe "execute/2 — deduplication" do
    test "returns prompt for already-active task without creating a duplicate" do
      {scope, session, _component, req_params} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      params = Map.put(req_params, :session_id, session.id)

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

      final_session = Sessions.get_session(scope, session.id)
      matching = Enum.filter(final_session.tasks, &(&1.requirement_name == "implementation_file"))
      assert length(matching) == 1
    end

    test "resumes a prepared task by activating it" do
      {scope, session, component, req_params} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      # Manually prepare a task (simulates leftover from old flow)
      task_attrs = %{
        session_type: CodeMySpec.AgentTasks.ComponentCode,
        requirement_name: "implementation_file",
        project_id: scope.active_project_id,
        component_id: component.id
      }

      {:ok, session_with_prepared} = Sessions.prepare_task(scope, session, task_attrs)
      prepared_task = Enum.find(session_with_prepared.tasks, &(&1.status == :prepared))

      response =
        ToolLibrary.run(
          "start_task",
          Map.put(req_params, :session_id, session_with_prepared.id),
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)

      # Task should now be active
      final_session = Sessions.get_session(scope, session.id)
      task = Enum.find(final_session.tasks, &(&1.id == prepared_task.id))
      assert task.status == :active
    end
  end

  describe "execute/2 — entity scoping" do
    test "two components with the same requirement_name get separate tasks" do
      scope = CodeMySpec.ConfigurationsFixtures.ensure_configuration!(full_scope_fixture())
      component_a = component_fixture(scope, %{name: "List", module_name: "MyApp.List"})
      component_b = component_fixture(scope, %{name: "Item", module_name: "MyApp.Item"})
      session = session_fixture(scope)

      # Both components have to be in the graph before a task can start on
      # either. Reads serve rows and compute nothing.
      CodeMySpec.Requirements.recompute(scope)

      frame = %Frame{assigns: %{current_scope: scope}}

      params_a = %{
        requirement_name: "implementation_file",
        entity_type: "component",
        entity_id: component_a.id,
        session_id: session.id,
        agent_id: "agent-a"
      }

      params_b = %{
        requirement_name: "implementation_file",
        entity_type: "component",
        entity_id: component_b.id,
        session_id: session.id,
        agent_id: "agent-b"
      }

      # Agent A starts a task for component A
      response_a =
        ToolLibrary.run(
          "start_task",
          params_a,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response_a)

      # Agent B starts a task for component B — should NOT get A's task
      response_b =
        ToolLibrary.run(
          "start_task",
          params_b,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response_b)

      # Verify: two separate tasks exist, each linked to the correct component
      final_session = Sessions.get_session(scope, session.id)

      implementation_tasks =
        Enum.filter(final_session.tasks, &(&1.requirement_name == "implementation_file"))

      assert length(implementation_tasks) == 2

      task_a = Enum.find(implementation_tasks, &(&1.component_id == component_a.id))
      task_b = Enum.find(implementation_tasks, &(&1.component_id == component_b.id))

      assert task_a, "Expected a task for component A"
      assert task_b, "Expected a task for component B"
      assert task_a.agent_id == "agent-a"
      assert task_b.agent_id == "agent-b"
    end
  end

  describe "execute/2 — error paths" do
    test "returns error for non-existent requirement" do
      scope = full_scope_fixture()
      session = session_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "start_task",
          %{
            requirement_name: "nonexistent",
            entity_type: "component",
            entity_id: Ecto.UUID.generate(),
            session_id: session.id
          },
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
      assert response_text(response) =~ "not found"
    end

    test "self-registers a UUID-form session_id that has no row instead of erroring" do
      # An unknown but valid session_id is indistinguishable from a real
      # conversation whose SessionStart hook never fired, so start_task
      # registers it rather than dead-ending (see happy-path self-heal test).
      {scope, _session, _component, req_params} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      session_id = Ecto.UUID.generate()

      response =
        ToolLibrary.run(
          "start_task",
          Map.put(req_params, :session_id, session_id),
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      assert Sessions.get_by_external_id(scope, session_id)
    end

    test "returns error when session_id is missing" do
      {scope, _session, _component, req_params} = setup_requirement()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "start_task",
          req_params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
      assert response_text(response) =~ "No session_id"
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
      {scope, session, _component, req_params} = setup_requirement()
      params = Map.put(req_params, :session_id, session.id)
      frame = %Frame{assigns: %{current_scope: scope}}

      {:ok, _hold} = FleetHolds.place(scope, "load 40, five agents running tests")

      held_response =
        ToolLibrary.run("start_task", params, Map.put(frame.assigns, :scope, scope))

      assert match?({:error, _}, held_response)
      assert response_text(held_response) =~ "fleet hold is in force"
      assert response_text(held_response) =~ "load 40, five agents running tests"
      assert Sessions.get_session(scope, session.id).tasks == []

      {:ok, _} = FleetHolds.lift(scope)

      lifted_response =
        ToolLibrary.run("start_task", params, Map.put(frame.assigns, :scope, scope))

      assert match?({:ok, _}, lifted_response)
      updated_session = Sessions.get_session(scope, session.id)
      assert [%{status: :active}] = updated_session.tasks
    end

    test "does not disturb resuming a task already claimed before the hold" do
      {scope, session, _component, req_params} = setup_requirement()
      params = Map.put(req_params, :session_id, session.id)
      frame = %Frame{assigns: %{current_scope: scope}}

      first =
        ToolLibrary.run("start_task", params, Map.put(frame.assigns, :scope, scope))

      assert match?({:ok, _}, first)

      {:ok, _hold} = FleetHolds.place(scope, "load 40")

      resumed =
        ToolLibrary.run("start_task", params, Map.put(frame.assigns, :scope, scope))

      assert match?({:ok, _}, resumed)
      updated_session = Sessions.get_session(scope, session.id)
      assert [%{status: :active}] = updated_session.tasks
    end
  end

  # d2044280: an agent's own `tap_out` naming no task is supposed to hold the
  # whole agent, pending a decision -- but nothing retired the row once the
  # agent demonstrably stopped waiting on it, which is exactly what let two
  # agents read as frozen while they were actively taking turns.
  describe "a resumed tap-out" do
    alias CodeMySpec.Notifications
    alias CodeMySpec.Notifications.PermissionRequest
    alias CodeMySpec.Repo

    test "claiming a new task retires its agent's pending, task-less tap-out" do
      {scope, _session, _component, req_params} = setup_requirement()
      agent = durable_agent(scope)
      {:ok, request} = Notifications.request_agent_tap_out(scope, agent.id, nil, "stuck")

      frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}
      response = ToolLibrary.run("start_task", req_params, Map.put(frame.assigns, :scope, scope))

      assert match?({:ok, _}, response)
      assert Repo.get!(PermissionRequest, request.id).status == "expired"
    end

    test "resuming its own active task also retires the pending, task-less tap-out" do
      {scope, _session, _component, req_params} = setup_requirement()
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
      {scope, _session, _component, req_params} = setup_requirement()
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
    session = session_fixture(scope)

    # The graph has to exist before a task can be started against a node in it.
    # Reads serve rows and compute nothing; in production `GraphWatcher` does
    # this when the component sync announces.
    CodeMySpec.Requirements.recompute(scope)

    req_params = %{
      requirement_name: "implementation_file",
      entity_type: "component",
      entity_id: component.id
    }

    {scope, session, component, req_params}
  end

  defp response_text({_status, text}), do: text
end
