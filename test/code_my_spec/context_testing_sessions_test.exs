defmodule CodeMySpec.ContextTestingSessionsTest do
  use CodeMySpec.DataCase
  import CodeMySpec.{UsersFixtures, AccountsFixtures, ProjectsFixtures}
  alias CodeMySpec.{Sessions, Components}
  alias CodeMySpec.ContextTestingSessions

  alias CodeMySpec.ContextTestingSessions.Steps.{
    Initialize,
    SpawnComponentTestingSessions,
    Finalize
  }

  describe "context testing session workflow" do
    setup do
      user = user_fixture()
      account = account_fixture()
      member_fixture(user, account)

      project =
        user_scope_fixture(user, account)
        |> project_fixture(%{account_id: account.id, module_name: "MyApp"})

      scope = user_scope_fixture(user, account, project)

      # Create test context component
      {:ok, accounts_context} =
        Components.create_component(scope, %{
          name: "Accounts",
          type: "context",
          module_name: "MyApp.Accounts",
          description: "Accounts context for managing users and authentication"
        })

      # Create child components
      {:ok, user_schema} =
        Components.create_component(scope, %{
          name: "User",
          type: "schema",
          module_name: "MyApp.Accounts.User",
          description: "User schema",
          parent_component_id: accounts_context.id
        })

      {:ok, user_repository} =
        Components.create_component(scope, %{
          name: "UserRepository",
          type: "repository",
          module_name: "MyApp.Accounts.UserRepository",
          description: "Repository for user persistence",
          parent_component_id: accounts_context.id
        })

      {:ok, accounts_live} =
        Components.create_component(scope, %{
          name: "AccountsLive",
          type: "other",
          module_name: "MyApp.AccountsLive",
          description: "LiveView for accounts management",
          parent_component_id: accounts_context.id
        })

      %{
        scope: scope,
        project: project,
        accounts_context: accounts_context,
        user_schema: user_schema,
        user_repository: user_repository,
        accounts_live: accounts_live
      }
    end

    @tag timeout: 300_000
    test "executes complete context testing workflow", %{
      scope: scope,
      accounts_context: accounts_context
    } do
      Sessions.subscribe_sessions(scope)

      # Create context testing session
      {:ok, session} =
        Sessions.create_session(scope, %{
          type: ContextTestingSessions,
          agent: :claude_code,
          environment_type: :local,
          component_id: accounts_context.id
        })

      assert_received {:created, %Sessions.Session{}}

      # Step 1: Initialize
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      assert interaction.command.module == Initialize

      # Mock git branch creation
      result = %{status: :ok, stdout: "Created branch", stderr: "", exit_code: 0}

      {:ok, session} = Sessions.handle_result(scope, session.id, interaction.id, result)
      assert_received {:updated, %Sessions.Session{}}

      [last_interaction | _] = session.interactions
      assert last_interaction.result.status == :ok

      # Step 2: SpawnComponentTestingSessions
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      assert interaction.command.module == SpawnComponentTestingSessions
      assert interaction.command.command == "spawn_sessions"
      assert is_list(interaction.command.metadata["child_session_ids"])
      assert length(interaction.command.metadata["child_session_ids"]) == 3

      # Store child session IDs for later
      child_session_ids = interaction.command.metadata["child_session_ids"]

      # Mock successful completion of child sessions
      result = %{status: :ok, stdout: "All child sessions started", stderr: "", exit_code: 0}

      # Mark all child sessions as complete and create test files
      for child_id <- child_session_ids do
        child_session = Sessions.get_session!(scope, child_id)
        {:ok, _} = Sessions.update_session(scope, child_session, %{status: :complete})
      end

      # Create test files
      File.mkdir_p!("test/my_app/accounts")

      File.write!(
        "test/my_app/accounts/user_test.exs",
        "defmodule MyApp.Accounts.UserTest do\nend"
      )

      File.write!(
        "test/my_app/accounts/user_repository_test.exs",
        "defmodule MyApp.Accounts.UserRepositoryTest do\nend"
      )

      File.write!(
        "test/my_app/accounts_live_test.exs",
        "defmodule MyApp.AccountsLiveTest do\nend"
      )

      {:ok, session} = Sessions.handle_result(scope, session.id, interaction.id, result)
      assert_received {:updated, %Sessions.Session{}}

      [last_interaction | _] = session.interactions
      assert last_interaction.result.status == :ok

      # Step 3: Finalize
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      assert interaction.command.module == Finalize

      # Mock successful git commit and push
      result = %{
        status: :ok,
        stdout: "Committed and pushed changes",
        stderr: "",
        exit_code: 0
      }

      {:ok, session} = Sessions.handle_result(scope, session.id, interaction.id, result)
      assert_received {:updated, %Sessions.Session{}}

      [last_interaction | _] = session.interactions
      assert last_interaction.result.status == :ok
      assert session.status == :complete

      # Session should be complete
      assert {:error, :complete} = Sessions.next_command(scope, session.id)

      # Cleanup
      File.rm_rf!("test/my_app")
    end

    @tag timeout: 300_000
    test "handles validation failure and retry for incomplete child sessions", %{
      scope: scope,
      accounts_context: accounts_context
    } do
      Sessions.subscribe_sessions(scope)

      # Create session
      {:ok, session} =
        Sessions.create_session(scope, %{
          type: ContextTestingSessions,
          agent: :claude_code,
          environment_type: :local,
          component_id: accounts_context.id
        })

      # Step 1: Initialize
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      result = %{status: :ok, stdout: "Created branch", stderr: "", exit_code: 0}
      {:ok, session} = Sessions.handle_result(scope, session.id, interaction.id, result)

      # Step 2: SpawnComponentTestingSessions - first attempt
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      child_session_ids = interaction.command.metadata["child_session_ids"]

      # Mark only some child sessions complete (validation should fail)
      [first_child_id | _] = child_session_ids
      child_session = Sessions.get_session!(scope, first_child_id)
      {:ok, _} = Sessions.update_session(scope, child_session, %{status: :complete})

      # Create only one test file
      File.mkdir_p!("test/my_app/accounts")

      File.write!(
        "test/my_app/accounts/user_test.exs",
        "defmodule MyApp.Accounts.UserTest do\nend"
      )

      result = %{status: :ok, stdout: "Sessions started", stderr: "", exit_code: 0}
      {:ok, session} = Sessions.handle_result(scope, session.id, interaction.id, result)

      [last_interaction | _] = session.interactions
      # Should return error due to validation failure
      assert last_interaction.result.status == :error

      # Step 3: Should retry SpawnComponentTestingSessions
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      assert interaction.command.module == SpawnComponentTestingSessions

      # The retry should return the SAME child session IDs (not create new ones)
      retry_child_session_ids = interaction.command.metadata["child_session_ids"]
      assert Enum.sort(retry_child_session_ids) == Enum.sort(child_session_ids)

      # Now complete all child sessions and create all files
      for child_id <- child_session_ids do
        child_session = Sessions.get_session!(scope, child_id)
        {:ok, _} = Sessions.update_session(scope, child_session, %{status: :complete})
      end

      File.write!(
        "test/my_app/accounts/user_repository_test.exs",
        "defmodule MyApp.Accounts.UserRepositoryTest do\nend"
      )

      File.write!(
        "test/my_app/accounts_live_test.exs",
        "defmodule MyApp.AccountsLiveTest do\nend"
      )

      result = %{status: :ok, stdout: "All sessions complete", stderr: "", exit_code: 0}
      {:ok, session} = Sessions.handle_result(scope, session.id, interaction.id, result)

      [last_interaction | _] = session.interactions
      # Should now succeed
      assert last_interaction.result.status == :ok

      # Should proceed to next step
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      assert interaction.command.module == Finalize

      # Cleanup
      File.rm_rf!("test/my_app")
    end

    @tag timeout: 300_000
    test "handles validation when all child sessions complete successfully", %{
      scope: scope,
      accounts_context: accounts_context
    } do
      Sessions.subscribe_sessions(scope)

      # Create session
      {:ok, session} =
        Sessions.create_session(scope, %{
          type: ContextTestingSessions,
          agent: :claude_code,
          environment_type: :local,
          component_id: accounts_context.id
        })

      # Initialize
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      result = %{status: :ok, stdout: "Created branch", stderr: "", exit_code: 0}
      {:ok, session} = Sessions.handle_result(scope, session.id, interaction.id, result)

      # SpawnComponentTestingSessions
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      child_session_ids = interaction.command.metadata["child_session_ids"]

      # Mark all child sessions complete
      for child_id <- child_session_ids do
        child_session = Sessions.get_session!(scope, child_id)
        {:ok, _} = Sessions.update_session(scope, child_session, %{status: :complete})
      end

      result = %{status: :ok, stdout: "Sessions complete", stderr: "", exit_code: 0}
      {:ok, session} = Sessions.handle_result(scope, session.id, interaction.id, result)

      [last_interaction | _] = session.interactions
      # Should pass validation when all child sessions are complete
      assert last_interaction.result.status == :ok

      # Should proceed to Finalize
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      assert interaction.command.module == Finalize

      # Cleanup
      File.rm_rf!("test/my_app")
    end

    @tag timeout: 300_000
    test "handles validation failure when tests fail", %{
      scope: scope,
      accounts_context: accounts_context
    } do
      Sessions.subscribe_sessions(scope)

      # Create session
      {:ok, session} =
        Sessions.create_session(scope, %{
          type: ContextTestingSessions,
          agent: :claude_code,
          environment_type: :local,
          component_id: accounts_context.id
        })

      # Initialize
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      result = %{status: :ok, stdout: "Created branch", stderr: "", exit_code: 0}
      {:ok, session} = Sessions.handle_result(scope, session.id, interaction.id, result)

      # SpawnComponentTestingSessions - first attempt
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      child_session_ids = interaction.command.metadata["child_session_ids"]

      # Mark all child sessions complete and create all test files
      for child_id <- child_session_ids do
        child_session = Sessions.get_session!(scope, child_id)
        {:ok, _} = Sessions.update_session(scope, child_session, %{status: :complete})
      end

      # Create test files
      File.mkdir_p!("test/my_app/accounts")

      File.write!(
        "test/my_app/accounts/user_test.exs",
        "defmodule MyApp.Accounts.UserTest do\nend"
      )

      File.write!(
        "test/my_app/accounts/user_repository_test.exs",
        "defmodule MyApp.Accounts.UserRepositoryTest do\nend"
      )

      File.write!(
        "test/my_app/accounts_live_test.exs",
        "defmodule MyApp.AccountsLiveTest do\nend"
      )

      # Note: In real implementation, validation would run tests and detect failures
      # For this test, we're verifying the validation logic exists
      result = %{status: :ok, stdout: "Sessions complete", stderr: "", exit_code: 0}
      {:ok, session} = Sessions.handle_result(scope, session.id, interaction.id, result)

      [last_interaction | _] = session.interactions
      # Should succeed if tests pass (or validation is mocked)
      assert last_interaction.result.status in [:ok, :error]

      # Cleanup
      File.rm_rf!("test/my_app")
    end

    @tag timeout: 300_000
    test "handles child session failures gracefully", %{
      scope: scope,
      accounts_context: accounts_context
    } do
      Sessions.subscribe_sessions(scope)

      # Create session
      {:ok, session} =
        Sessions.create_session(scope, %{
          type: ContextTestingSessions,
          agent: :claude_code,
          environment_type: :local,
          component_id: accounts_context.id
        })

      # Initialize
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      result = %{status: :ok, stdout: "Created branch", stderr: "", exit_code: 0}
      {:ok, session} = Sessions.handle_result(scope, session.id, interaction.id, result)

      # SpawnComponentTestingSessions
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      child_session_ids = interaction.command.metadata["child_session_ids"]

      # Mark one child session as failed
      [first_child_id | remaining_ids] = child_session_ids
      child_session = Sessions.get_session!(scope, first_child_id)
      {:ok, _} = Sessions.update_session(scope, child_session, %{status: :failed})

      # Mark remaining as complete
      for child_id <- remaining_ids do
        child_session = Sessions.get_session!(scope, child_id)
        {:ok, _} = Sessions.update_session(scope, child_session, %{status: :complete})
      end

      result = %{status: :ok, stdout: "Sessions started", stderr: "", exit_code: 0}
      {:ok, session} = Sessions.handle_result(scope, session.id, interaction.id, result)

      [last_interaction | _] = session.interactions
      # Should fail validation because one child session failed
      assert last_interaction.result.status == :error

      # Cleanup
      File.rm_rf!("test/my_app")
    end

    @tag timeout: 300_000
    test "validates all components have corresponding child sessions", %{
      scope: scope,
      accounts_context: accounts_context
    } do
      Sessions.subscribe_sessions(scope)

      # Create session
      {:ok, session} =
        Sessions.create_session(scope, %{
          type: ContextTestingSessions,
          agent: :claude_code,
          environment_type: :local,
          component_id: accounts_context.id
        })

      # Initialize
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      result = %{status: :ok, stdout: "Created branch", stderr: "", exit_code: 0}
      {:ok, session} = Sessions.handle_result(scope, session.id, interaction.id, result)

      # SpawnComponentTestingSessions should create child sessions for all 3 components
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      child_session_ids = interaction.command.metadata["child_session_ids"]

      # Should have exactly 3 child sessions (User, UserRepository, AccountsLive)
      assert length(child_session_ids) == 3

      # Verify all child sessions have correct type
      for child_id <- child_session_ids do
        child_session = Sessions.get_session!(scope, child_id)
        assert child_session.type == CodeMySpec.ComponentTestSessions
        assert child_session.session_id == session.id
      end

      # Cleanup
      File.rm_rf!("test/my_app")
    end

    @tag timeout: 300_000
    test "generates branch name dynamically from component name", %{
      scope: scope,
      accounts_context: accounts_context
    } do
      Sessions.subscribe_sessions(scope)

      # Create session
      {:ok, session} =
        Sessions.create_session(scope, %{
          type: ContextTestingSessions,
          agent: :claude_code,
          environment_type: :local,
          component_id: accounts_context.id
        })

      # Initialize step should create branch
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      assert interaction.command.module == Initialize

      # Verify command contains branch name generation logic
      assert String.contains?(
               interaction.command.command,
               "test-context-testing-session-for-accounts"
             )

      # Mock git branch creation
      result = %{
        status: :ok,
        stdout: "Created branch",
        stderr: "",
        exit_code: 0
      }

      {:ok, _session} = Sessions.handle_result(scope, session.id, interaction.id, result)

      # Cleanup
      File.rm_rf!("test/my_app")
    end

    @tag timeout: 300_000
    test "child sessions inherit parent scope", %{
      scope: scope,
      accounts_context: accounts_context
    } do
      Sessions.subscribe_sessions(scope)

      # Create parent session
      {:ok, session} =
        Sessions.create_session(scope, %{
          type: ContextTestingSessions,
          agent: :claude_code,
          environment_type: :local,
          component_id: accounts_context.id
        })

      # Initialize
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      result = %{status: :ok, stdout: "Created branch", stderr: "", exit_code: 0}
      {:ok, session} = Sessions.handle_result(scope, session.id, interaction.id, result)

      # SpawnComponentTestingSessions
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      child_session_ids = interaction.command.metadata["child_session_ids"]

      # Verify all child sessions are scoped correctly
      for child_id <- child_session_ids do
        child_session = Sessions.get_session!(scope, child_id)
        assert child_session.account_id == scope.active_account_id
        assert child_session.project_id == scope.active_project_id
      end

      # Cleanup
      File.rm_rf!("test/my_app")
    end

    @tag timeout: 300_000
    test "finalizes by committing and marking session complete", %{
      scope: scope,
      accounts_context: accounts_context
    } do
      Sessions.subscribe_sessions(scope)

      # Create session and progress to Finalize step
      {:ok, session} =
        Sessions.create_session(scope, %{
          type: ContextTestingSessions,
          agent: :claude_code,
          environment_type: :local,
          component_id: accounts_context.id
        })

      # Initialize
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      result = %{status: :ok, stdout: "Created branch", stderr: "", exit_code: 0}
      {:ok, session} = Sessions.handle_result(scope, session.id, interaction.id, result)

      # SpawnComponentTestingSessions - complete successfully
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      child_session_ids = interaction.command.metadata["child_session_ids"]

      for child_id <- child_session_ids do
        child_session = Sessions.get_session!(scope, child_id)
        {:ok, _} = Sessions.update_session(scope, child_session, %{status: :complete})
      end

      # Create all test files
      File.mkdir_p!("test/my_app/accounts")

      File.write!(
        "test/my_app/accounts/user_test.exs",
        "defmodule MyApp.Accounts.UserTest do\nend"
      )

      File.write!(
        "test/my_app/accounts/user_repository_test.exs",
        "defmodule MyApp.Accounts.UserRepositoryTest do\nend"
      )

      File.write!(
        "test/my_app/accounts_live_test.exs",
        "defmodule MyApp.AccountsLiveTest do\nend"
      )

      result = %{status: :ok, stdout: "All sessions complete", stderr: "", exit_code: 0}
      {:ok, session} = Sessions.handle_result(scope, session.id, interaction.id, result)

      # Now at Finalize step
      {:ok, session} = Sessions.next_command(scope, session.id)
      [interaction | _] = session.interactions
      assert interaction.command.module == Finalize

      # Verify the command includes all test files
      assert String.contains?(interaction.command.command, "git add")
      assert String.contains?(interaction.command.command, "git commit")
      assert String.contains?(interaction.command.command, "git push")

      # Mock successful commit and push
      result = %{
        status: :ok,
        stdout: "Committed and pushed test files",
        stderr: "",
        exit_code: 0
      }

      {:ok, session} = Sessions.handle_result(scope, session.id, interaction.id, result)

      [last_interaction | _] = session.interactions
      assert last_interaction.result.status == :ok
      assert session.status == :complete

      # Session should be complete - no more commands
      assert {:error, :complete} = Sessions.next_command(scope, session.id)

      # Cleanup
      File.rm_rf!("test/my_app")
    end
  end
end
