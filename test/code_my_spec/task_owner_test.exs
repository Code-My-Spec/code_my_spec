defmodule CodeMySpec.TaskOwnerTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.SessionsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Repo
  alias CodeMySpec.TaskOwner
  alias CodeMySpecTest.AgentPresence

  for kind <- [:session, :agent] do
    describe "#{kind} task blockers" do
      setup do
        scope = full_scope_fixture()
        owner = owner_fixture(unquote(kind), scope)

        {:ok, owner} =
          TaskOwner.add_task(scope, owner, %{status: :active, requirement_name: "spec_file"})

        task = TaskOwner.active_task(owner)
        %{scope: scope, owner: owner, task: task, request: Ecto.UUID.generate()}
      end

      test "blocking preserves identity and continuous intent while freeing the active slot",
           context do
        %{scope: scope, owner: owner, task: task, request: request} = context

        assert {:ok, blocked} =
                 TaskOwner.block_task(scope, owner, task.id, :question, request,
                   reason: "Need a decision"
                 )

        assert TaskOwner.active_task(blocked) == nil
        assert [saved] = TaskOwner.blocked_tasks(blocked)
        assert saved.id == task.id
        assert saved.requirement_name == task.requirement_name
        assert saved.blocker_id == request
        assert saved.blocker_type == :question
        assert saved.blocked_reason == "Need a decision"
        assert %DateTime{} = saved.blocked_at
        assert saved.completed_at == nil
        assert blocked.continuous == owner.continuous
        assert TaskOwner.find_task(Repo.reload!(blocked), task.id) == saved
      end

      test "only the matching blocker resolves and replay keeps its timestamp", context do
        %{scope: scope, owner: owner, task: task, request: request} = context
        assert {:ok, blocked} = TaskOwner.block_task(scope, owner, task.id, :tap_out, request)

        assert {:ok, untouched} =
                 TaskOwner.release_block(scope, owner, task.id, Ecto.UUID.generate())

        assert TaskOwner.find_task(untouched, task.id).blocker_resolved_at == nil
        assert {:ok, resolved} = TaskOwner.release_block(scope, owner, task.id, request)
        saved = TaskOwner.find_task(resolved, task.id)
        assert saved.status == :blocked
        assert %DateTime{} = saved.blocker_resolved_at
        assert {:ok, replay} = TaskOwner.release_block(scope, blocked, request)
        assert TaskOwner.find_task(replay, task.id) == saved
      end

      test "resume is explicit and an older answer cannot release a newer blocker", context do
        %{scope: scope, owner: owner, task: task, request: request} = context
        assert {:ok, blocked} = TaskOwner.block_task(scope, owner, task.id, :question, request)
        assert {:error, :blocker_unresolved} = TaskOwner.resume_task(scope, owner, task.id)
        assert {:ok, _} = TaskOwner.release_block(scope, blocked, task.id, request)
        assert {:ok, resumed} = TaskOwner.resume_task(scope, owner, task.id)
        assert TaskOwner.active_task(resumed).id == task.id
        assert TaskOwner.active_task(resumed).blocker_id == nil
        newer = Ecto.UUID.generate()

        assert {:ok, blocked_again} =
                 TaskOwner.block_task(scope, resumed, task.id, :question, newer)

        assert {:ok, ignored} = TaskOwner.release_block(scope, owner, task.id, request)

        assert TaskOwner.find_task(ignored, task.id) ==
                 TaskOwner.find_task(blocked_again, task.id)

        assert {:error, :blocker_unresolved} = TaskOwner.resume_task(scope, ignored, task.id)
      end

      test "stale owner snapshots do not discard another task's blocker", context do
        %{scope: scope, owner: owner, task: task, request: request} = context
        assert {:ok, _} = TaskOwner.block_task(scope, owner, task.id, :question, request)

        {:ok, owner} =
          TaskOwner.add_task(scope, owner, %{status: :active, requirement_name: "test_file"})

        second = List.last(TaskOwner.tasks(owner))

        assert {:ok, both} =
                 TaskOwner.block_task(scope, owner, second.id, :manual, Ecto.UUID.generate())

        assert length(TaskOwner.blocked_tasks(both)) == 2
        assert {:ok, resolved} = TaskOwner.release_block(scope, owner, task.id, request)
        assert TaskOwner.find_task(resolved, second.id).status == :blocked
        assert TaskOwner.find_task(resolved, second.id).blocker_resolved_at == nil
      end

      test "legacy activation cannot bypass explicit blocked-task resumption", context do
        %{scope: scope, owner: owner, task: task, request: request} = context
        {:ok, _} = TaskOwner.block_task(scope, owner, task.id, :question, request)
        assert {:error, :task_blocked} = TaskOwner.activate_task(scope, owner, task.id)
        {:ok, resolved} = TaskOwner.release_block(scope, owner, task.id, request)
        assert {:error, :task_blocked} = TaskOwner.activate_task(scope, owner, task.id)
        assert TaskOwner.find_task(Repo.reload!(owner), task.id).status == :blocked
        assert {:ok, resumed} = TaskOwner.resume_task(scope, resolved, task.id)
        assert TaskOwner.active_task(resumed).id == task.id
      end

      test "adding, activating and completing from stale snapshots preserve blockers", context do
        %{scope: scope, owner: owner, task: task, request: request} = context
        {:ok, blocked} = TaskOwner.block_task(scope, owner, task.id, :question, request)
        saved = TaskOwner.find_task(blocked, task.id)

        {:ok, added} =
          TaskOwner.add_task(scope, owner, %{status: :prepared, requirement_name: "test_file"})

        second = List.last(TaskOwner.tasks(added))
        assert TaskOwner.find_task(added, task.id) == saved
        assert {:ok, activated} = TaskOwner.activate_task(scope, owner, second.id)
        assert TaskOwner.find_task(activated, task.id) == saved
        assert TaskOwner.find_task(activated, second.id).status == :active
        assert {:ok, completed} = TaskOwner.complete_task(scope, owner, second.id)
        assert TaskOwner.find_task(completed, task.id) == saved
        assert TaskOwner.find_task(completed, second.id).status == :completed
      end

      test "resumption cannot displace another active task", context do
        %{scope: scope, owner: owner, task: task, request: request} = context
        {:ok, owner} = TaskOwner.block_task(scope, owner, task.id, :question, request)
        {:ok, owner} = TaskOwner.release_block(scope, owner, request)

        {:ok, owner} =
          TaskOwner.add_task(scope, owner, %{status: :active, requirement_name: "test_file"})

        assert {:error, :active_task_exists} = TaskOwner.resume_task(scope, owner, task.id)
        assert TaskOwner.find_task(Repo.reload!(owner), task.id).status == :blocked
      end

      test "scope checks and transaction rollback prevent partial mutations", context do
        %{scope: scope, owner: owner, task: task, request: request} = context

        assert {:error, :owner_not_found} =
                 TaskOwner.block_task(full_scope_fixture(), owner, task.id, :question, request)

        assert {:error, :task_not_found} =
                 TaskOwner.block_task(scope, owner, Ecto.UUID.generate(), :question, request)

        assert {:error, :abort} =
                 Repo.transaction(fn ->
                   assert {:ok, _} =
                            TaskOwner.block_task(scope, owner, task.id, :question, request)

                   Repo.rollback(:abort)
                 end)

        assert TaskOwner.find_task(Repo.reload!(owner), task.id).status == :active
      end
    end
  end

  test "a durable agent cannot claim or activate another task from a stale snapshot" do
    scope = full_scope_fixture()
    empty_owner = owner_fixture(:agent, scope)
    {:ok, owner} = TaskOwner.add_task(scope, empty_owner, %{status: :active})
    active_id = TaskOwner.active_task(owner).id

    assert {:error, {:active_task_exists, ^active_id}} =
             TaskOwner.add_task(scope, empty_owner, %{status: :active})

    {:ok, prepared} = TaskOwner.add_task(scope, empty_owner, %{status: :prepared})
    prepared_id = List.last(TaskOwner.tasks(prepared)).id

    assert {:error, {:active_task_exists, ^active_id}} =
             TaskOwner.activate_task(scope, empty_owner, prepared_id)

    assert TaskOwner.active_task(Repo.reload!(owner)).id == active_id
  end

  defp owner_fixture(:session, scope), do: session_fixture(scope, %{continuous: true})

  defp owner_fixture(:agent, scope) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        role: "coding",
        working_copy: "/tmp/task-owner-test",
        working_copy_id: scope.active_working_copy_id,
        continuous: true,
        status: :running
      })

    AgentPresence.present(agent)

    agent
  end
end
