defmodule CodeMySpec.Paths do
  @moduledoc """
  Central path resolution for all project resource directories.

  Project resource paths are relative to the project root directory. Every module that needs
  to reference a .code_my_spec/spec/status/architecture/knowledge path should use this
  module instead of hardcoding strings. Machine state and generated projects
  live under `~/.codemyspec`, separate from project resources.
  """

  use Boundary, top_level?: true, deps: []

  @base_dir ".code_my_spec"

  # ============================================================================
  # Base directory
  # ============================================================================

  @doc "The root resource directory (`.code_my_spec`)."
  def base_dir, do: @base_dir

  @doc "The user's CodeMySpec state directory, independent of workspace identity."
  @spec user_state_dir() :: String.t()
  def user_state_dir do
    home =
      if Code.ensure_loaded?(Desktop.OS),
        do: apply(Desktop.OS, :home, []),
        else: System.user_home!()

    home |> Path.join(".codemyspec") |> expand()
  end

  @doc """
  This machine's state directory. On a laptop it is `~/.codemyspec`.
  With `CMS_PROJECT_DIR`, it remains beside that workspace's checkout so
  independent workspaces never reuse the host's machine identity.
  """
  @spec local_state_dir() :: String.t()
  def local_state_dir do
    case System.get_env("CMS_PROJECT_DIR") do
      dir when is_binary(dir) and dir != "" -> dir |> expand() |> Path.dirname()
      _ -> user_state_dir()
    end
  end

  @doc "Normalize an absolute path using Desktop's platform-aware expansion when available."
  @spec expand(Path.t()) :: String.t()
  def expand(path) do
    if Code.ensure_loaded?(Desktop.OS),
      do: apply(Desktop.OS, :path_expand, [path]),
      else: Path.expand(path)
  end

  @doc "Detached agent runtime storage, preserving the configured explicit override."
  def agents_root do
    (Application.get_env(:code_my_spec, :detached_agents_root) ||
       Path.join(local_state_dir(), "agents"))
    |> expand()
  end

  @doc "Scratch files outside any project checkout."
  def scratch_root, do: Path.join(local_state_dir(), "scratch")

  @doc "Default destination for generated projects without a user-selected directory."
  def projects_root, do: Path.join(local_state_dir(), "projects")

  @doc "Default folder for a new local project; resolving it does not create or move files."
  def project_home(%{name: name, id: id}) do
    folder =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 80)

    folder =
      if folder == "" or Regex.match?(~r/^(con|prn|aux|nul|com[0-9]|lpt[0-9])$/, folder),
        do: "project-#{id}",
        else: folder

    Path.join(projects_root(), folder)
  end

  @doc "The desktop SQLite database, preserving CMS_DESKTOP_DB when supplied."
  def desktop_database do
    (System.get_env("CMS_DESKTOP_DB") || Path.join(user_state_dir(), "desktop.db"))
    |> expand()
  end

  # ============================================================================
  # Top-level directories
  # ============================================================================

  @doc "Persona research directory (`.code_my_spec/personas`)."
  def personas_dir, do: Path.join(@base_dir, "personas")

  @doc "Architecture directory (`.code_my_spec/architecture`): the proposal and decisions."
  def architecture_dir, do: Path.join(@base_dir, "architecture")

  @doc "Architecture decision records directory (`.code_my_spec/architecture/decisions`)."
  def decisions_dir, do: Path.join(@base_dir, "architecture/decisions")

  @doc "Knowledge directory for project-specific research (`.code_my_spec/knowledge`)."
  def knowledge_dir, do: Path.join(@base_dir, "knowledge")

  @doc "Rules directory (`.code_my_spec/rules`)."
  def rules_dir, do: Path.join(@base_dir, "rules")

  @doc "Design assets directory (`.code_my_spec/design`)."
  def design_dir, do: Path.join(@base_dir, "design")

  @doc "QA results directory (`.code_my_spec/qa`)."
  def qa_dir, do: Path.join(@base_dir, "qa")

  @doc "QA scripts directory (`.code_my_spec/qa/scripts`)."
  def qa_scripts_dir, do: Path.join(@base_dir, "qa/scripts")

  @doc "Integrations directory (`.code_my_spec/integrations`)."
  def integrations_dir, do: Path.join(@base_dir, "integrations")

  @doc "Prod release records directory (`.code_my_spec/releases`)."
  def releases_dir, do: Path.join(@base_dir, "releases")

  @doc "Credo custom checks directory (`.code_my_spec/credo_checks`)."
  def credo_checks_dir, do: Path.join(@base_dir, "credo_checks")

  @doc "Framework-provided Credo checks (`.code_my_spec/credo_checks/framework`). Synced from app's priv/credo_checks/."
  def credo_checks_framework_dir, do: Path.join(credo_checks_dir(), "framework")

  @doc "Project-specific local Credo checks (`.code_my_spec/credo_checks/local`). Never touched by sync."
  def credo_checks_local_dir, do: Path.join(credo_checks_dir(), "local")

  @doc "Task prompts and ephemeral agent outputs directory (`.code_my_spec/tasks`)."
  def tasks_dir, do: Path.join(@base_dir, "tasks")

  @doc "Transient research prompts directory (`.code_my_spec/tasks/research`)."
  def research_dir, do: Path.join(tasks_dir(), "research")

  # ============================================================================
  # Well-known files
  # ============================================================================

  @doc "Architecture decisions index file."
  def decisions_index, do: Path.join(@base_dir, "architecture/decisions.md")

  @doc "Architecture proposal file."
  def proposal_path, do: Path.join(@base_dir, "architecture/proposal.md")

  @doc "QA summary file."
  def qa_summary, do: Path.join(@base_dir, "qa/summary.md")

  @doc "QA plan document."
  def qa_plan, do: Path.join(@base_dir, "qa/plan.md")

  @doc "QA journey plan document."
  def qa_journey_plan, do: Path.join(@base_dir, "qa/journey_plan.md")

  @doc "QA journey result document."
  def qa_journey_result, do: Path.join(@base_dir, "qa/journey_result.md")

  @doc "QA journey LiveView test directory (relative, target project)."
  def qa_journey_tests_dir, do: "test/journeys"

  @doc "Integrations index file (`.code_my_spec/integrations.md`)."
  def integrations_index, do: Path.join(@base_dir, "integrations.md")

  @doc "Design system HTML file."
  def design_system_path, do: Path.join(@base_dir, "design/design_system.html")

  # ============================================================================
  # Derived paths (take a module path or topic name)
  # ============================================================================

  @doc "Design file path for a module path."
  def design_file(module_path), do: Path.join(design_dir(), "#{module_path}.md")

  # ============================================================================
  # Glob patterns
  # ============================================================================

  @doc "Glob pattern for knowledge files under a topic."
  def knowledge_topic_glob(topic), do: Path.join(knowledge_dir(), "#{topic}/**")
end
