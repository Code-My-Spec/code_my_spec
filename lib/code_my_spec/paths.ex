defmodule CodeMySpec.Paths do
  @moduledoc """
  Central path resolution for all project resource directories.

  All paths are relative to the project root directory. Every module that needs
  to reference a .code_my_spec/spec/status/architecture/knowledge path should use this
  module instead of hardcoding strings.
  """

  use Boundary, top_level?: true, deps: [], exports: :all

  @base_dir ".code_my_spec"

  # ============================================================================
  # Base directory
  # ============================================================================

  @doc "The root resource directory (`.code_my_spec`)."
  def base_dir, do: @base_dir

  # ============================================================================
  # Top-level directories
  # ============================================================================

  @doc "Spec files directory (`.code_my_spec/spec`)."
  def spec_dir, do: Path.join(@base_dir, "spec")

  @doc "Persona research directory (`.code_my_spec/personas`)."
  def personas_dir, do: Path.join(@base_dir, "personas")

  @doc "Architecture views directory (`.code_my_spec/architecture`)."
  def architecture_dir, do: Path.join(@base_dir, "architecture")

  @doc "Architecture decision records directory (`.code_my_spec/architecture/decisions`)."
  def decisions_dir, do: Path.join(@base_dir, "architecture/decisions")

  @doc "Knowledge directory for project-specific research (`.code_my_spec/knowledge`)."
  def knowledge_dir, do: Path.join(@base_dir, "knowledge")

  @doc "Hex doc projection directory (`.code_my_spec/hex_docs`). Populated by the projector that reads EEP-48 docs from compiled BEAMs in `_build/<env>/lib/<package>/ebin`."
  def hex_docs_dir, do: Path.join(@base_dir, "hex_docs")

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

  @doc "QA journey Wallaby test directory (relative, target project)."
  def qa_journey_wallaby_dir, do: "test/journeys"

  @doc "Integrations index file (`.code_my_spec/integrations.md`)."
  def integrations_index, do: Path.join(@base_dir, "integrations.md")

  @doc "Design system HTML file."
  def design_system_path, do: Path.join(@base_dir, "design/design_system.html")

  # ============================================================================
  # Derived paths (take a module path or topic name)
  # ============================================================================

  @doc "Spec file path for a module path (e.g., `my_app/accounts` → `.code_my_spec/spec/my_app/accounts.spec.md`)."
  def spec_file(module_path), do: Path.join(spec_dir(), "#{module_path}.spec.md")

  @doc "Design file path for a module path."
  def design_file(module_path), do: Path.join(design_dir(), "#{module_path}.md")

  @doc "Design review file path for a context module path."
  def review_file(module_path), do: Path.join(spec_dir(), "#{module_path}/design_review.md")

  # ============================================================================
  # Glob patterns
  # ============================================================================

  @doc "Glob pattern for knowledge files under a topic."
  def knowledge_topic_glob(topic), do: Path.join(knowledge_dir(), "#{topic}/**")

  # ============================================================================
  # Prefix helpers (for stripping/adding spec dir prefix)
  # ============================================================================

  @doc """
  The spec directory prefix with trailing slash, for use in `String.replace_prefix/2`.

  Returns `".code_my_spec/spec/"`.
  """
  def spec_prefix, do: spec_dir() <> "/"
end
