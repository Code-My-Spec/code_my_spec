defmodule CodeMySpec.AgentTasks.ProjectSetup do
  @moduledoc """
  Agent task that guides developers through complete Phoenix project setup for CodeMySpec integration.

  Generates comprehensive setup instructions and evaluates current setup state by checking
  prerequisites, project structure, dependencies, and .code_my_spec/ directory configuration.
  Designed to be run from a target directory that will become (or already is) a Phoenix project root.

  The agent approach (vs running the ScriptGenerator script directly) allows picking up setup
  from any point and provides flexibility for the agent to adapt to different starting states.
  """

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Environments.Environment

  @required_deps [:credo, :client_utils, :sobelow, :sexy_spex, :boundary]
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

    # Project structure (.code_my_spec/ directory)
    structure_check = check_project_structure(working_dir, app_name)

    # CLI config
    cli_config_check = check_cli_config(working_dir)

    # Build tooling checks
    compilers_check = check_compilers(working_dir, project_check.phoenix_project_exists)
    spex_config_check = check_spex_config(working_dir, project_check.phoenix_project_exists)
    test_boundaries_check = check_test_boundaries(working_dir, app_name)

    # Auth check
    auth_check = check_auth_status()

    # App symlinks (framework knowledge + tools)
    symlinks_check = check_app_symlinks(working_dir)

    # AGENTS.md guide
    agents_md_check = check_agents_md(working_dir)

    # Rules installed
    rules_check = check_rules_installed(working_dir)

    # Ignored components (optional)
    ignored_components_check = check_ignored_components(working_dir)

    %{
      user_authenticated: auth_check.authenticated,
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
      compilers_configured: compilers_check.configured,
      spex_config_complete: spex_config_check.complete,
      test_boundaries_configured: test_boundaries_check.configured,
      project_dir_exists: structure_check.dir_exists,
      project_structure_complete: structure_check.structure_complete,
      missing_structure_dirs: structure_check.missing_dirs,
      cli_config_exists: cli_config_check.exists,
      app_symlinks_installed: symlinks_check.installed,
      agents_md_installed: agents_md_check.installed,
      rules_installed: rules_check.installed,
      cli_config_has_project_id: cli_config_check.has_project_id,
      ignored_components_configured: ignored_components_check.configured
    }
  end

  # Auth check

  defp check_auth_status do
    authenticated =
      try do
        OAuthClient.authenticated?()
      rescue
        _ -> false
      catch
        _, _ -> false
      end

    %{authenticated: authenticated}
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

  # Project structure checks (.code_my_spec/ directory)

  defp check_project_structure(working_dir, app_name) do
    base_path = Path.join(working_dir, CodeMySpec.Paths.base_dir())

    dir_exists = File.dir?(base_path)

    {structure_complete, missing_dirs} = check_required_directories(base_path, app_name)

    %{
      dir_exists: dir_exists,
      structure_complete: structure_complete,
      missing_dirs: missing_dirs
    }
  end

  defp check_required_directories(base_path, app_name) do
    required_dirs =
      [
        base_path,
        Path.join(base_path, "rules"),
        Path.join(base_path, "spec")
      ] ++
        if app_name do
          [
            Path.join([base_path, "spec", app_name]),
            Path.join([base_path, "spec", "#{app_name}_web"])
          ]
        else
          []
        end

    missing = Enum.reject(required_dirs, &File.dir?/1)
    {Enum.empty?(missing), missing}
  end

  # App symlinks check (framework knowledge + tools)

  @app_symlinks [
    {:framework_dir, "priv/knowledge"},
    {:tools_dir, "priv/tools"}
  ]

  defp check_app_symlinks(working_dir) do
    # File.dir? follows symlinks, so this validates both the link and its target
    all_installed =
      Enum.all?(@app_symlinks, fn {path_fn, _} ->
        Path.join(working_dir, apply(CodeMySpec.Paths, path_fn, []))
        |> File.dir?()
      end)

    %{installed: all_installed}
  end

  # Rules installed check

  defp check_rules_installed(working_dir) do
    rules_path = Path.join(working_dir, CodeMySpec.Paths.rules_dir())

    if File.dir?(rules_path) do
      rule_files =
        rules_path
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".md"))

      %{installed: rule_files != []}
    else
      %{installed: false}
    end
  end

  # AGENTS.md check

  defp check_agents_md(working_dir) do
    agents_path = Path.join([working_dir, CodeMySpec.Paths.base_dir(), "AGENTS.md"])
    %{installed: File.exists?(agents_path)}
  end

  # Ignored components check (optional — not gated in all_checks_pass?)

  @default_ignored_suffixes ~w(Repo Endpoint Router Mailer Telemetry Application Gettext)

  defp check_ignored_components(working_dir) do
    config_path = Path.join([working_dir, ".code_my_spec", "config.yml"])

    if File.exists?(config_path) do
      case YamlElixir.read_from_file(config_path) do
        {:ok, config} when is_map(config) ->
          %{
            configured:
              is_list(config["ignored_components"]) and config["ignored_components"] != []
          }

        _ ->
          %{configured: false}
      end
    else
      %{configured: false}
    end
  end

  # Compiler checks

  defp check_compilers(working_dir, project_exists) do
    if project_exists do
      mix_exs_path = Path.join(working_dir, "mix.exs")

      case File.read(mix_exs_path) do
        {:ok, content} ->
          # dotall flag (s) allows matching across lines for per-env compilers pattern
          has_boundary = Regex.match?(~r/compilers.*:boundary/s, content)
          has_spex = Regex.match?(~r/compilers.*:spex/s, content)
          %{configured: has_boundary and has_spex}

        _ ->
          %{configured: false}
      end
    else
      %{configured: false}
    end
  end

  # Spex config checks

  defp check_spex_config(working_dir, project_exists) do
    if project_exists do
      mix_exs_path = Path.join(working_dir, "mix.exs")

      case File.read(mix_exs_path) do
        {:ok, content} ->
          has_pattern = Regex.match?(~r/spex:\s*\[pattern:/, content)
          has_elixirc_paths = Regex.match?(~r/elixirc_paths.*test\/spex/, content)
          has_preferred_env = Regex.match?(~r/spex:\s*:test/, content)
          has_alias = Regex.match?(~r/spex:\s*\["spex/, content)

          %{complete: has_pattern and has_elixirc_paths and has_preferred_env and has_alias}

        _ ->
          %{complete: false}
      end
    else
      %{complete: false}
    end
  end

  # Test boundaries check

  defp check_test_boundaries(_working_dir, nil), do: %{configured: false}

  defp check_test_boundaries(working_dir, app_name) do
    spex_namespace_path = Path.join([working_dir, "test", "spex", "#{app_name}_spex.ex"])
    test_namespace_path = Path.join([working_dir, "test", "support", "#{app_name}_test_boundary.ex"])

    spex_has_boundary = file_contains_boundary?(spex_namespace_path)
    test_has_boundary = file_contains_boundary?(test_namespace_path)

    %{configured: spex_has_boundary and test_has_boundary}
  end

  defp file_contains_boundary?(path) do
    case File.read(path) do
      {:ok, content} -> String.contains?(content, "use Boundary")
      _ -> false
    end
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
    |> maybe_add_auth_instructions(status)
    |> maybe_add_elixir_instructions(status)
    |> maybe_add_phoenix_installer_instructions(status)
    |> maybe_add_project_creation_instructions(status)
    |> maybe_add_deps_instructions(status)
    |> maybe_add_compiler_instructions(status)
    |> maybe_add_spex_config_instructions(status)
    |> maybe_add_sexy_spex_local_dep_note(status)
    |> maybe_add_test_boundaries_instructions(status)
    |> maybe_add_structure_instructions(status)
    |> maybe_add_symlinks_instructions(status)
    |> maybe_add_agents_md_instructions(status)
    |> maybe_add_rules_instructions(status)
    |> maybe_add_cli_config_instructions(status)
    |> maybe_add_ignored_components_instructions(status)
    |> Enum.reverse()
    |> Enum.join("\n\n")
  end

  defp maybe_add_auth_instructions(sections, %{user_authenticated: true}), do: sections

  defp maybe_add_auth_instructions(sections, %{user_authenticated: false}) do
    [build_auth_instructions() | sections]
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

  defp maybe_add_compiler_instructions(
         sections,
         %{phoenix_project_exists: true, compilers_configured: false}
       ) do
    instruction = """
    ## Configure Compilers

    Add a per-environment `compilers/1` function to `mix.exs` and reference it
    in `project/0`. The `:spex` compiler comes from `client_utils` and only
    needs to run in `:test` — it compiles BDD spec files so Boundary can trace
    cross-module calls. The `:diagnostics` compiler must be first so its
    `after_compiler` hooks are registered before `:elixir` runs:

    ```elixir
    def project do
      [
        compilers: compilers(Mix.env()),
        ...
      ]
    end

    # :spex compiler only needed in test (compiles BDD spec files for Boundary)
    defp compilers(:test),
      do: [:diagnostics, :boundary, :phoenix_live_view, :erlang, :elixir, :spex, :app]

    defp compilers(_), do: [:diagnostics, :boundary, :phoenix_live_view, :erlang, :elixir, :app]
    ```
    """

    [instruction | sections]
  end

  defp maybe_add_compiler_instructions(sections, _status), do: sections

  defp maybe_add_spex_config_instructions(
         sections,
         %{phoenix_project_exists: true, spex_config_complete: false}
       ) do
    instruction = """
    ## Configure Spex

    Add the following to your `mix.exs` to enable BDD spec testing:

    **1. Add spex pattern to `project/0`:**
    ```elixir
    def project do
      [
        spex: [pattern: "test/spex/**/*_spex.exs"],
        ...
      ]
    end
    ```

    **2. Add `"test/spex"` to `elixirc_paths(:test)`:**
    ```elixir
    defp elixirc_paths(:test), do: ["lib", "test/support", "test/spex"]
    ```

    **3. Add `spex: :test` to `preferred_envs` in `cli/0`:**
    ```elixir
    def cli do
      [
        preferred_envs: [spex: :test]
      ]
    end
    ```

    **4. Add spex alias to `aliases/0`:**
    ```elixir
    defp aliases do
      [
        spex: ["spex --quiet"],
        ...
      ]
    end
    ```
    """

    [instruction | sections]
  end

  defp maybe_add_spex_config_instructions(sections, _status), do: sections

  defp maybe_add_sexy_spex_local_dep_note(
         sections,
         %{phoenix_project_exists: true, codemyspec_deps_installed: false}
       ) do
    instruction = """
    ## Note: sexy_spex Local Dependency

    The published hex version of `sexy_spex` does not yet include `SexySpex.Givens`,
    which is required by the generated `shared_givens.ex`. Until a new version is
    published, use the local path dependency:

    ```elixir
    {:sexy_spex, path: "/Users/johndavenport/Documents/github/spex"}
    ```

    Replace the path with the location of your local spex checkout.
    """

    [instruction | sections]
  end

  defp maybe_add_sexy_spex_local_dep_note(sections, _status), do: sections

  defp maybe_add_test_boundaries_instructions(
         sections,
         %{phoenix_project_exists: true, test_boundaries_configured: false} = status
       ) do
    app_name = status.app_name || "your_app"
    module_name = Macro.camelize(app_name)

    instruction = """
    ## Configure Test and Spex Boundaries

    Create boundary namespace modules so Boundary can track cross-context calls
    in test and spex files.

    **1. Create `test/spex/#{app_name}_spex.ex`:**
    ```elixir
    defmodule #{module_name}Spex do
      use Boundary, top_level?: true, deps: [#{module_name}]
    end
    ```

    **2. Create `test/support/#{app_name}_test_boundary.ex`:**
    ```elixir
    defmodule #{module_name}Test do
      use Boundary, top_level?: true, deps: [#{module_name}]
    end
    ```

    These modules declare top-level boundaries for the test and spex namespaces,
    allowing Boundary to verify that test code only depends on the main application.
    """

    [instruction | sections]
  end

  defp maybe_add_test_boundaries_instructions(sections, _status), do: sections

  defp maybe_add_structure_instructions(
         sections,
         %{project_dir_exists: false} = status
       ) do
    [build_structure_instructions(status) | sections]
  end

  defp maybe_add_structure_instructions(
         sections,
         %{project_structure_complete: false} = status
       ) do
    [build_structure_instructions(status) | sections]
  end

  defp maybe_add_structure_instructions(sections, _status), do: sections

  defp maybe_add_symlinks_instructions(sections, %{app_symlinks_installed: true}),
    do: sections

  defp maybe_add_symlinks_instructions(sections, _status) do
    instruction = """
    ## Install App Symlinks

    CodeMySpec provides framework knowledge and tools via symlinks into your project.

    Install them:
    ```bash
    curl -s -X POST http://localhost:4002/api/bootstrap/install-symlinks \\
      -H "Content-Type: application/json" \\
      -H "X-Working-Dir: $(pwd)"
    ```

    This creates:
    - `.code_my_spec/framework/` → framework reference (LiveView, DaisyUI, Boundary, etc.)
    - `.code_my_spec/tools/` → helper scripts (e.g., `set-story-component`)

    Both symlinks stay current with the app version automatically.
    Add them to `.gitignore` (they're machine-specific).
    """

    [instruction | sections]
  end

  defp maybe_add_agents_md_instructions(sections, %{agents_md_installed: true}),
    do: sections

  defp maybe_add_agents_md_instructions(sections, _status) do
    instruction = """
    ## Generate AGENTS.md

    The project guide orients agents to the `.code_my_spec/` directory structure.

    Generate it:
    ```bash
    curl -s -X POST http://localhost:4002/api/bootstrap/install-agents-md \\
      -H "Content-Type: application/json" \\
      -H "X-Working-Dir: $(pwd)"
    ```

    This creates `.code_my_spec/AGENTS.md` with app-specific paths.
    This file should be committed to version control.
    """

    [instruction | sections]
  end

  defp maybe_add_rules_instructions(sections, %{rules_installed: true}), do: sections

  defp maybe_add_rules_instructions(sections, _status) do
    instruction = """
    ## Install Default Rules

    CodeMySpec provides coding rules that guide agents when writing specs, code, and tests.

    Install them:
    ```bash
    curl -s -X POST http://localhost:4002/api/bootstrap/install-rules \\
      -H "Content-Type: application/json" \\
      -H "X-Working-Dir: $(pwd)"
    ```

    This copies default rule files into `.code_my_spec/rules/`.
    Rules are safe to customize — existing files are never overwritten.
    These files should be committed to version control.
    """

    [instruction | sections]
  end

  defp maybe_add_cli_config_instructions(sections, %{cli_config_has_project_id: true}),
    do: sections

  defp maybe_add_cli_config_instructions(sections, status) do
    [build_cli_config_instructions(status) | sections]
  end

  defp maybe_add_ignored_components_instructions(sections, %{ignored_components_configured: true}),
       do: sections

  defp maybe_add_ignored_components_instructions(sections, _status) do
    example_names = Enum.map(@default_ignored_suffixes, &"MyApp.#{&1}")
    example_yaml = Enum.map_join(example_names, "\n", &"  - #{&1}")
    example_cli = Enum.map_join(example_names, ", ", &"\"#{&1}\"")

    instruction = """
    ## Configure Ignored Components (Optional)

    Boilerplate Phoenix modules (Repo, Endpoint, Router, etc.) clutter the component
    graph and status output without being domain components that need spec/test tracking.

    Add `ignored_components` to `.code_my_spec/config.yml` using **fully qualified module names**
    (replace `MyApp` with your application's base module):

    ```yaml
    ignored_components:
    #{example_yaml}
    ```

    Or via the CLI:
    ```bash
    cms config set ignored_components #{example_cli}
    ```

    These components will be excluded from sync, dependency graphs, architecture views,
    and status files.
    """

    [instruction | sections]
  end

  defp build_status_summary(status) do
    checks = [
      {"Authenticated", status.user_authenticated},
      {"Elixir 1.18+", status.elixir_installed},
      {"Phoenix installer", status.phoenix_installer_available},
      {"PostgreSQL", status.postgresql_available},
      {"Phoenix project", status.phoenix_project_exists},
      {"CodeMySpec deps", status.codemyspec_deps_installed},
      {"Compilers (boundary + spex)", status.compilers_configured},
      {"Spex config", status.spex_config_complete},
      {"Test boundaries", status.test_boundaries_configured},
      {"Project structure", status.project_dir_exists},
      {"Project structure dirs", status.project_structure_complete},
      {"App symlinks", status.app_symlinks_installed},
      {"AGENTS.md", status.agents_md_installed},
      {"Rules", status.rules_installed},
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

  defp build_auth_instructions do
    """
    ## Authenticate with CodeMySpec

    You need to log in to your CodeMySpec account before initializing the project.

    1. **Start the auth flow**:
    ```bash
    curl -s -X POST http://localhost:4002/api/bootstrap/auth/start
    ```

    This returns a JSON response with an `auth_url`. Tell the user to open that URL
    in their browser to log in.

    2. **Wait for the user to complete login**, then verify:
    ```bash
    curl -s http://localhost:4002/api/bootstrap/auth/status
    ```

    Once `authenticated` is `true`, you can proceed to list projects and init.
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

    Also add a per-environment `compilers/1` function to your `mix.exs`.
    The `:spex` compiler only needs to run in `:test` (it compiles BDD spec
    files so Boundary can trace cross-module calls). The `:diagnostics`
    compiler must be first so its `after_compiler` hooks are registered
    before `:elixir` runs:

    ```elixir
    def project do
      [
        compilers: compilers(Mix.env()),
        spex: [pattern: "test/spex/**/*_spex.exs"],
        ...
      ]
    end

    # :spex compiler only needed in test (compiles BDD spec files for Boundary)
    defp compilers(:test),
      do: [:diagnostics, :boundary, :phoenix_live_view, :erlang, :elixir, :spex, :app]

    defp compilers(_), do: [:diagnostics, :boundary, :phoenix_live_view, :erlang, :elixir, :app]
    ```

    The `:spex` compiler compiles your BDD spec `.exs` files and catches boundary
    violations. The `:diagnostics` compiler registers `after_compiler` hooks that
    write all diagnostics to a `diagnostics.jsonl` file, even when compilation
    fails with syntax errors.
    """
  end

  defp build_structure_instructions(status) do
    base_dir = CodeMySpec.Paths.base_dir()
    missing_info = build_base_dir_info(status.project_dir_exists, base_dir)
    missing_dirs_info = build_missing_dirs_info(status.missing_structure_dirs, status.app_name, base_dir)

    """
    ## Configure Project Structure
    #{missing_info}
    #{missing_dirs_info}
    """
  end

  defp build_base_dir_info(true, _base_dir), do: ""

  defp build_base_dir_info(false, base_dir) do
    """

    The `#{base_dir}/` directory is not configured. Create it:

    ```bash
    mkdir -p #{base_dir}
    ```
    """
  end

  defp build_missing_dirs_info([], _app_name, _base_dir), do: ""

  defp build_missing_dirs_info(missing_dirs, app_name, base_dir) do
    dirs_list = Enum.map_join(missing_dirs, "\n", &"  - #{&1}")
    app = app_name || "your_app"

    """

    Create missing directories:
    #{dirs_list}

    ```bash
    mkdir -p #{base_dir}/rules #{base_dir}/spec/#{app} #{base_dir}/spec/#{app}_web
    ```
    """
  end

  @doc """
  Create symlinks from .code_my_spec/ to the app's priv/ directories.

  Creates:
  - `.code_my_spec/framework/` → `priv/knowledge/`
  - `.code_my_spec/tools/` → `priv/tools/`

  Returns `:ok` on success, `{:error, reason}` on first failure.
  """
  @spec install_app_symlinks(String.t()) :: :ok | {:error, term()}
  def install_app_symlinks(working_dir) do
    Enum.reduce_while(@app_symlinks, :ok, fn {path_fn, priv_subdir}, :ok ->
      source = Application.app_dir(:code_my_spec, priv_subdir)
      link_path = Path.join(working_dir, apply(CodeMySpec.Paths, path_fn, []))

      case create_symlink(source, link_path) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp create_symlink(source, link_path) do
    with :ok <- link_path |> Path.dirname() |> File.mkdir_p() do
      # Remove existing symlink or directory if present
      if File.exists?(link_path) or symlink?(link_path) do
        File.rm_rf(link_path)
      end

      File.ln_s(source, link_path)
    end
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> true
      _ -> false
    end
  end

  @doc """
  Generate and write .code_my_spec/AGENTS.md for the project.

  Detects the app name from mix.exs and generates a project-specific guide.
  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec install_agents_md(String.t()) :: :ok | {:error, term()}
  def install_agents_md(working_dir) do
    app_name = extract_app_name(Path.join(working_dir, "mix.exs"))
    content = agents_md_content(app_name)
    agents_path = Path.join([working_dir, CodeMySpec.Paths.base_dir(), "AGENTS.md"])

    with :ok <- agents_path |> Path.dirname() |> File.mkdir_p() do
      File.write(agents_path, content)
    end
  end

  @doc """
  Copy default rule files into the project's .code_my_spec/rules/ directory.

  Copies from the app's priv/rules/ to the target project. Only copies files
  that don't already exist (preserves user customizations).

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec install_rules(String.t()) :: :ok | {:error, term()}
  def install_rules(working_dir) do
    source_dir = Application.app_dir(:code_my_spec, "priv/rules")
    target_dir = Path.join(working_dir, CodeMySpec.Paths.rules_dir())

    with :ok <- File.mkdir_p(target_dir) do
      case File.ls(source_dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.reject(fn file -> File.exists?(Path.join(target_dir, file)) end)
          |> Enum.each(fn file ->
            File.cp!(Path.join(source_dir, file), Path.join(target_dir, file))
          end)

          :ok

        {:error, reason} ->
          {:error, {:source_dir, reason}}
      end
    end
  end

  @doc """
  Generate the generalized AGENTS.md content for a project.

  Takes the app name (e.g., "my_app") and returns markdown content
  that orients agents to the project's .code_my_spec/ structure.
  """
  def agents_md_content(app_name) do
    app = app_name || "your_app"
    base = CodeMySpec.Paths.base_dir()

    """
    # Project Development Guide

    This guide describes how the project's `#{base}/` directory works so you can locate what you need efficiently.

    ## Project Structure

    ```
    #{base}/
    ├── architecture/          ← System component graph and dependencies
    ├── status/                ← Implementation status of every component
    ├── spec/                  ← Specifications for every module
    ├── rules/                 ← Coding standards by component type
    ├── knowledge/             ← Project-specific operational knowledge
    ├── framework/             ← Framework reference (LiveView, DaisyUI, etc.) [symlink]
    ├── tools/                 ← Helper scripts (set-story-component, etc.) [symlink]
    ├── design/                ← Design system assets
    ├── issues/                ← Known bugs and technical debt
    └── qa/                    ← QA test results
    ```

    ## Progressive Disclosure: Where to Look

    ### 1. Orientation — What exists and how it's organized

    Start here to understand the system shape.

    | Need | File |
    |---|---|
    | List of all components, types, and dependencies | `#{base}/architecture/overview.md` |
    | Hierarchical tree view by Elixir namespace | `#{base}/architecture/namespace_hierarchy.md` |
    | Dependency graph (Mermaid) | `#{base}/architecture/dependency_graph.mmd` |

    ### 2. Status — What's done and what's not

    Check here before starting work on a component.

    | Need | File |
    |---|---|
    | Top-level status of all contexts | `#{base}/status/#{app}.md` |
    | Web layer status | `#{base}/status/#{app}_web.md` |
    | Status of a specific context | `#{base}/status/#{app}/<context_name>.md` |

    Status files use a checklist format:
    ```
    - [ ] spec_file - Context specification file exists
    - [x] implementation_file - Component implementation file exists
    - [ ] test_file - Component test file exists
    - [x] tests_passing - Component tests are passing
    ```

    ### 3. Specifications — What a module should do

    Read before implementing or modifying any module.

    | Need | File |
    |---|---|
    | Spec for a module | `#{base}/spec/<module_path>.spec.md` |

    Specs follow a standard format:
    - **Title**: Fully qualified module name with type
    - **Delegates**: Functions delegated to other modules
    - **Functions**: Public API with `@spec`, process steps, and test assertions
    - **Dependencies**: Required modules
    - **Fields**: (schemas only) Ecto field definitions

    Spec paths mirror the Elixir module namespace.

    ### 4. Rules — Coding standards for each component type

    Read before writing code. Rules are scoped by component type.

    | Component Type | Design Rules | Test Rules |
    |---|---|---|
    | Context | `#{base}/rules/context_design.md` | — |
    | Repository | `#{base}/rules/repository_design.md` | `#{base}/rules/repository_test.md` |
    | Schema | `#{base}/rules/schema_design.md` | — |
    | LiveView | `#{base}/rules/liveview_design.md` | — |
    | LiveView component | `#{base}/rules/liveview_component_design.md` | — |
    | Elixir (general) | `#{base}/rules/elixir_design.md` | `#{base}/rules/elixir_test.md` |

    ### 5. Design System — Visual reference

    Read before building any UI (LiveViews, components, templates).

    | Need | File |
    |---|---|
    | Design system (colors, typography, components) | `#{base}/design/design_system.html` |

    Open the HTML file in a browser to see the full visual reference. Use the DaisyUI classes and theme tokens defined there.

    ### 6. Issues — Known problems and technical debt

    Check before working in an area to avoid known pitfalls.

    Issues live in `#{base}/issues/` as individual markdown files describing the problem, reproduction steps, and possible solutions.

    ### 7. Knowledge — Operational knowledge

    - `#{base}/knowledge/` — Project-specific research (data providers, auth flows, etc.)
    - `#{base}/framework/` — Framework knowledge (LiveView, DaisyUI, Boundary, etc.) [symlink]

    ## Phoenix Contexts Architecture

    All code follows Phoenix Contexts conventions:

    - **Contexts** are the public API boundary. They live at `lib/#{app}/<context_name>.ex` and delegate to child modules.
    - **Repositories** handle data access. They live under the context namespace.
    - **Schemas** define Ecto schemas. They live under the context namespace.
    - **Scope** is the first parameter to all public context functions. It carries user, account, project, and optionally working directory.

    ### Key Conventions

    - All public functions accept `%Scope{}` as the first parameter
    - Database queries filter by scope foreign keys
    - Return consistent `{:ok, result}` / `{:error, reason}` tuples

    ## Working with #{base}/

    **Before implementing a component:**
    1. Check `#{base}/status/` — is it already done?
    2. Read `#{base}/spec/` — what should it do?
    3. Read `#{base}/rules/` — what conventions apply to this component type?
    4. Check `#{base}/issues/` — are there known problems in this area?

    **Before modifying an existing component:**
    1. Read the spec to understand the intended behavior
    2. Read the current implementation
    3. Check if there are open issues related to it
    4. Follow the rules for that component type

    **When you need context on the bigger picture:**
    1. Read `#{base}/architecture/namespace_hierarchy.md` for the component tree
    2. Read `#{base}/architecture/overview.md` for dependency relationships
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
    ## Initialize CodeMySpec Project Config

    #{config_status}

    Use the bootstrap API to initialize the project config. The local server
    runs on port 4002 and handles auth and init without interactive CLI commands.

    1. **Check auth status** (should already be authenticated from earlier step):
    ```bash
    curl -s http://localhost:4002/api/bootstrap/auth/status
    ```

    2. **List available projects**:
    ```bash
    curl -s http://localhost:4002/api/bootstrap/projects
    ```

    3. **Initialize with a project ID** (ask the user which project to select):
    ```bash
    curl -s -X POST http://localhost:4002/api/bootstrap/init \
      -H "Content-Type: application/json" \
      -H "X-Working-Dir: $(pwd)" \
      -d '{"project_id": "<PROJECT_ID>"}'
    ```

    4. **Add ephemeral `.code_my_spec/` directories to `.gitignore`**:
    ```bash
    cat >> .gitignore << 'GITIGNORE'

    # CodeMySpec - ephemeral/generated (specs, rules, knowledge are committed)
    .code_my_spec/config.yml
    .code_my_spec/sessions/
    .code_my_spec/status/
    .code_my_spec/qa/
    .code_my_spec/framework
    .code_my_spec/tools
    /diagnostics.jsonl
    GITIGNORE
    ```

    **Note:** `.code_my_spec/spec/`, `.code_my_spec/rules/`, `.code_my_spec/knowledge/`,
    `.code_my_spec/architecture/`, and `.code_my_spec/design/` should be committed to version control.
    `.code_my_spec/framework` and `.code_my_spec/tools` are local symlinks (machine-specific) and should not be committed.
    """
  end

  # Evaluation helpers

  @required_check_keys [
    :user_authenticated,
    :elixir_installed,
    :phoenix_installer_available,
    :phoenix_project_exists,
    :codemyspec_deps_installed,
    :compilers_configured,
    :spex_config_complete,
    :project_dir_exists,
    :project_structure_complete,
    :app_symlinks_installed,
    :agents_md_installed,
    :rules_installed,
    :cli_config_has_project_id
  ]

  defp all_checks_pass?(status) do
    Enum.all?(@required_check_keys, &Map.get(status, &1))
  end

  defp build_evaluation_feedback(status) do
    checks = evaluation_checks(status)
    {passing, failing} = Enum.split_with(checks, fn {_, passed, _} -> passed end)

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

  defp evaluation_checks(status) do
    [
      {"Authenticated", status.user_authenticated,
       "Run: curl -s -X POST http://localhost:4002/api/bootstrap/auth/start, then visit the auth_url, then verify with curl -s http://localhost:4002/api/bootstrap/auth/status"},
      {"Elixir 1.18+", status.elixir_installed, "Install Elixir 1.18+ using asdf or brew"},
      {"Phoenix installer", status.phoenix_installer_available,
       "Run: mix archive.install hex phx_new"},
      {"Phoenix project", status.phoenix_project_exists,
       "Run: mix phx.new . --app your_app_name"},
      {"Project compiles", status.project_compiles,
       "Fix compilation errors: #{status.compilation_errors}"},
      {"CodeMySpec deps", status.codemyspec_deps_installed,
       "Add missing deps to mix.exs: #{inspect(status.missing_deps)}"},
      {"Compilers (boundary + spex)", status.compilers_configured,
       "Add compilers: compilers(Mix.env()) to project/0 with per-env defp compilers(:test) including :spex and defp compilers(_) without :spex"},
      {"Spex config", status.spex_config_complete,
       "Add spex pattern, elixirc_paths(:test) with test/spex, preferred_envs spex: :test, and spex alias"},
      {"Test boundaries", status.test_boundaries_configured,
       "Create boundary namespace modules in test/spex/ and test/support/ with use Boundary"},
      {"Project structure", status.project_dir_exists,
       "Create .code_my_spec directory: mkdir -p #{CodeMySpec.Paths.base_dir()}"},
      {"Project structure dirs", status.project_structure_complete,
       "Create directories: #{Enum.join(status.missing_structure_dirs, ", ")}"},
      {"App symlinks", status.app_symlinks_installed,
       "Install app symlinks: curl -s -X POST http://localhost:4002/api/bootstrap/install-symlinks -H 'X-Working-Dir: <project_dir>'"},
      {"AGENTS.md", status.agents_md_installed,
       "Generate AGENTS.md: curl -s -X POST http://localhost:4002/api/bootstrap/install-agents-md -H 'X-Working-Dir: <project_dir>'"},
      {"Rules", status.rules_installed,
       "Install rules: curl -s -X POST http://localhost:4002/api/bootstrap/install-rules -H 'X-Working-Dir: <project_dir>'"},
      {"CLI config", status.cli_config_has_project_id,
       "Run curl -s http://localhost:4002/api/bootstrap/projects to list, then POST /api/bootstrap/init with project_id to create config"}
    ]
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
