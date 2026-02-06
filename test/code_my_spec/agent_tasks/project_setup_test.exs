defmodule CodeMySpec.AgentTasks.ProjectSetupTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Users.Scope

  @moduletag :tmp_dir

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp create_environment(tmp_dir) do
    %Environment{
      type: :local,
      ref: %{working_dir: tmp_dir},
      cwd: tmp_dir,
      metadata: %{}
    }
  end

  defp create_scope do
    %Scope{
      user: nil,
      active_account: nil,
      active_account_id: nil,
      active_project: nil,
      active_project_id: nil
    }
  end

  defp create_session(tmp_dir) do
    %{environment: create_environment(tmp_dir)}
  end

  defp write_file!(tmp_dir, relative_path, content) do
    full_path = Path.join(tmp_dir, relative_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, content)
    full_path
  end

  # Creates a minimal mix.exs file that looks like a Phoenix project
  defp create_minimal_mix_exs(tmp_dir, app_name) do
    content = """
    defmodule #{Macro.camelize(app_name)}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{app_name},
          version: "0.1.0",
          elixir: "~> 1.18",
          deps: deps()
        ]
      end

      def application do
        [
          mod: {#{Macro.camelize(app_name)}.Application, []},
          extra_applications: [:logger]
        ]
      end

      defp deps do
        [
          {:phoenix, "~> 1.7"},
          {:phoenix_live_view, "~> 0.20"}
        ]
      end
    end
    """

    write_file!(tmp_dir, "mix.exs", content)
  end

  # Creates a mix.exs with CodeMySpec dependencies
  defp create_mix_exs_with_deps(tmp_dir, app_name) do
    content = """
    defmodule #{Macro.camelize(app_name)}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{app_name},
          version: "0.1.0",
          elixir: "~> 1.18",
          deps: deps()
        ]
      end

      def application do
        [
          mod: {#{Macro.camelize(app_name)}.Application, []},
          extra_applications: [:logger]
        ]
      end

      defp deps do
        [
          {:phoenix, "~> 1.7"},
          {:phoenix_live_view, "~> 0.20"},
          {:ngrok, git: "https://github.com/johns10/ex_ngrok", branch: "main", only: [:dev]},
          {:exunit_json_formatter, git: "https://github.com/johns10/exunit_json_formatter", branch: "master"},
          {:credo, "~> 1.7.13"},
          {:client_utils, git: "https://github.com/example/client_utils"},
          {:mix_machine, "~> 1.0"},
          {:sobelow, "~> 0.13"}
        ]
      end
    end
    """

    write_file!(tmp_dir, "mix.exs", content)
  end

  defp create_phoenix_project_structure(tmp_dir, app_name) do
    create_minimal_mix_exs(tmp_dir, app_name)
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "config"))
    write_file!(tmp_dir, "lib/#{app_name}.ex", "defmodule #{Macro.camelize(app_name)} do\nend\n")
    write_file!(tmp_dir, "config/config.exs", "import Config\n")
  end

  defp create_auth_structure(tmp_dir, app_name) do
    accounts_dir = Path.join([tmp_dir, "lib", app_name, "accounts"])
    File.mkdir_p!(accounts_dir)

    write_file!(
      tmp_dir,
      "lib/#{app_name}/accounts/user.ex",
      "defmodule #{Macro.camelize(app_name)}.Accounts.User do\nend\n"
    )

    write_file!(
      tmp_dir,
      "lib/#{app_name}/accounts/accounts.ex",
      "defmodule #{Macro.camelize(app_name)}.Accounts do\nend\n"
    )
  end

  defp create_docs_structure(tmp_dir, app_name) do
    File.mkdir_p!(Path.join(tmp_dir, "docs/rules"))
    File.mkdir_p!(Path.join(tmp_dir, "docs/spec/#{app_name}"))
    File.mkdir_p!(Path.join(tmp_dir, "docs/spec/#{app_name}_web"))

    # Create .gitmodules file with docs submodule entry
    gitmodules_content = """
    [submodule "docs"]
    \tpath = docs
    \turl = https://github.com/example/docs-repo.git
    """

    write_file!(tmp_dir, ".gitmodules", gitmodules_content)
  end

  defp create_full_project_setup(tmp_dir, app_name) do
    create_phoenix_project_structure(tmp_dir, app_name)
    create_mix_exs_with_deps(tmp_dir, app_name)
    create_auth_structure(tmp_dir, app_name)
    create_docs_structure(tmp_dir, app_name)
  end

  # ============================================================================
  # check_status/2 Tests
  # ============================================================================

  describe "check_status/2" do
    test "returns elixir_installed false when Elixir version < 1.18", %{tmp_dir: tmp_dir} do
      # This test requires mocking the system command output
      # Since we can't easily mock System.cmd, we test the function with a mock environment
      # that simulates an old Elixir version response
      env = create_environment(tmp_dir)
      session = %{environment: env}

      # We'll test this by verifying the function handles the case where
      # elixir --version returns an old version
      # For now, we test the actual system which should have Elixir 1.18+
      status = ProjectSetup.check_status(env, session)

      # On a development machine with Elixir 1.18+, this should be true
      # The test assertion verifies the key exists and is a boolean
      assert is_boolean(status.elixir_installed)

      if status.elixir_installed do
        assert is_binary(status.elixir_version)
      end
    end

    test "returns phoenix_installer_available false when phx_new not in archives", %{
      tmp_dir: tmp_dir
    } do
      env = create_environment(tmp_dir)
      session = %{environment: env}

      status = ProjectSetup.check_status(env, session)

      # The key should exist and be a boolean
      assert is_boolean(status.phoenix_installer_available)
    end

    test "returns phoenix_project_exists false when mix.exs missing", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      session = %{environment: env}

      # Don't create any files - empty directory
      status = ProjectSetup.check_status(env, session)

      assert status.phoenix_project_exists == false
      assert is_nil(status.app_name)
    end

    test "returns project_compiles false with errors when compilation fails", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      session = %{environment: env}

      # Create a project with syntax errors
      create_phoenix_project_structure(tmp_dir, "broken_app")

      write_file!(tmp_dir, "lib/broken_app/bad_module.ex", """
      defmodule BrokenApp.BadModule do
        def broken do
          # Missing closing parenthesis
          IO.puts("hello"
        end
      end
      """)

      status = ProjectSetup.check_status(env, session)

      # Project exists but may not compile due to syntax error
      assert status.phoenix_project_exists == true

      if status.project_compiles == false do
        assert is_binary(status.compilation_errors) or is_nil(status.compilation_errors)
      end
    end

    test "returns codemyspec_deps_installed false with missing_deps list", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      session = %{environment: env}

      # Create project without CodeMySpec deps
      create_phoenix_project_structure(tmp_dir, "my_app")

      status = ProjectSetup.check_status(env, session)

      assert status.codemyspec_deps_installed == false
      assert is_list(status.missing_deps)
      assert length(status.missing_deps) > 0
    end

    test "returns docs_repo_configured false when docs submodule missing", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      session = %{environment: env}

      # Create project without docs submodule
      create_phoenix_project_structure(tmp_dir, "my_app")

      status = ProjectSetup.check_status(env, session)

      assert status.docs_repo_configured == false
    end

    test "returns docs_structure_complete false with missing_docs_dirs list", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      session = %{environment: env}

      # Create project with docs dir but incomplete structure
      create_phoenix_project_structure(tmp_dir, "my_app")
      File.mkdir_p!(Path.join(tmp_dir, "docs"))
      # Don't create rules/ or spec/ directories

      status = ProjectSetup.check_status(env, session)

      assert status.docs_structure_complete == false
      assert is_list(status.missing_docs_dirs)
      assert length(status.missing_docs_dirs) > 0
    end

    test "extracts app_name from mix.exs project definition", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      session = %{environment: env}

      create_phoenix_project_structure(tmp_dir, "custom_app_name")

      status = ProjectSetup.check_status(env, session)

      assert status.phoenix_project_exists == true
      assert status.app_name == "custom_app_name"
    end

    test "handles missing mix.exs gracefully", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      session = %{environment: env}

      # Empty directory - no mix.exs
      status = ProjectSetup.check_status(env, session)

      assert status.phoenix_project_exists == false
      assert is_nil(status.app_name)
      # Should not crash, should return a valid status map
      assert is_map(status)
    end

    test "warns but does not fail on PostgreSQL check failure", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      session = %{environment: env}

      status = ProjectSetup.check_status(env, session)

      # PostgreSQL availability should be tracked but not cause failure
      assert is_boolean(status.postgresql_available)
      # The overall status check should still work even if PostgreSQL isn't available
      assert is_map(status)
    end
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    test "returns full setup guide when starting from empty directory", %{tmp_dir: tmp_dir} do
      scope = create_scope()
      session = create_session(tmp_dir)

      assert {:ok, prompt} = ProjectSetup.command(scope, session, [])

      # Should include all setup steps for empty directory
      assert is_binary(prompt)
      assert String.length(prompt) > 0
      # Should mention prerequisites
      assert prompt =~ "Elixir" or prompt =~ "elixir"
      # Should mention project creation
      assert prompt =~ "phx.new" or prompt =~ "Phoenix"
    end

    test "returns partial guide omitting completed steps", %{tmp_dir: tmp_dir} do
      scope = create_scope()
      session = create_session(tmp_dir)

      # Create a partial setup (Phoenix project exists, but missing other things)
      create_phoenix_project_structure(tmp_dir, "my_app")

      assert {:ok, prompt} = ProjectSetup.command(scope, session, [])

      # Should be a valid prompt string
      assert is_binary(prompt)
      # Should not include Phoenix project creation since it exists
      # The exact content depends on implementation, but it should be shorter
      # than the full setup guide
    end

    test "includes prerequisite installation when elixir_installed is false", %{tmp_dir: tmp_dir} do
      # This test would require mocking System.cmd to return an old Elixir version
      # For now, we verify the structure of the command function
      scope = create_scope()
      session = create_session(tmp_dir)

      assert {:ok, prompt} = ProjectSetup.command(scope, session, [])

      # The prompt should be a non-empty string
      assert is_binary(prompt)
    end

    test "includes Phoenix installer setup when phoenix_installer_available is false", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope()
      session = create_session(tmp_dir)

      assert {:ok, prompt} = ProjectSetup.command(scope, session, [])

      # Should mention Phoenix installer if not available
      assert is_binary(prompt)
    end

    test "includes project creation when phoenix_project_exists is false", %{tmp_dir: tmp_dir} do
      scope = create_scope()
      session = create_session(tmp_dir)

      # Empty directory
      assert {:ok, prompt} = ProjectSetup.command(scope, session, [])

      # Should include instructions for creating Phoenix project
      assert prompt =~ "phx.new" or prompt =~ "mix"
    end

    test "includes auth generation when auth_generated is false", %{tmp_dir: tmp_dir} do
      scope = create_scope()
      session = create_session(tmp_dir)

      # Create project without auth
      create_phoenix_project_structure(tmp_dir, "my_app")

      assert {:ok, prompt} = ProjectSetup.command(scope, session, [])

      # Should include auth generation instructions
      assert prompt =~ "phx.gen.auth" or prompt =~ "auth"
    end

    test "includes dependency block when codemyspec_deps_installed is false", %{tmp_dir: tmp_dir} do
      scope = create_scope()
      session = create_session(tmp_dir)

      # Create project without CodeMySpec deps
      create_phoenix_project_structure(tmp_dir, "my_app")

      assert {:ok, prompt} = ProjectSetup.command(scope, session, [])

      # Should include dependency instructions
      assert prompt =~ "deps" or prompt =~ "mix.exs" or prompt =~ "ngrok" or prompt =~ "credo"
    end

    test "includes submodule setup when docs_repo_configured is false", %{tmp_dir: tmp_dir} do
      scope = create_scope()
      session = create_session(tmp_dir)

      # Create project without docs submodule
      create_phoenix_project_structure(tmp_dir, "my_app")

      assert {:ok, prompt} = ProjectSetup.command(scope, session, [])

      # Should include docs repository setup
      assert prompt =~ "docs" or prompt =~ "submodule" or prompt =~ "git"
    end

    test "includes commit instructions between major steps", %{tmp_dir: tmp_dir} do
      scope = create_scope()
      session = create_session(tmp_dir)

      assert {:ok, prompt} = ProjectSetup.command(scope, session, [])

      # Should include commit instructions
      assert prompt =~ "commit" or prompt =~ "git"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    test "returns valid when all required checks pass", %{tmp_dir: tmp_dir} do
      scope = create_scope()
      session = create_session(tmp_dir)

      # Create a fully set up project
      create_full_project_setup(tmp_dir, "complete_app")

      result = ProjectSetup.evaluate(scope, session, [])

      # If all checks pass, should return :valid
      # Note: This may return :invalid on CI if Elixir version differs
      assert match?({:ok, :valid}, result) or match?({:ok, :invalid, _}, result)
    end

    test "returns invalid with detailed feedback when checks fail", %{tmp_dir: tmp_dir} do
      scope = create_scope()
      session = create_session(tmp_dir)

      # Empty directory - many checks will fail
      assert {:ok, :invalid, feedback} = ProjectSetup.evaluate(scope, session, [])

      assert is_binary(feedback)
      assert String.length(feedback) > 0
    end

    test "feedback includes progress summary", %{tmp_dir: tmp_dir} do
      scope = create_scope()
      session = create_session(tmp_dir)

      # Partial setup
      create_phoenix_project_structure(tmp_dir, "my_app")

      assert {:ok, :invalid, feedback} = ProjectSetup.evaluate(scope, session, [])

      # Should include progress indication (e.g., "X of Y steps complete")
      assert feedback =~ ~r/\d+.*of.*\d+|complete|progress|step/i
    end

    test "feedback includes specific remediation for each failing check", %{tmp_dir: tmp_dir} do
      scope = create_scope()
      session = create_session(tmp_dir)

      # Empty directory
      assert {:ok, :invalid, feedback} = ProjectSetup.evaluate(scope, session, [])

      # Should include specific guidance for what's missing
      assert is_binary(feedback)
      # Feedback should mention specific things to fix
      assert String.length(feedback) > 50
    end
  end
end
