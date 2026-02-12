defmodule CodeMySpec.AgentTasks.ProjectSetup do
  @moduledoc """
  Agent task that guides developers through complete Phoenix project setup for CodeMySpec integration.

  Generates comprehensive setup instructions and evaluates current setup state by checking
  prerequisites, project structure, dependencies, and documentation repository configuration.
  Designed to be run from a target directory that will become (or already is) a Phoenix project root.

  The agent approach (vs running the ScriptGenerator script directly) allows picking up setup
  from any point and provides flexibility for the agent to adapt to different starting states.
  """

  alias CodeMySpec.Environments.Environment

  @required_deps [:credo, :client_utils, :sobelow, :sexy_spex]
  @min_elixir_version {1, 18, 0}

  @doc """
  Generate setup instructions for the agent based on current environment state.

  Returns a comprehensive prompt containing setup instructions customized to skip
  completed steps based on check_status results.
  """
  @spec command(term(), map(), keyword()) :: {:ok, String.t()}
  def command(scope, session, _opts \\ []) do
    env = scope.environment
    status = check_status(env, session)
    prompt = build_setup_prompt(status)
    {:ok, prompt}
  end

  @doc """
  Evaluate current environment and report detailed setup completion status.

  Returns:
  - `{:ok, :valid}` if all required checks pass
  - `{:ok, :invalid, feedback}` with detailed remediation hints if checks fail
  - `{:error, term()}` if something went wrong
  """
  @spec evaluate(term(), map(), keyword()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(scope, session, _opts \\ []) do
    env = scope.environment
    status = check_status(env, session)

    case all_checks_pass?(status) do
      true ->
        {:ok, :valid}

      false ->
        feedback = build_evaluation_feedback(status)
        {:ok, :invalid, feedback}
    end
  end

  @doc """
  Check current environment and return structured status map.

  Helper used by both command/3 and evaluate/3 to determine current setup state.
  """
  @spec check_status(Environment.t(), map()) :: map()
  def check_status(%Environment{} = env, _session) do
    working_dir = env.cwd || env.ref[:working_dir] || File.cwd!()

    # System prerequisites
    elixir_check = check_elixir_version(working_dir)
    phoenix_installer = check_phoenix_installer(working_dir)
    postgresql = check_postgresql(working_dir)

    # Phoenix project
    project_check = check_phoenix_project(working_dir)
    app_name = project_check.app_name

    # Compilation (only if project exists)
    compilation_check = check_compilation(working_dir, project_check.phoenix_project_exists)

    # Dependencies
    deps_check = check_codemyspec_deps(working_dir, project_check.phoenix_project_exists)

    # Docs repository
    docs_check = check_docs_structure(working_dir, app_name)

    # CLI config
    cli_config_check = check_cli_config(working_dir)

    %{
      elixir_installed: elixir_check.installed,
      elixir_version: elixir_check.version,
      phoenix_installer_available: phoenix_installer,
      postgresql_available: postgresql,
      phoenix_project_exists: project_check.phoenix_project_exists,
      app_name: app_name,
      project_compiles: compilation_check.compiles,
      compilation_errors: compilation_check.errors,
      codemyspec_deps_installed: deps_check.installed,
      missing_deps: deps_check.missing,
      docs_repo_configured: docs_check.repo_configured,
      docs_structure_complete: docs_check.structure_complete,
      missing_docs_dirs: docs_check.missing_dirs,
      cli_config_exists: cli_config_check.exists,
      cli_config_has_project_id: cli_config_check.has_project_id
    }
  end

  # System prerequisite checks

  defp check_elixir_version(working_dir) do
    case System.cmd("elixir", ["--version"], cd: working_dir, stderr_to_stdout: true) do
      {output, 0} ->
        parse_and_check_elixir(output)

      _ ->
        %{installed: false, version: nil}
    end
  end

  defp parse_and_check_elixir(output) do
    case parse_elixir_version(output) do
      {:ok, version_string, version_tuple} ->
        installed = version_tuple >= @min_elixir_version
        %{installed: installed, version: version_string}

      :error ->
        %{installed: false, version: nil}
    end
  end

  defp parse_elixir_version(output) do
    case Regex.run(~r/Elixir\s+(\d+)\.(\d+)\.(\d+)/, output) do
      [_, major, minor, patch] ->
        version_string = "#{major}.#{minor}.#{patch}"

        version_tuple = {
          String.to_integer(major),
          String.to_integer(minor),
          String.to_integer(patch)
        }

        {:ok, version_string, version_tuple}

      nil ->
        :error
    end
  end

  defp check_phoenix_installer(working_dir) do
    case System.cmd("mix", ["archive"], cd: working_dir, stderr_to_stdout: true) do
      {output, 0} ->
        String.contains?(output, "phx_new")

      _ ->
        false
    end
  end

  defp check_postgresql(working_dir) do
    case System.cmd("psql", ["--version"], cd: working_dir, stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end

  # Phoenix project checks

  defp check_phoenix_project(working_dir) do
    mix_exs_path = Path.join(working_dir, "mix.exs")
    lib_path = Path.join(working_dir, "lib")
    config_path = Path.join(working_dir, "config")

    project_exists =
      File.exists?(mix_exs_path) and
        File.dir?(lib_path) and
        File.dir?(config_path)

    app_name =
      if project_exists do
        extract_app_name(mix_exs_path)
      else
        nil
      end

    %{phoenix_project_exists: project_exists, app_name: app_name}
  end

  defp extract_app_name(mix_exs_path) do
    case File.read(mix_exs_path) do
      {:ok, content} ->
        case Regex.run(~r/app:\s*:(\w+)/, content) do
          [_, app_name] -> app_name
          nil -> nil
        end

      _ ->
        nil
    end
  end

  defp check_compilation(working_dir, project_exists) do
    if project_exists do
      case System.cmd("mix", ["compile", "--warnings-as-errors"],
             cd: working_dir,
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          %{compiles: true, errors: nil}

        {output, _exit_code} ->
          %{compiles: false, errors: output}
      end
    else
      %{compiles: false, errors: nil}
    end
  end

  # Dependency checks

  defp check_codemyspec_deps(working_dir, project_exists) do
    if project_exists do
      mix_exs_path = Path.join(working_dir, "mix.exs")

      case File.read(mix_exs_path) do
        {:ok, content} ->
          missing =
            @required_deps
            |> Enum.reject(&dep_present?(content, &1))

          %{installed: Enum.empty?(missing), missing: missing}

        _ ->
          %{installed: false, missing: @required_deps}
      end
    else
      %{installed: false, missing: @required_deps}
    end
  end

  defp dep_present?(content, dep_name) do
    # Match various dependency declaration patterns
    atom_string = Atom.to_string(dep_name)
    Regex.match?(~r/\{:#{atom_string}[,\s]/, content)
  end

  # Docs structure checks

  defp check_docs_structure(working_dir, app_name) do
    docs_path = Path.join(working_dir, "docs")

    repo_configured = File.dir?(docs_path)

    {structure_complete, missing_dirs} = check_docs_directories(docs_path, app_name)

    %{
      repo_configured: repo_configured,
      structure_complete: structure_complete,
      missing_dirs: missing_dirs
    }
  end

  defp check_docs_directories(docs_path, app_name) do
    required_dirs =
      [
        docs_path,
        Path.join(docs_path, "rules"),
        Path.join(docs_path, "spec")
      ] ++
        if app_name do
          [
            Path.join([docs_path, "spec", app_name]),
            Path.join([docs_path, "spec", "#{app_name}_web"])
          ]
        else
          []
        end

    missing = Enum.reject(required_dirs, &File.dir?/1)
    {Enum.empty?(missing), missing}
  end

  # CLI config check

  defp check_cli_config(working_dir) do
    config_path = Path.join([working_dir, ".code_my_spec", "config.yml"])

    if File.exists?(config_path) do
      case YamlElixir.read_from_file(config_path) do
        {:ok, config} when is_map(config) ->
          %{exists: true, has_project_id: is_binary(config["project_id"])}

        _ ->
          %{exists: true, has_project_id: false}
      end
    else
      %{exists: false, has_project_id: false}
    end
  end

  # Prompt building

  defp build_setup_prompt(status) do
    [build_status_summary(status)]
    |> maybe_add_elixir_instructions(status)
    |> maybe_add_phoenix_installer_instructions(status)
    |> maybe_add_project_creation_instructions(status)
    |> maybe_add_deps_instructions(status)
    |> maybe_add_docs_instructions(status)
    |> maybe_add_cli_config_instructions(status)
    |> Enum.reverse()
    |> Enum.join("\n\n")
  end

  defp maybe_add_elixir_instructions(sections, %{elixir_installed: true}), do: sections

  defp maybe_add_elixir_instructions(sections, %{elixir_installed: false}) do
    [build_elixir_instructions() | sections]
  end

  defp maybe_add_phoenix_installer_instructions(sections, %{phoenix_installer_available: true}),
    do: sections

  defp maybe_add_phoenix_installer_instructions(sections, %{phoenix_installer_available: false}) do
    [build_phoenix_installer_instructions() | sections]
  end

  defp maybe_add_project_creation_instructions(sections, %{phoenix_project_exists: true}),
    do: sections

  defp maybe_add_project_creation_instructions(sections, %{phoenix_project_exists: false}) do
    [build_project_creation_instructions() | sections]
  end

  defp maybe_add_deps_instructions(
        sections,
        %{phoenix_project_exists: true, codemyspec_deps_installed: false} = status
      ) do
    [build_deps_instructions(status.missing_deps) | sections]
  end

  defp maybe_add_deps_instructions(sections, _status), do: sections

  defp maybe_add_docs_instructions(
        sections,
        %{docs_repo_configured: false} = status
      ) do
    [build_docs_instructions(status) | sections]
  end

  defp maybe_add_docs_instructions(
        sections,
        %{docs_structure_complete: false} = status
      ) do
    [build_docs_instructions(status) | sections]
  end

  defp maybe_add_docs_instructions(sections, _status), do: sections

  defp maybe_add_cli_config_instructions(sections, %{cli_config_has_project_id: true}),
    do: sections

  defp maybe_add_cli_config_instructions(sections, status) do
    [build_cli_config_instructions(status) | sections]
  end

  defp build_status_summary(status) do
    checks = [
      {"Elixir 1.18+", status.elixir_installed},
      {"Phoenix installer", status.phoenix_installer_available},
      {"PostgreSQL", status.postgresql_available},
      {"Phoenix project", status.phoenix_project_exists},
      {"CodeMySpec deps", status.codemyspec_deps_installed},
      {"Docs repository", status.docs_repo_configured},
      {"Docs structure", status.docs_structure_complete},
      {"CLI config", status.cli_config_has_project_id}
    ]

    completed = Enum.count(checks, fn {_, passed} -> passed end)
    total = length(checks)

    check_lines =
      Enum.map_join(checks, "\n", fn {name, passed} ->
        status_icon = if passed, do: "[x]", else: "[ ]"
        "  #{status_icon} #{name}"
      end)

    """
    # Project Setup Status

    Progress: #{completed} of #{total} steps complete

    #{check_lines}
    """
  end

  defp build_elixir_instructions do
    """
    ## Install Elixir 1.18+

    CodeMySpec requires Elixir 1.18 or later. Install using your preferred method:

    ### Using asdf (recommended)
    ```bash
    asdf plugin add elixir
    asdf install elixir 1.18.1
    asdf global elixir 1.18.1
    ```

    ### Using Homebrew (macOS)
    ```bash
    brew install elixir
    ```

    Verify installation:
    ```bash
    elixir --version
    ```
    """
  end

  defp build_phoenix_installer_instructions do
    """
    ## Install Phoenix Installer

    Install the Phoenix project generator:

    ```bash
    mix archive.install hex phx_new
    ```

    Verify installation:
    ```bash
    mix archive | grep phx_new
    ```
    """
  end

  defp build_project_creation_instructions do
    """
    ## Create Phoenix Project

    Create a new Phoenix project with LiveView:

    ```bash
    mix phx.new . --app your_app_name
    ```

    Or if creating in a new directory:
    ```bash
    mix phx.new your_app_name
    cd your_app_name
    ```

    After creation:
    ```bash
    mix deps.get
    mix ecto.create
    ```
    """
  end

  defp build_deps_instructions(missing_deps) do
    missing_list = Enum.map_join(missing_deps, "\n", &"  - :#{&1}")

    """
    ## Add CodeMySpec Dependencies

    The following dependencies are missing:
    #{missing_list}

    Add these dependencies to your `mix.exs` file in the `deps/0` function. Look up the latest versions on hex.pm for each package:

    - `:credo` - static code analysis
    - `:client_utils` - CodeMySpec client utilities (includes diagnostics and spex compilers)
    - `:sobelow` - security-focused static analysis
    - `:sexy_spex` - BDD specification testing

    Then fetch dependencies:
    ```bash
    mix deps.get
    ```

    Also add the diagnostics compilers to your `mix.exs` project config.
    Note: `:spex` must come between `:elixir` and `:app` so that Boundary
    can trace cross-module calls in spex files before its analysis runs:

    ```elixir
    def project do
      [
        compilers: [:boundary, :phoenix_live_view, :erlang, :elixir, :spex, :app, :diagnostics],
        spex: [pattern: "test/spex/**/*_spex.exs"],
        ...
      ]
    end
    ```

    The `:spex` compiler compiles your BDD spec `.exs` files and catches boundary
    violations. The `:diagnostics` compiler runs last and writes all diagnostics
    from every compiler to a `diagnostics.jsonl` file.
    """
  end

  defp build_docs_instructions(status) do
    missing_info = build_docs_submodule_info(status.docs_repo_configured)
    missing_dirs_info = build_missing_dirs_info(status.missing_docs_dirs, status.app_name)

    """
    ## Configure Documentation Repository
    #{missing_info}
    #{missing_dirs_info}
    """
  end

  defp build_docs_submodule_info(true), do: ""

  defp build_docs_submodule_info(false) do
    """

    The docs directory is not configured. Create it:

    ```bash
    mkdir -p docs
    ```
    """
  end

  defp build_missing_dirs_info([], _app_name), do: ""

  defp build_missing_dirs_info(missing_dirs, app_name) do
    dirs_list = Enum.map_join(missing_dirs, "\n", &"  - #{&1}")
    app = app_name || "your_app"

    """

    Create missing directories:
    #{dirs_list}

    ```bash
    mkdir -p docs/rules docs/spec/#{app} docs/spec/#{app}_web
    ```
    """
  end

  defp build_cli_config_instructions(status) do
    config_status =
      cond do
        not status.cli_config_exists ->
          "The `.code_my_spec/config.yml` file does not exist."

        not status.cli_config_has_project_id ->
          "The `.code_my_spec/config.yml` exists but is missing the `project_id`."

        true ->
          ""
      end

    """
    ## Configure CLI for CodeMySpec

    #{config_status}

    Initialize the CodeMySpec CLI configuration:

    1. First, ensure you're logged in to CodeMySpec:
    ```bash
    cms login
    ```

    2. Run the init command to create the config file:
    ```bash
    cms init
    ```

    This will prompt you to select from your existing projects on the CodeMySpec server,
    or you can specify a project ID directly:
    ```bash
    cms init --project-id <YOUR_PROJECT_ID>
    ```

    3. Add to `.gitignore` (the config contains project-specific IDs):
    ```bash
    echo ".code_my_spec/" >> .gitignore
    ```
    """
  end

  # Evaluation helpers

  defp all_checks_pass?(status) do
    status.elixir_installed and
      status.phoenix_installer_available and
      status.phoenix_project_exists and
      status.codemyspec_deps_installed and
      status.docs_repo_configured and
      status.docs_structure_complete and
      status.cli_config_has_project_id
  end

  defp build_evaluation_feedback(status) do
    checks = [
      {"Elixir 1.18+", status.elixir_installed, "Install Elixir 1.18+ using asdf or brew"},
      {"Phoenix installer", status.phoenix_installer_available,
       "Run: mix archive.install hex phx_new"},
      {"Phoenix project", status.phoenix_project_exists,
       "Run: mix phx.new . --app your_app_name"},
      {"Project compiles", status.project_compiles,
       "Fix compilation errors: #{status.compilation_errors}"},
      {"CodeMySpec deps", status.codemyspec_deps_installed,
       "Add missing deps to mix.exs: #{inspect(status.missing_deps)}"},
      {"Docs repository", status.docs_repo_configured, "Create docs directory: mkdir -p docs"},
      {"Docs structure", status.docs_structure_complete,
       "Create directories: #{Enum.join(status.missing_docs_dirs, ", ")}"},
      {"CLI config", status.cli_config_has_project_id,
       "Create .code_my_spec/config.yml with project_id from CodeMySpec server"}
    ]

    passing = Enum.filter(checks, fn {_, passed, _} -> passed end)
    failing = Enum.reject(checks, fn {_, passed, _} -> passed end)

    completed = length(passing)
    total = length(checks)

    passing_section = build_passing_section(passing)
    failing_section = build_failing_section(failing)
    next_action = build_next_action(failing)

    """
    # Setup Evaluation

    Progress: #{completed} of #{total} steps complete

    #{passing_section}
    ## Failing Checks

    #{failing_section}

    #{next_action}
    """
  end

  defp build_passing_section([]), do: ""

  defp build_passing_section(passing) do
    passing_list = Enum.map_join(passing, "\n", fn {name, _, _} -> "  [x] #{name}" end)

    """
    ## Completed Steps
    #{passing_list}
    """
  end

  defp build_failing_section(failing) do
    Enum.map_join(failing, "\n\n", fn {name, _, remediation} ->
      "  [ ] #{name}\n      Remediation: #{remediation}"
    end)
  end

  defp build_next_action([]), do: "All checks pass!"

  defp build_next_action([{name, _, remediation} | _]) do
    "**Next Action**: #{name} - #{remediation}"
  end
end
