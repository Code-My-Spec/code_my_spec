defmodule CodeMySpec.AgentTasks.EvaluateAgentTaskTest do
  use CodeMySpec.DataCase, async: false

  alias CodeMySpec.AgentTasks.EvaluateAgentTask
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Sessions.SessionsRepository
  alias CodeMySpec.Users.Scope

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ProjectsFixtures

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "evaluate_agent_task_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    env = Environment.new(:local, tmp_dir)

    base_scope = user_scope_fixture()
    project = project_fixture(base_scope)

    scope = %Scope{
      environment: env,
      active_project: project,
      active_project_id: project.id
    }

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{scope: scope, env: env}
  end

  describe "run/2" do
    test "returns empty map when no sessions exist", %{scope: scope} do
      assert %{} = EvaluateAgentTask.run(scope)
    end

    test "all valid at same priority → empty map, sessions deleted", %{scope: scope, env: env} do
      # ArchitectureReview.evaluate always returns {:ok, :valid}
      {:ok, session1} =
        SessionsRepository.create_session(env, %{
          type: "ArchitectureReview",
          priority: 1,
          state: %{}
        })

      {:ok, session2} =
        SessionsRepository.create_session(env, %{
          type: "ArchitectureReview",
          priority: 1,
          state: %{}
        })

      result = EvaluateAgentTask.run(scope)

      assert result == %{}

      # Both sessions should be deleted
      assert {:error, :not_found} = SessionsRepository.get_session(env, session1.id)
      assert {:error, :not_found} = SessionsRepository.get_session(env, session2.id)
    end

    test "multiple invalid at same priority → combined block feedback", %{scope: scope, env: env} do
      # ComponentSpec without a valid component will error during evaluate
      {:ok, _s1} =
        SessionsRepository.create_session(env, %{
          type: "ComponentSpec",
          priority: 10,
          component_module_name: "NonExistent.Module1",
          state: %{}
        })

      {:ok, _s2} =
        SessionsRepository.create_session(env, %{
          type: "ComponentSpec",
          priority: 10,
          component_module_name: "NonExistent.Module2",
          state: %{}
        })

      result = EvaluateAgentTask.run(scope)

      assert result["decision"] == "block"
      assert is_binary(result["reason"])
      # Should contain feedback from both sessions
      assert result["reason"] =~ "ComponentSpec"
    end

    test "higher priority blocks before lower priority is evaluated", %{scope: scope, env: env} do
      # High priority session that will fail
      {:ok, _failing} =
        SessionsRepository.create_session(env, %{
          type: "ComponentSpec",
          priority: 10,
          component_module_name: "NonExistent.Module",
          state: %{}
        })

      # Low priority session that would pass
      {:ok, passing_session} =
        SessionsRepository.create_session(env, %{
          type: "ArchitectureReview",
          priority: 1,
          state: %{}
        })

      result = EvaluateAgentTask.run(scope)

      # Should block on the high-priority session
      assert result["decision"] == "block"

      # Lower-priority session should still exist (not evaluated)
      assert {:ok, %Session{}} = SessionsRepository.get_session(env, passing_session.id)
    end

    test "passing higher priority only evaluates top level, ignores lower", %{
      scope: scope,
      env: env
    } do
      # High priority session that passes
      {:ok, high_session} =
        SessionsRepository.create_session(env, %{
          type: "ArchitectureReview",
          priority: 10,
          state: %{}
        })

      # Low priority session that would fail — but should not be evaluated
      {:ok, low_session} =
        SessionsRepository.create_session(env, %{
          type: "ComponentSpec",
          priority: 1,
          component_module_name: "NonExistent.Module",
          state: %{}
        })

      result = EvaluateAgentTask.run(scope)

      # High-priority session should be deleted (it passed)
      assert {:error, :not_found} = SessionsRepository.get_session(env, high_session.id)

      # Low-priority session should still exist (not evaluated)
      assert {:ok, _} = SessionsRepository.get_session(env, low_session.id)

      # No block — only the top level was evaluated and it passed
      assert result == %{}
    end

    test "deletes valid sessions, keeps invalid ones", %{scope: scope, env: env} do
      # Valid session
      {:ok, valid_session} =
        SessionsRepository.create_session(env, %{
          type: "ArchitectureReview",
          priority: 5,
          state: %{}
        })

      # Invalid session at same priority
      {:ok, invalid_session} =
        SessionsRepository.create_session(env, %{
          type: "ComponentSpec",
          priority: 5,
          component_module_name: "NonExistent.Module",
          state: %{}
        })

      result = EvaluateAgentTask.run(scope)

      assert result["decision"] == "block"

      # Valid session should be deleted
      assert {:error, :not_found} = SessionsRepository.get_session(env, valid_session.id)

      # Invalid session should still exist
      assert {:ok, %Session{}} = SessionsRepository.get_session(env, invalid_session.id)
    end
  end
end
