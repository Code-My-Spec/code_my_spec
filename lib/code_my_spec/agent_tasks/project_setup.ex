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

  @claude_md_start_marker "<!-- code_my_spec:start -->"
  @claude_md_end_marker "<!-- code_my_spec:end -->"

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
  Evaluate setup completion by running each step's evaluate.

  Returns:
  - `{:ok, :valid}` if all steps pass
  - `{:ok, :invalid, feedback}` listing incomplete steps
  """
  @spec evaluate(term(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(scope, _task, _opts \\ []) do
    steps = build_step_status(scope)
    incomplete = Enum.reject(steps, & &1.done)

    if incomplete == [] do
      {:ok, :valid}
    else
      feedback =
        incomplete
        |> Enum.map_join("\n", fn step -> "- [ ] #{step.name}" end)

      {:ok, :invalid, "Setup incomplete (#{length(incomplete)} steps remaining):\n\n#{feedback}"}
    end
  end

  # Installation helpers

  defp extract_app_name(mix_exs_path) do
    case File.read(mix_exs_path) do
      {:ok, content} ->
        case Regex.run(~r/app:\s*:(\w+)/, content) do
          [_, app_name] -> app_name
          _ -> nil
        end

      _ ->
        nil
    end
  end

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

end
