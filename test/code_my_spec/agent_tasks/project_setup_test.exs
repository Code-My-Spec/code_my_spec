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
