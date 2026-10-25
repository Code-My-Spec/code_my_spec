defmodule CodeMySpec.Agents.DetachedWorkTest do
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.EnvRestore

  defmodule Transport do
    def request_work_turn(copy, agent, ref, text, _timeout) do
      send(self(), {:detached_work, copy, agent.id, ref, text})
      {:ok, :started}
    end
  end

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    original =
      for key <- [:env, :desktop_agent_transport],
          do: {key, Application.fetch_env(:code_my_spec, key)}

    Application.put_env(:code_my_spec, :env, :desktop)
    Application.put_env(:code_my_spec, :desktop_agent_transport, Transport)

    on_exit(fn ->
      Enum.each(original, fn {key, value} -> EnvRestore.restore_fetched_app_env(key, value) end)
    end)

    {:ok, copy} = WorkingCopies.fetch(ctx.scope.active_working_copy_id)
    Repo.update!(Ecto.Changeset.change(copy, main: true))
    :ok
  end

  defp agent(scope, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        execution_mode: :detached,
        working_copy: "/tmp/detached-work-#{Ecto.UUID.generate()}",
        working_copy_id: nil,
        status: :running,
        continuous: true
      })

    AgentPresence.present(agent)
    agent
  end

  test "detached Main and Product are admitted with a live desktop execution host", ctx do
    for role <- [:main, :product] do
      owner = agent(ctx.scope, role)
      assert :ok = Work.admission(ctx.scope, owner, :work_offer)
      AgentPresence.absent(owner)
      assert {:hold, :busy} = Work.admission(ctx.scope, owner, :work_offer)
    end
  end

  test "missing host, invalid detached roles and stopped runtime remain inadmissible", ctx do
    owner = agent(ctx.scope, :main)

    for role <- [:coding, :qa] do
      assert {:hold, :busy} = Work.admission(ctx.scope, %{owner | role: role}, :work_offer)
    end

    assert {:hold, :busy} = Work.admission(ctx.scope, %{owner | status: :stopped}, :work_offer)
    Application.delete_env(:code_my_spec, :desktop_agent_transport)
    assert {:hold, :busy} = Work.admission(ctx.scope, owner, :work_offer)
    Application.put_env(:code_my_spec, :desktop_agent_transport, Transport)
    Application.put_env(:code_my_spec, :env, :prod)
    assert {:hold, :busy} = Work.admission(ctx.scope, owner, :work_offer)
  end

  test "off, retired, noncontinuous and busy safeguards still hold", ctx do
    owner = agent(ctx.scope, :main)
    assert {:hold, _} = Work.admission(ctx.scope, %{owner | continuous: false}, :work_offer)

    assert {:hold, :busy} =
             Work.admission(ctx.scope, %{owner | waiting_since: DateTime.utc_now()}, :work_offer)

    assert {:hold, :busy} =
             Work.admission(
               ctx.scope,
               %{owner | turn_started_at: DateTime.utc_now()},
               :work_offer
             )

    {:ok, off} = AgentsRepository.update_agent(ctx.scope, owner, %{off_at: DateTime.utc_now()})
    assert {:hold, {:off, _}} = Work.admission(ctx.scope, off, :work_offer)

    {:ok, retired} =
      AgentsRepository.update_agent(ctx.scope, off, %{retired_at: DateTime.utc_now(), off_at: nil})

    assert {:hold, {:retired, _}} = Work.admission(ctx.scope, retired, :work_offer)
  end

  test "detached Product resumes an owned task through desktop transport", ctx do
    owner = agent(ctx.scope, :product)

    {:ok, owner} =
      TaskOwner.add_task(ctx.scope, owner, %{
        requirement_name: "personas_complete",
        project_id: ctx.scope.active_project_id
      })

    [task] = owner.tasks
    {:ok, owner} = TaskOwner.activate_task(ctx.scope, owner, task.id)
    assert :ok = Work.resume_held_task(ctx.scope, owner.id)
    assert_received {:detached_work, nil, id, ref, text}
    assert id == owner.id
    assert is_binary(ref)
    assert text =~ "personas_complete"
    assert text =~ task.id
  end

  test "Product receives, discovers and claims project work while remaining detached", ctx do
    ctx = ProjectStateFixtures.apply_project_setup_steps(ctx)
    exercise_graph_work(ctx, :product)
  end

  test "Main receives, discovers and claims fleet work while remaining detached", ctx do
    ctx = ProjectStateFixtures.apply_project_kickoff(ctx)
    exercise_graph_work(ctx, :main)
  end

  defp exercise_graph_work(ctx, role) do
    :ok = GraphWatcher.settle(ctx.scope)
    owner = agent(ctx.scope, role)
    detached = %{ctx.scope | active_working_copy_id: nil, cwd: nil}
    stale = %{detached | active_working_copy_id: Ecto.UUID.generate(), cwd: "/wrong-copy"}
    assert %{active_working_copy_id: id, cwd: nil} = Work.requirement_scope(stale, owner)
    assert id == ctx.scope.active_working_copy_id
    [head | _] = Work.claimable_work(detached, owner)
    assert Work.claimable_work(stale, owner) == Work.claimable_work(detached, owner)

    assert {:ok, text} =
             ToolLibrary.run("get_next_requirement", %{}, %{scope: detached, agent_id: owner.id})

    assert text =~ head.name
    assert {:ok, _} = Work.request_turn_if_runnable(detached, owner, :continuous_enabled)
    assert_received {:detached_work, nil, target, _, _}
    assert target == owner.id

    assert {:ok, _} =
             ToolLibrary.run(
               "start_task",
               %{
                 requirement_name: head.name,
                 entity_type: head.entity_type,
                 entity_id: to_string(head.entity_id)
               },
               %{scope: detached, agent_id: owner.id}
             )

    {:ok, updated} = AgentsRepository.fetch_agent(ctx.scope, owner.id)
    assert Enum.any?(updated.tasks, &(&1.requirement_name == head.name and &1.status == :active))
    assert updated.execution_mode == :detached
    assert updated.working_copy_id == nil
    assert updated.working_copy == owner.working_copy

    assert ctx.scope.active_working_copy_id ==
             Work.requirement_scope(detached, owner).active_working_copy_id
  end
end
