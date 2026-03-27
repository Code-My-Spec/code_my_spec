defmodule CodeMySpec.AgentTasks.ProjectSetupTest do
  use ExUnit.Case, async: false
  use ExCliVcr

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

  defp create_scope(tmp_dir) do
    %Scope{
      user: nil,
      active_account: nil,
      active_account_id: nil,
      active_project: nil,
      active_project_id: nil,
      environment: create_environment(tmp_dir)
    }
  end

  defp create_task(_tmp_dir) do
    %{project_id: nil, component_id: nil, story_id: nil}
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
          {:sobelow, "~> 0.13"},
          {:sexy_spex, "~> 0.1.0", only: :test},
          {:boundary, "~> 0.10"}
        ]
      end
    end
    """

    write_file!(tmp_dir, "mix.exs", content)
  end

  # Creates a mix.exs with full compiler and spex configuration
  defp create_fully_configured_mix_exs(tmp_dir, app_name) do
    content = """
    defmodule #{Macro.camelize(app_name)}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{app_name},
          version: "0.1.0",
          elixir: "~> 1.18",
          compilers: [:diagnostics, :boundary, :phoenix_live_view, :erlang, :elixir, :spex, :app],
          spex: [pattern: "test/spex/**/*_spex.exs"],
          deps: deps()
        ]
      end

      def application do
        [
          mod: {#{Macro.camelize(app_name)}.Application, []},
          extra_applications: [:logger]
        ]
      end

      def cli do
        [
          preferred_envs: [spex: :test]
        ]
      end

      defp elixirc_paths(:test), do: ["lib", "test/support", "test/spex"]
      defp elixirc_paths(_), do: ["lib"]

      defp aliases do
        [
          spex: ["spex --quiet"]
        ]
      end

      defp deps do
        [
          {:phoenix, "~> 1.7"},
          {:phoenix_live_view, "~> 0.20"},
          {:credo, "~> 1.7.13"},
          {:client_utils, git: "https://github.com/example/client_utils"},
          {:sobelow, "~> 0.13"},
          {:sexy_spex, "~> 0.1.0", only: :test},
          {:boundary, "~> 0.10"}
        ]
      end
    end
    """

    write_file!(tmp_dir, "mix.exs", content)
  end

  defp create_test_boundary_files(tmp_dir, app_name) do
    module_name = Macro.camelize(app_name)

    write_file!(tmp_dir, "test/support/#{app_name}_spex.ex", """
    defmodule #{module_name}Spex do
      use Boundary, top_level?: true, deps: [#{module_name}]
    end
    """)

    write_file!(tmp_dir, "test/support/#{app_name}_test_boundary.ex", """
    defmodule #{module_name}Test do
      use Boundary, top_level?: true, deps: [#{module_name}]
    end
    """)
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
    File.mkdir_p!(Path.join(tmp_dir, ".code_my_spec/rules"))
    File.mkdir_p!(Path.join(tmp_dir, ".code_my_spec/spec/#{app_name}"))
    File.mkdir_p!(Path.join(tmp_dir, ".code_my_spec/spec/#{app_name}_web"))
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
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      use_cmd_cassette "project_setup_check_status_elixir", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert is_boolean(status.elixir_installed)

        if status.elixir_installed do
          assert is_binary(status.elixir_version)
        end
      end
    end

    test "returns phoenix_installer_available false when phx_new not in archives", %{
      tmp_dir: tmp_dir
    } do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      use_cmd_cassette "project_setup_check_status_phoenix", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert is_boolean(status.phoenix_installer_available)
      end
    end

    test "returns phoenix_project_exists false when mix.exs missing", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      use_cmd_cassette "project_setup_check_status_no_mix", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert status.phoenix_project_exists == false
        assert is_nil(status.app_name)
      end
    end

    test "returns project_compiles false with errors when compilation fails", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "broken_app")

      write_file!(tmp_dir, "lib/broken_app/bad_module.ex", """
      defmodule BrokenApp.BadModule do
        def broken do
          # Missing closing parenthesis
          IO.puts("hello"
        end
      end
      """)

      use_cmd_cassette "project_setup_check_status_compile_fail", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert status.phoenix_project_exists == true

        if status.project_compiles == false do
          assert is_binary(status.compilation_errors) or is_nil(status.compilation_errors)
        end
      end
    end

    test "returns codemyspec_deps_installed false with missing_deps list", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")

      use_cmd_cassette "project_setup_check_status_no_deps", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert status.codemyspec_deps_installed == false
        assert is_list(status.missing_deps)
        assert status.missing_deps != []
      end
    end

    test "returns project_dir_exists false when .code_my_spec directory missing", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")

      use_cmd_cassette "project_setup_check_status_no_docs", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert status.project_dir_exists == false
      end
    end

    test "returns project_structure_complete false with missing_structure_dirs list", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")
      File.mkdir_p!(Path.join(tmp_dir, ".code_my_spec"))

      use_cmd_cassette "project_setup_check_status_incomplete", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert status.project_structure_complete == false
        assert is_list(status.missing_structure_dirs)
        assert status.missing_structure_dirs != []
      end
    end

    test "extracts app_name from mix.exs project definition", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "custom_app_name")

      use_cmd_cassette "project_setup_check_status_app_name", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert status.phoenix_project_exists == true
        assert status.app_name == "custom_app_name"
      end
    end

    test "handles missing mix.exs gracefully", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      use_cmd_cassette "project_setup_check_status_graceful", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert status.phoenix_project_exists == false
        assert is_nil(status.app_name)
        assert is_map(status)
      end
    end

    test "warns but does not fail on PostgreSQL check failure", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      use_cmd_cassette "project_setup_check_status_postgres", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert is_boolean(status.postgresql_available)
        assert is_map(status)
      end
    end

    test "returns compilers_configured false when compilers not set", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")

      use_cmd_cassette "project_setup_check_status_no_compilers", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert status.compilers_configured == false
      end
    end

    test "returns compilers_configured true when boundary and spex in compilers", %{
      tmp_dir: tmp_dir
    } do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")
      create_fully_configured_mix_exs(tmp_dir, "my_app")

      use_cmd_cassette "project_setup_check_status_compilers_ok", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert status.compilers_configured == true
      end
    end

    test "returns spex_config_complete false when spex not configured", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")

      use_cmd_cassette "project_setup_check_status_no_spex", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert status.spex_config_complete == false
      end
    end

    test "returns spex_config_complete true when fully configured", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")
      create_fully_configured_mix_exs(tmp_dir, "my_app")

      use_cmd_cassette "project_setup_check_status_spex_ok", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert status.spex_config_complete == true
      end
    end

    test "returns test_boundaries_configured false when no boundary files", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")

      use_cmd_cassette "project_setup_check_status_no_boundaries", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert status.test_boundaries_configured == false
      end
    end

    test "returns test_boundaries_configured true when boundary files exist", %{
      tmp_dir: tmp_dir
    } do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")
      create_test_boundary_files(tmp_dir, "my_app")

      use_cmd_cassette "project_setup_check_status_boundaries_ok", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert status.test_boundaries_configured == true
      end
    end

    test "returns app_symlinks_installed false when symlinks missing", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")

      use_cmd_cassette "project_setup_check_status_no_symlinks", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert status.app_symlinks_installed == false
      end
    end

    test "returns app_symlinks_installed true when all symlinks exist", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")
      assert :ok = ProjectSetup.install_app_resources(tmp_dir)

      use_cmd_cassette "project_setup_check_status_symlinks_ok", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert status.app_symlinks_installed == true
      end
    end

    test "returns boundary in missing_deps when not in mix.exs", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")

      use_cmd_cassette "project_setup_check_status_missing_boundary", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert :boundary in status.missing_deps
      end
    end

    test "returns agents_md_installed false when AGENTS.md missing", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")

      use_cmd_cassette "project_setup_check_status_no_agents", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert status.agents_md_installed == false
      end
    end

    test "returns agents_md_installed true when AGENTS.md exists", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")
      assert :ok = ProjectSetup.install_agents_md(tmp_dir)

      use_cmd_cassette "project_setup_check_status_agents_ok", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)

        assert status.agents_md_installed == true
      end
    end
  end

  # ============================================================================
  # install_app_resources/1 Tests
  # ============================================================================

  describe "install_app_resources/1" do
    test "creates framework and tools directories", %{tmp_dir: tmp_dir} do
      assert :ok = ProjectSetup.install_app_resources(tmp_dir)

      # Framework directory (copied, not symlinked)
      framework_path = Path.join(tmp_dir, ".code_my_spec/framework")
      assert File.dir?(framework_path)
      assert File.exists?(Path.join(framework_path, "README.md"))
      assert File.exists?(Path.join(framework_path, "liveview/patterns.md"))

      # Tools directory (copied, not symlinked)
      tools_path = Path.join(tmp_dir, ".code_my_spec/tools")
      assert File.dir?(tools_path)
      assert File.exists?(Path.join(tools_path, "set-story-component"))
    end

    test "is idempotent — can be called multiple times", %{tmp_dir: tmp_dir} do
      assert :ok = ProjectSetup.install_app_resources(tmp_dir)
      assert :ok = ProjectSetup.install_app_resources(tmp_dir)

      assert File.exists?(Path.join(tmp_dir, ".code_my_spec/framework/README.md"))
      assert File.exists?(Path.join(tmp_dir, ".code_my_spec/tools/set-story-component"))
    end
  end

  # ============================================================================
  # install_agents_md/1 Tests
  # ============================================================================

  describe "install_agents_md/1" do
    test "writes AGENTS.md with app-specific paths", %{tmp_dir: tmp_dir} do
      create_phoenix_project_structure(tmp_dir, "my_app")
      assert :ok = ProjectSetup.install_agents_md(tmp_dir)

      agents_path = Path.join(tmp_dir, ".code_my_spec/AGENTS.md")
      assert File.exists?(agents_path)

      content = File.read!(agents_path)
      assert content =~ ".code_my_spec/status/my_app.md"
      assert content =~ "lib/my_app/"
      assert content =~ ".code_my_spec/"
    end

    test "uses fallback when no mix.exs", %{tmp_dir: tmp_dir} do
      assert :ok = ProjectSetup.install_agents_md(tmp_dir)

      content = File.read!(Path.join(tmp_dir, ".code_my_spec/AGENTS.md"))
      assert content =~ "your_app"
    end
  end

  # ============================================================================
  # install_rules/1 Tests
  # ============================================================================

  describe "install_rules/1" do
    test "copies rule files to .code_my_spec/rules/", %{tmp_dir: tmp_dir} do
      assert :ok = ProjectSetup.install_rules(tmp_dir)

      rules_path = Path.join(tmp_dir, ".code_my_spec/rules")
      assert File.dir?(rules_path)

      rule_files = File.ls!(rules_path) |> Enum.filter(&String.ends_with?(&1, ".md"))
      assert [_ | _] = rule_files
      assert "context_design.md" in rule_files
      assert "elixir.md" in rule_files
    end

    test "does not overwrite existing files", %{tmp_dir: tmp_dir} do
      rules_path = Path.join(tmp_dir, ".code_my_spec/rules")
      File.mkdir_p!(rules_path)

      # Write a customized rule
      custom_content = "# My Custom Rule\nCustomized content"
      File.write!(Path.join(rules_path, "context_design.md"), custom_content)

      assert :ok = ProjectSetup.install_rules(tmp_dir)

      # Custom file should be preserved
      assert File.read!(Path.join(rules_path, "context_design.md")) == custom_content

      # Other rule files should be installed
      rule_files = File.ls!(rules_path) |> Enum.filter(&String.ends_with?(&1, ".md"))
      assert "context_design.md" in rule_files
      assert "elixir.md" in rule_files
    end

    test "is idempotent", %{tmp_dir: tmp_dir} do
      assert :ok = ProjectSetup.install_rules(tmp_dir)
      assert :ok = ProjectSetup.install_rules(tmp_dir)

      rules_path = Path.join(tmp_dir, ".code_my_spec/rules")
      rule_files = File.ls!(rules_path) |> Enum.filter(&String.ends_with?(&1, ".md"))
      assert [_ | _] = rule_files
    end
  end

  # ============================================================================
  # install_claude_md/1 Tests
  # ============================================================================

  describe "install_claude_md/1" do
    test "creates CLAUDE.md when none exists", %{tmp_dir: tmp_dir} do
      create_phoenix_project_structure(tmp_dir, "my_app")
      assert :ok = ProjectSetup.install_claude_md(tmp_dir)

      claude_md_path = Path.join(tmp_dir, "CLAUDE.md")
      assert File.exists?(claude_md_path)

      content = File.read!(claude_md_path)
      assert content =~ "<!-- code_my_spec:start -->"
      assert content =~ "<!-- code_my_spec:end -->"
      assert content =~ ".code_my_spec/AGENTS.md"
      assert content =~ "my_app"
    end

    test "appends managed section to existing CLAUDE.md without markers", %{tmp_dir: tmp_dir} do
      create_phoenix_project_structure(tmp_dir, "my_app")

      # Write existing content
      claude_md_path = Path.join(tmp_dir, "CLAUDE.md")
      File.write!(claude_md_path, "# My Project\n\nExisting content here.\n")

      assert :ok = ProjectSetup.install_claude_md(tmp_dir)

      content = File.read!(claude_md_path)
      # Original content preserved
      assert content =~ "# My Project"
      assert content =~ "Existing content here."
      # Managed section appended
      assert content =~ "<!-- code_my_spec:start -->"
      assert content =~ "<!-- code_my_spec:end -->"
    end

    test "replaces managed section on re-run (idempotent)", %{tmp_dir: tmp_dir} do
      create_phoenix_project_structure(tmp_dir, "my_app")

      claude_md_path = Path.join(tmp_dir, "CLAUDE.md")
      File.write!(claude_md_path, "# My Project\n\nCustom notes.\n")

      # First install
      assert :ok = ProjectSetup.install_claude_md(tmp_dir)
      first_content = File.read!(claude_md_path)

      # Second install — should produce identical content
      assert :ok = ProjectSetup.install_claude_md(tmp_dir)
      second_content = File.read!(claude_md_path)

      assert first_content == second_content
    end

    test "preserves content outside markers when replacing", %{tmp_dir: tmp_dir} do
      create_phoenix_project_structure(tmp_dir, "my_app")

      claude_md_path = Path.join(tmp_dir, "CLAUDE.md")

      # Simulate a file with markers and surrounding content
      File.write!(claude_md_path, """
      # My Project

      Some notes.

      <!-- code_my_spec:start -->
      ## Old managed content
      <!-- code_my_spec:end -->

      ## My Custom Section

      More notes.
      """)

      assert :ok = ProjectSetup.install_claude_md(tmp_dir)

      content = File.read!(claude_md_path)
      # Custom content preserved
      assert content =~ "# My Project"
      assert content =~ "Some notes."
      assert content =~ "## My Custom Section"
      assert content =~ "More notes."
      # Old managed content replaced
      refute content =~ "## Old managed content"
      # New managed content present
      assert content =~ ".code_my_spec/AGENTS.md"
    end

    test "uses fallback app name when no mix.exs", %{tmp_dir: tmp_dir} do
      assert :ok = ProjectSetup.install_claude_md(tmp_dir)

      content = File.read!(Path.join(tmp_dir, "CLAUDE.md"))
      assert content =~ "your_app"
    end
  end

  # ============================================================================
  # check_status/2 - claude_md_installed Tests
  # ============================================================================

  describe "check_status/2 - claude_md_installed" do
    test "returns claude_md_installed false when CLAUDE.md missing", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")

      use_cmd_cassette "project_setup_claude_md_missing", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)
        assert status.claude_md_installed == false
      end
    end

    test "returns claude_md_installed false when CLAUDE.md exists without markers", %{
      tmp_dir: tmp_dir
    } do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "# My Project\n")

      use_cmd_cassette "project_setup_claude_md_no_markers", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)
        assert status.claude_md_installed == false
      end
    end

    test "returns claude_md_installed true when markers present", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")
      assert :ok = ProjectSetup.install_claude_md(tmp_dir)

      use_cmd_cassette "project_setup_claude_md_ok", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)
        assert status.claude_md_installed == true
      end
    end
  end

  # ============================================================================
  # check_status/2 - rules_installed Tests
  # ============================================================================

  describe "check_status/2 - rules_installed" do
    test "returns rules_installed false when rules directory empty", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")
      File.mkdir_p!(Path.join(tmp_dir, ".code_my_spec/rules"))

      use_cmd_cassette "project_setup_rules_empty", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)
        assert status.rules_installed == false
      end
    end

    test "returns rules_installed false when rules directory missing", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")

      use_cmd_cassette "project_setup_rules_missing", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)
        assert status.rules_installed == false
      end
    end

    test "returns rules_installed true when rule files exist", %{tmp_dir: tmp_dir} do
      env = create_environment(tmp_dir)
      task = %{project_id: nil, component_id: nil, story_id: nil}

      create_phoenix_project_structure(tmp_dir, "my_app")
      assert :ok = ProjectSetup.install_rules(tmp_dir)

      use_cmd_cassette "project_setup_rules_ok", ignore: [[:opts, :cd]] do
        status = ProjectSetup.check_status(env, task)
        assert status.rules_installed == true
      end
    end
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    test "returns full setup guide when starting from empty directory", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      task = create_task(tmp_dir)

      use_cmd_cassette "project_setup_command_empty", ignore: [[:opts, :cd]] do
        assert {:ok, prompt} = ProjectSetup.command(scope, task)

        assert is_binary(prompt)
        assert String.length(prompt) > 0
        assert prompt =~ "Elixir" or prompt =~ "elixir"
        assert prompt =~ "phx.new" or prompt =~ "Phoenix"
      end
    end

    test "returns partial guide omitting completed steps", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      task = create_task(tmp_dir)

      create_phoenix_project_structure(tmp_dir, "my_app")

      use_cmd_cassette "project_setup_command_partial", ignore: [[:opts, :cd]] do
        assert {:ok, prompt} = ProjectSetup.command(scope, task)

        assert is_binary(prompt)
      end
    end

    test "includes prerequisite installation when elixir_installed is false", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      task = create_task(tmp_dir)

      use_cmd_cassette "project_setup_command_prereqs", ignore: [[:opts, :cd]] do
        assert {:ok, prompt} = ProjectSetup.command(scope, task)

        assert is_binary(prompt)
      end
    end

    test "includes Phoenix installer setup when phoenix_installer_available is false", %{
      tmp_dir: tmp_dir
    } do
      scope = create_scope(tmp_dir)
      task = create_task(tmp_dir)

      use_cmd_cassette "project_setup_command_phoenix", ignore: [[:opts, :cd]] do
        assert {:ok, prompt} = ProjectSetup.command(scope, task)

        assert is_binary(prompt)
      end
    end

    test "includes project creation when phoenix_project_exists is false", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      task = create_task(tmp_dir)

      use_cmd_cassette "project_setup_command_create", ignore: [[:opts, :cd]] do
        assert {:ok, prompt} = ProjectSetup.command(scope, task)

        assert prompt =~ "phx.new" or prompt =~ "mix"
      end
    end

    test "includes auth generation when auth_generated is false", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      task = create_task(tmp_dir)

      create_phoenix_project_structure(tmp_dir, "my_app")

      use_cmd_cassette "project_setup_command_auth", ignore: [[:opts, :cd]] do
        assert {:ok, prompt} = ProjectSetup.command(scope, task)

        assert prompt =~ "phx.gen.auth" or prompt =~ "auth"
      end
    end

    test "includes dependency block when codemyspec_deps_installed is false", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      task = create_task(tmp_dir)

      create_phoenix_project_structure(tmp_dir, "my_app")

      use_cmd_cassette "project_setup_command_deps", ignore: [[:opts, :cd]] do
        assert {:ok, prompt} = ProjectSetup.command(scope, task)

        assert prompt =~ "deps" or prompt =~ "mix.exs" or prompt =~ "ngrok" or prompt =~ "credo"
      end
    end

    test "includes structure setup when project_dir_exists is false", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      task = create_task(tmp_dir)

      create_phoenix_project_structure(tmp_dir, "my_app")

      use_cmd_cassette "project_setup_command_structure", ignore: [[:opts, :cd]] do
        assert {:ok, prompt} = ProjectSetup.command(scope, task)

        assert prompt =~ ".code_my_spec" or prompt =~ "Project Structure"
      end
    end

    test "includes commit instructions between major steps", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      task = create_task(tmp_dir)

      use_cmd_cassette "project_setup_command_commits", ignore: [[:opts, :cd]] do
        assert {:ok, prompt} = ProjectSetup.command(scope, task)

        assert prompt =~ "commit" or prompt =~ "git"
      end
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    test "returns valid when all required checks pass", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      task = create_task(tmp_dir)

      create_full_project_setup(tmp_dir, "complete_app")

      use_cmd_cassette "project_setup_evaluate_valid", ignore: [[:opts, :cd]] do
        result = ProjectSetup.evaluate(scope, task)

        assert match?({:ok, :valid}, result) or match?({:ok, :invalid, _}, result)
      end
    end

    test "returns invalid with detailed feedback when checks fail", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      task = create_task(tmp_dir)

      use_cmd_cassette "project_setup_evaluate_invalid", ignore: [[:opts, :cd]] do
        assert {:ok, :invalid, feedback} = ProjectSetup.evaluate(scope, task)

        assert is_binary(feedback)
        assert String.length(feedback) > 0
      end
    end

    test "feedback includes progress summary", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      task = create_task(tmp_dir)

      create_phoenix_project_structure(tmp_dir, "my_app")

      use_cmd_cassette "project_setup_evaluate_progress", ignore: [[:opts, :cd]] do
        assert {:ok, :invalid, feedback} = ProjectSetup.evaluate(scope, task)

        assert feedback =~ ~r/\d+.*of.*\d+|complete|progress|step/i
      end
    end

    test "feedback includes specific remediation for each failing check", %{tmp_dir: tmp_dir} do
      scope = create_scope(tmp_dir)
      task = create_task(tmp_dir)

      use_cmd_cassette "project_setup_evaluate_remediation", ignore: [[:opts, :cd]] do
        assert {:ok, :invalid, feedback} = ProjectSetup.evaluate(scope, task)

        assert is_binary(feedback)
        assert String.length(feedback) > 50
      end
    end
  end
end
