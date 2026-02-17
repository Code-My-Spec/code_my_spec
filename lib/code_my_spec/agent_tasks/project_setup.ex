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

    # Docs repository
    docs_check = check_docs_structure(working_dir, app_name)

    # CLI config
    cli_config_check = check_cli_config(working_dir)

    # Build tooling checks
    compilers_check = check_compilers(working_dir, project_check.phoenix_project_exists)
    spex_config_check = check_spex_config(working_dir, project_check.phoenix_project_exists)
    test_boundaries_check = check_test_boundaries(working_dir, app_name)

    # Ignored components (optional)
    ignored_components_check = check_ignored_components(working_dir)

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
      compilers_configured: compilers_check.configured,
      spex_config_complete: spex_config_check.complete,
      test_boundaries_configured: test_boundaries_check.configured,
      docs_repo_configured: docs_check.repo_configured,
      docs_agents_md_exists: docs_check.agents_md_exists,
      docs_structure_complete: docs_check.structure_complete,
      missing_docs_dirs: docs_check.missing_dirs,
      cli_config_exists: cli_config_check.exists,
      cli_config_has_project_id: cli_config_check.has_project_id,
      ignored_components_configured: ignored_components_check.configured
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
    agents_md_exists = File.exists?(Path.join(docs_path, "AGENTS.md"))

    {structure_complete, missing_dirs} = check_docs_directories(docs_path, app_name)

    %{
      repo_configured: repo_configured,
      agents_md_exists: agents_md_exists,
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
          has_boundary = Regex.match?(~r/compilers:.*:boundary/, content)
          has_spex = Regex.match?(~r/compilers:.*:spex/, content)
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
    test_namespace_path = Path.join([working_dir, "test", "support", "#{app_name}_test.ex"])

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
    |> maybe_add_elixir_instructions(status)
    |> maybe_add_phoenix_installer_instructions(status)
    |> maybe_add_project_creation_instructions(status)
    |> maybe_add_deps_instructions(status)
    |> maybe_add_compiler_instructions(status)
    |> maybe_add_spex_config_instructions(status)
    |> maybe_add_sexy_spex_local_dep_note(status)
    |> maybe_add_test_boundaries_instructions(status)
    |> maybe_add_docs_instructions(status)
    |> maybe_add_agents_md_instructions(status)
    |> maybe_add_cli_config_instructions(status)
    |> maybe_add_ignored_components_instructions(status)
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

  defp maybe_add_compiler_instructions(
         sections,
         %{phoenix_project_exists: true, compilers_configured: false}
       ) do
    instruction = """
    ## Configure Compilers

    Add `:boundary` and `:spex` to the compilers list in `mix.exs`.
    The `:diagnostics` compiler must be first so its `after_compiler` hooks are
    registered before `:elixir` runs. The `:spex` compiler must come between
    `:elixir` and `:app` so Boundary can trace cross-module calls in spex files:

    ```elixir
    def project do
      [
        compilers: [:diagnostics, :boundary, :phoenix_live_view, :erlang, :elixir, :spex, :app],
        ...
      ]
    end
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
      use Boundary, top_level?: true, deps: [#{module_name}], check: [in: [:test], out: []]
    end
    ```

    **2. Create `test/support/#{app_name}_test.ex`:**
    ```elixir
    defmodule #{module_name}Test do
      use Boundary, top_level?: true, deps: [#{module_name}], check: [in: [:test], out: []]
    end
    ```

    These modules declare top-level boundaries for the test and spex namespaces,
    allowing Boundary to verify that test code only depends on the main application.
    """

    [instruction | sections]
  end

  defp maybe_add_test_boundaries_instructions(sections, _status), do: sections

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

  defp maybe_add_agents_md_instructions(sections, %{docs_agents_md_exists: true}), do: sections

  defp maybe_add_agents_md_instructions(sections, %{docs_agents_md_exists: false} = status) do
    [build_agents_md_instructions(status.app_name) | sections]
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
      {"Elixir 1.18+", status.elixir_installed},
      {"Phoenix installer", status.phoenix_installer_available},
      {"PostgreSQL", status.postgresql_available},
      {"Phoenix project", status.phoenix_project_exists},
      {"CodeMySpec deps", status.codemyspec_deps_installed},
      {"Compilers (boundary + spex)", status.compilers_configured},
      {"Spex config", status.spex_config_complete},
      {"Test boundaries", status.test_boundaries_configured},
      {"Docs repository", status.docs_repo_configured},
      {"Docs AGENTS.md", status.docs_agents_md_exists},
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
    Note: `:diagnostics` must be first so its `after_compiler` hooks are
    registered before `:elixir` runs. `:spex` must come between `:elixir`
    and `:app` so that Boundary can trace cross-module calls in spex files
    before its analysis runs:

    ```elixir
    def project do
      [
        compilers: [:diagnostics, :boundary, :phoenix_live_view, :erlang, :elixir, :spex, :app],
        spex: [pattern: "test/spex/**/*_spex.exs"],
        ...
      ]
    end
    ```

    The `:spex` compiler compiles your BDD spec `.exs` files and catches boundary
    violations. The `:diagnostics` compiler registers `after_compiler` hooks that
    write all diagnostics to a `diagnostics.jsonl` file, even when compilation
    fails with syntax errors.
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

  defp build_agents_md_instructions(app_name) do
    content = agents_md_content(app_name)

    """
    ## Create docs/AGENTS.md

    This file orients AI agents working on your project. Write the following to `docs/AGENTS.md`:

    ```markdown
    #{content}
    ```
    """
  end

  @doc """
  Generate the generalized AGENTS.md content for a project.

  Takes the app name (e.g., "my_app") and returns markdown content
  that orients agents to the project's docs structure.
  """
  def agents_md_content(app_name) do
    app = app_name || "your_app"

    """
    # Project Development Guide

    This guide describes how the project's `docs/` directory works so you can locate what you need efficiently.

    ## Project Structure

    ```
    docs/
    ├── AGENTS.md              ← You are here
    ├── architecture/          ← System component graph and dependencies
    ├── status/                ← Implementation status of every component
    ├── spec/                  ← Specifications for every module
    ├── rules/                 ← Coding standards by component type
    ├── issues/                ← Known bugs and technical debt
    └── knowledge/             ← Domain-specific operational knowledge
    ```

    ## Progressive Disclosure: Where to Look

    ### 1. Orientation — What exists and how it's organized

    Start here to understand the system shape.

    | Need | File |
    |---|---|
    | List of all components, types, and dependencies | `architecture/overview.md` |
    | Hierarchical tree view by Elixir namespace | `architecture/namespace_hierarchy.md` |
    | Dependency graph (Mermaid) | `architecture/dependency_graph.mmd` |

    ### 2. Status — What's done and what's not

    Check here before starting work on a component.

    | Need | File |
    |---|---|
    | Top-level status of all contexts | `status/#{app}.md` |
    | Web layer status | `status/#{app}_web.md` |
    | Status of a specific context | `status/#{app}/<context_name>.md` |

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
    | Spec for a module | `spec/<module_path>.spec.md` |

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
    | Context | `rules/context_design.md` | — |
    | Repository | `rules/repository_design.md` | `rules/repository_test.md` |
    | Schema | `rules/schema_design.md` | — |
    | LiveView | `rules/liveview_design.md` | — |
    | LiveView component | `rules/liveview_component_design.md` | — |
    | Elixir (general) | `rules/elixir_design.md` | `rules/elixir_test.md` |

    ### 5. Issues — Known problems and technical debt

    Check before working in an area to avoid known pitfalls.

    Issues live in `issues/` as individual markdown files describing the problem, reproduction steps, and possible solutions.

    ### 6. Knowledge — Operational knowledge

    Deep dives on specific topics that don't fit elsewhere. Check `knowledge/` for available guides.

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

    ## Working with the Docs Directory

    **Before implementing a component:**
    1. Check `status/` — is it already done?
    2. Read `spec/` — what should it do?
    3. Read `rules/` — what conventions apply to this component type?
    4. Check `issues/` — are there known problems in this area?

    **Before modifying an existing component:**
    1. Read the spec to understand the intended behavior
    2. Read the current implementation
    3. Check if there are open issues related to it
    4. Follow the rules for that component type

    **When you need context on the bigger picture:**
    1. Read `architecture/namespace_hierarchy.md` for the component tree
    2. Read `architecture/overview.md` for dependency relationships
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

  @required_check_keys [
    :elixir_installed,
    :phoenix_installer_available,
    :phoenix_project_exists,
    :codemyspec_deps_installed,
    :compilers_configured,
    :spex_config_complete,
    :docs_repo_configured,
    :docs_agents_md_exists,
    :docs_structure_complete,
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
       "Add compilers: [:diagnostics, :boundary, :phoenix_live_view, :erlang, :elixir, :spex, :app] to project/0"},
      {"Spex config", status.spex_config_complete,
       "Add spex pattern, elixirc_paths(:test) with test/spex, preferred_envs spex: :test, and spex alias"},
      {"Test boundaries", status.test_boundaries_configured,
       "Create boundary namespace modules in test/spex/ and test/support/ with use Boundary"},
      {"Docs repository", status.docs_repo_configured, "Create docs directory: mkdir -p docs"},
      {"Docs AGENTS.md", status.docs_agents_md_exists,
       "Create docs/AGENTS.md — see setup instructions for content"},
      {"Docs structure", status.docs_structure_complete,
       "Create directories: #{Enum.join(status.missing_docs_dirs, ", ")}"},
      {"CLI config", status.cli_config_has_project_id,
       "Create .code_my_spec/config.yml with project_id from CodeMySpec server"}
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
