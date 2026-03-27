defmodule CodeMySpec.AgentTasks.ProjectSetup do
  @moduledoc """
  Agent task that guides developers through complete Phoenix project setup for CodeMySpec integration.

  Generates comprehensive setup instructions and evaluates current setup state by checking
  prerequisites, project structure, dependencies, and .code_my_spec/ directory configuration.
  Designed to be run from a target directory that will become (or already is) a Phoenix project root.

  The agent approach (vs running the ScriptGenerator script directly) allows picking up setup
  from any point and provides flexibility for the agent to adapt to different starting states.
  """

  alias CodeMySpec.AgentTasks.Setup
  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Environments.Environment

  @required_deps [:credo, :client_utils, :sobelow, :sexy_spex, :boundary]
  @min_elixir_version {1, 18, 0}

  @setup_steps [
    Setup.ApplicationInWeb,
    Setup.CodemyspecDeps,
    Setup.Compilers,
    Setup.SpexConfig,
    Setup.TestBoundaries,
    Setup.TestSupportNamespace,
    Setup.ProjectStructure,
    Setup.AppResources,
    Setup.AgentsMd,
    Setup.Rules,
    Setup.CredoChecks,
    Setup.ClaudeMd
  ]

  @doc "Returns the ordered list of setup step modules."
  def setup_steps, do: @setup_steps

  @doc "Find a setup step module by its derived ID."
  def find_step(id) do
    Enum.find(@setup_steps, fn mod -> step_id(mod) == id end)
  end

  @doc "Derive a URL-friendly ID from a step module name."
  def step_id(mod), do: mod |> Module.split() |> List.last() |> Macro.underscore()

  @doc "Derive a human-readable name from a step module name."
  def step_name(mod) do
    mod |> Module.split() |> List.last() |> Macro.underscore() |> String.replace("_", " ") |> String.capitalize()
  end

  @doc """
  Generate setup instructions with inline prompts for incomplete steps.

  Evaluates each step, shows completed steps as checked off, and inlines
  the full command prompt for each incomplete step. One prompt, one agent.
  """
  @spec command(term(), map()) :: {:ok, String.t()}
  def command(scope, _task) do
    steps = build_step_status(scope)
    done = Enum.count(steps, & &1.done)
    total = length(steps)

    checklist =
      Enum.map_join(steps, "\n\n", fn step ->
        if step.done do
          "- [x] **#{step.name}**"
        else
          "- [ ] **#{step.name}**\n\n#{step.prompt}"
        end
      end)

    {:ok, """
    # Project Setup (#{done}/#{total})

    Configure this Phoenix project for CodeMySpec integration.
    Complete all unchecked steps below. Order does not matter.

    #{checklist}

    When all steps are complete, use `evaluate_task` to validate.
    """}
  end

  defp build_step_status(scope) do
    Enum.map(@setup_steps, fn mod ->
      done =
        case mod.evaluate(scope, %{}) do
          {:ok, :valid} -> true
          _ -> false
        end

      prompt =
        if done do
          nil
        else
          case mod.command(scope, %{}) do
            {:ok, text} -> text
            _ -> "Run #{step_name(mod)}"
          end
        end

      %{name: step_name(mod), done: done, prompt: prompt}
    end)
  end

  @doc """
  Evaluate current environment and report detailed setup completion status.

  Returns:
  - `{:ok, :valid}` if all required checks pass
  - `{:ok, :invalid, feedback}` with detailed remediation hints if checks fail
  - `{:error, term()}` if something went wrong
  """
  @spec evaluate(term(), map()) ::
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
    test_support_namespace_check = check_test_support_namespace(working_dir, app_name)

    # Application module location
    application_check = check_application_module(working_dir, app_name)

    # Auth check
    auth_check = check_auth_status()

    # App symlinks (framework knowledge + tools)
    symlinks_check = check_app_symlinks(working_dir)

    # AGENTS.md guide
    agents_md_check = check_agents_md(working_dir)

    # Rules installed
    rules_check = check_rules_installed(working_dir)

    # CLAUDE.md installed
    claude_md_check = check_claude_md(working_dir)

    # Credo checks configured
    credo_checks_check = check_credo_checks_configured(working_dir)

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
      test_support_namespace_correct: test_support_namespace_check.correct,
      project_dir_exists: structure_check.dir_exists,
      project_structure_complete: structure_check.structure_complete,
      missing_structure_dirs: structure_check.missing_dirs,
      cli_config_exists: cli_config_check.exists,
      app_symlinks_installed: symlinks_check.installed,
      agents_md_installed: agents_md_check.installed,
      rules_installed: rules_check.installed,
      claude_md_installed: claude_md_check.installed,
      cli_config_has_project_id: cli_config_check.has_project_id,
      application_in_web: application_check.in_web,
      credo_checks_configured: credo_checks_check.configured,
      ignored_components_configured: ignored_components_check.configured
    }
  end

  # Application module check — should live in the web namespace to avoid boundary issues

  defp check_application_module(_working_dir, nil), do: %{in_web: false}

  defp check_application_module(working_dir, app_name) do
    web_app_path = Path.join([working_dir, "lib", "#{app_name}_web", "application.ex"])
    %{in_web: File.exists?(web_app_path)}
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

  # App resource dirs check (framework knowledge + tools, copied by CLI on startup)

  @app_resource_dirs [
    :framework_dir,
    :tools_dir,
    :credo_checks_dir
  ]

  defp check_app_symlinks(working_dir) do
    all_installed =
      Enum.all?(@app_resource_dirs, fn path_fn ->
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

  # CLAUDE.md check

  @claude_md_start_marker "<!-- code_my_spec:start -->"
  @claude_md_end_marker "<!-- code_my_spec:end -->"

  defp check_claude_md(working_dir) do
    claude_md_path = Path.join(working_dir, "CLAUDE.md")

    case File.read(claude_md_path) do
      {:ok, content} ->
        %{installed: String.contains?(content, @claude_md_start_marker)}

      {:error, _} ->
        %{installed: false}
    end
  end

  # Credo checks check — .credo.exs has requires + eval_file for framework checks

  defp check_credo_checks_configured(working_dir) do
    credo_exs = Path.join(working_dir, ".credo.exs")

    case File.read(credo_exs) do
      {:ok, content} ->
        has_requires =
          String.contains?(content, "credo_checks/framework") and
            String.contains?(content, "credo_checks/local")

        has_eval = String.contains?(content, "credo_checks/framework/checks.exs")

        %{configured: has_requires and has_eval}

      {:error, _} ->
        %{configured: false}
    end
  end

  # Ignored components check (optional — not gated in all_checks_pass?)

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
          has_preferred_env = Regex.match?(~r/spex:\s*:test/, content)

          %{complete: has_preferred_env}

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
    spex_namespace_path = Path.join([working_dir, "test", "support", "#{app_name}_spex.ex"])
    test_namespace_path = Path.join([working_dir, "test", "support", "#{app_name}_test_boundary.ex"])

    spex_has_boundary = file_contains_boundary?(spex_namespace_path)
    test_has_boundary = file_contains_boundary?(test_namespace_path)

    %{configured: spex_has_boundary and test_has_boundary}
  end

  # Test support namespace check — ConnCase, DataCase etc. should be under AppTest namespace

  @test_support_files ["conn_case.ex", "data_case.ex"]

  defp check_test_support_namespace(_working_dir, nil), do: %{correct: false}

  defp check_test_support_namespace(working_dir, app_name) do
    module_name = Macro.camelize(app_name)
    test_namespace = "#{module_name}Test"

    all_correct =
      @test_support_files
      |> Enum.all?(fn file ->
        path = Path.join([working_dir, "test", "support", file])

        case File.read(path) do
          {:ok, content} -> String.contains?(content, "defmodule #{test_namespace}.")
          {:error, :enoent} -> true
          _ -> false
        end
      end)

    %{correct: all_correct}
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

  # Installation helpers

  @app_copy_dirs [
    {"priv/knowledge", :framework_dir},
    {"priv/tools", :tools_dir},
    {"priv/credo_checks", :credo_checks_framework_dir}
  ]

  @doc """
  Copy framework knowledge and tools from priv/ into the project's .code_my_spec/.

  Creates:
  - `.code_my_spec/framework/` from `priv/knowledge/`
  - `.code_my_spec/tools/` from `priv/tools/`

  Returns `:ok` on success, `{:error, reason}` on first failure.
  """
  @spec install_app_resources(String.t()) :: :ok | {:error, term()}
  def install_app_resources(working_dir) do
    Enum.reduce_while(@app_copy_dirs, :ok, fn {priv_subdir, path_fn}, :ok ->
      source = Application.app_dir(:code_my_spec, priv_subdir)
      target = Path.join(working_dir, apply(CodeMySpec.Paths, path_fn, []))

      case copy_dir(source, target) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp copy_dir(source, target) do
    with :ok <- target |> Path.dirname() |> File.mkdir_p() do
      # Remove existing directory or symlink
      if File.exists?(target) or symlink?(target) do
        File.rm_rf(target)
      end

      case File.cp_r(source, target) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, reason}
      end
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
  Install Credo custom checks directory structure.

  Creates:
  - `.code_my_spec/credo_checks/framework/` (populated by FrameworkSync)
  - `.code_my_spec/credo_checks/local/` (for project-specific checks)

  The `.credo.exs` configuration is handled by the setup prompt — the LLM
  adds the `requires` paths as part of project setup.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec install_credo_checks(String.t()) :: :ok | {:error, term()}
  def install_credo_checks(working_dir) do
    framework_dir = Path.join(working_dir, CodeMySpec.Paths.credo_checks_framework_dir())
    local_dir = Path.join(working_dir, CodeMySpec.Paths.credo_checks_local_dir())

    with :ok <- File.mkdir_p(framework_dir),
         :ok <- File.mkdir_p(local_dir) do
      :ok
    end
  end

  @doc """
  Create or update the managed section in CLAUDE.md at the project root.

  Uses HTML comment markers for idempotent updates:
  - No CLAUDE.md: creates with the managed section
  - CLAUDE.md without markers: appends managed section
  - CLAUDE.md with markers: replaces content between markers

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec install_claude_md(String.t()) :: :ok | {:error, term()}
  def install_claude_md(working_dir) do
    app_name = extract_app_name(Path.join(working_dir, "mix.exs"))
    managed_section = claude_md_content(app_name)
    claude_md_path = Path.join(working_dir, "CLAUDE.md")

    case File.read(claude_md_path) do
      {:ok, existing} ->
        if String.contains?(existing, @claude_md_start_marker) do
          # Replace between markers
          updated = replace_managed_section(existing, managed_section)
          File.write(claude_md_path, updated)
        else
          # Append managed section
          File.write(claude_md_path, existing <> "\n" <> managed_section)
        end

      {:error, :enoent} ->
        # Create new file
        File.write(claude_md_path, managed_section)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replace_managed_section(content, managed_section) do
    pattern = ~r/#{Regex.escape(@claude_md_start_marker)}.*#{Regex.escape(@claude_md_end_marker)}/s
    String.replace(content, pattern, String.trim_trailing(managed_section))
  end

  @doc """
  Generate the managed CLAUDE.md section content for a project.

  Returns the content wrapped in marker comments for idempotent updates.
  """
  def claude_md_content(app_name) do
    app = app_name || "your_app"
    base = CodeMySpec.Paths.base_dir()

    """
    #{@claude_md_start_marker}
    ## CodeMySpec Project

    Read `#{base}/AGENTS.md` for the full project development guide.

    ### Key Conventions

    - All public context functions take `%Scope{}` as the first parameter
    - Contexts are the public API boundary — never call child modules directly
    - Use `use Boundary` in every module to enforce dependency rules
    - Check `#{base}/architecture/overview.md` for the component graph before adding dependencies

    ### Before Writing Code

    1. Check `#{base}/status/#{app}.md` for implementation status
    2. Read the spec in `#{base}/spec/` for the module you're working on
    3. Read the rules in `#{base}/rules/` for the component type (context, repository, schema, etc.)
    4. Check `#{base}/issues/` for known problems in the area
    #{@claude_md_end_marker}
    """
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
    ├── framework/             ← Framework reference (LiveView, DaisyUI, etc.)
    ├── tools/                 ← Helper scripts (set-story-component, etc.)
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
    - `#{base}/framework/` — Framework knowledge (LiveView, DaisyUI, Boundary, etc.)

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

  # Evaluation helpers

  @required_check_keys [
    :user_authenticated,
    :elixir_installed,
    :phoenix_installer_available,
    :phoenix_project_exists,
    :application_in_web,
    :codemyspec_deps_installed,
    :compilers_configured,
    :spex_config_complete,
    :test_boundaries_configured,
    :test_support_namespace_correct,
    :project_dir_exists,
    :project_structure_complete,
    :app_symlinks_installed,
    :agents_md_installed,
    :rules_installed,
    :credo_checks_configured,
    :claude_md_installed,
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
       "Run: curl -s -X POST http://localhost:4003/api/bootstrap/auth/start, then visit the auth_url, then verify with curl -s http://localhost:4003/api/bootstrap/auth/status"},
      {"Elixir 1.18+", status.elixir_installed, "Install Elixir 1.18+ using asdf or brew"},
      {"Phoenix installer", status.phoenix_installer_available,
       "Run: mix archive.install hex phx_new"},
      {"Phoenix project", status.phoenix_project_exists,
       "Run: mix phx.new . --app your_app_name"},
      {"Project compiles", status.project_compiles,
       "Fix compilation errors: #{status.compilation_errors}"},
      {"Application in web namespace", status.application_in_web,
       "Move lib/app_name/application.ex to lib/app_name_web/application.ex, rename module to AppWeb.Application, update mod: in mix.exs application/0"},
      {"CodeMySpec deps", status.codemyspec_deps_installed,
       "Add missing deps to mix.exs: #{inspect(status.missing_deps)}"},
      {"Compilers (boundary + spex)", status.compilers_configured,
       "Add compilers: compilers(Mix.env()) to project/0 with per-env defp compilers(:test) including :spex and defp compilers(_) without :spex"},
      {"Spex config", status.spex_config_complete,
       "Add preferred_envs spex: :test to cli/0 in mix.exs"},
      {"Test boundaries", status.test_boundaries_configured,
       "Create boundary namespace modules in test/support/ with use Boundary"},
      {"Test support namespace", status.test_support_namespace_correct,
       "Rename ConnCase, DataCase etc. from AppWeb/App namespace to AppTest namespace in test/support/, then update all use references in test files"},
      {"Project structure", status.project_dir_exists,
       "Create .code_my_spec directory: mkdir -p #{CodeMySpec.Paths.base_dir()}"},
      {"Project structure dirs", status.project_structure_complete,
       "Create directories: #{Enum.join(status.missing_structure_dirs, ", ")}"},
      {"App resources (framework + tools)", status.app_symlinks_installed,
       "Run: curl -s -X POST http://localhost:4003/api/bootstrap/install-symlinks -H 'Content-Type: application/json' -H 'X-Working-Dir: <project_dir>'"},
      {"AGENTS.md", status.agents_md_installed,
       "Generate AGENTS.md: curl -s -X POST http://localhost:4003/api/bootstrap/install-agents-md -H 'X-Working-Dir: <project_dir>'"},
      {"Rules", status.rules_installed,
       "Install rules: curl -s -X POST http://localhost:4003/api/bootstrap/install-rules -H 'X-Working-Dir: <project_dir>'"},
      {"Credo custom checks", status.credo_checks_configured,
       "Add requires paths and extra: elem(Code.eval_file(\".code_my_spec/credo_checks/framework/checks.exs\"), 0) to .credo.exs"},
      {"CLAUDE.md", status.claude_md_installed,
       "Install CLAUDE.md: curl -s -X POST http://localhost:4003/api/bootstrap/install-claude-md -H 'X-Working-Dir: <project_dir>'"},
      {"CLI config", status.cli_config_has_project_id,
       "Run curl -s http://localhost:4003/api/bootstrap/projects to list, then POST /api/bootstrap/init with project_id to create config"}
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
