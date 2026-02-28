defmodule CodeMySpec.Paths do
  @moduledoc """
  Central path resolution for all project resource directories.

  All paths are relative to the project root directory. Every module that needs
  to reference a .code_my_spec/spec/status/architecture/knowledge path should use this
  module instead of hardcoding strings.
  """

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

  @doc "Status files directory (`.code_my_spec/status`)."
  def status_dir, do: Path.join(@base_dir, "status")

  @doc "Architecture views directory (`.code_my_spec/architecture`)."
  def architecture_dir, do: Path.join(@base_dir, "architecture")

  @doc "Architecture decision records directory (`.code_my_spec/architecture/decisions`)."
  def decisions_dir, do: Path.join(@base_dir, "architecture/decisions")

  @doc "Knowledge directory for project-specific research (`.code_my_spec/knowledge`)."
  def knowledge_dir, do: Path.join(@base_dir, "knowledge")

  @doc "Framework knowledge directory (`.code_my_spec/framework`). Symlinked to app's priv/knowledge/."
  def framework_dir, do: Path.join(@base_dir, "framework")

  @doc "Tools directory (`.code_my_spec/tools`). Symlinked to app's priv/tools/."
  def tools_dir, do: Path.join(@base_dir, "tools")

  @doc "Rules directory (`.code_my_spec/rules`)."
  def rules_dir, do: Path.join(@base_dir, "rules")

  @doc "Design assets directory (`.code_my_spec/design`)."
  def design_dir, do: Path.join(@base_dir, "design")

  @doc "Issues directory (`.code_my_spec/issues`)."
  def issues_dir, do: Path.join(@base_dir, "issues")

  @doc "QA results directory (`.code_my_spec/qa`)."
  def qa_dir, do: Path.join(@base_dir, "qa")

  @doc "Transient research prompts directory (`.code_my_spec/status/research`)."
  def research_dir, do: Path.join(@base_dir, "status/research")

  @doc "Sessions directory (`.code_my_spec/sessions`)."
  def sessions_dir, do: Path.join(@base_dir, "sessions")

  @doc "Completed sessions directory (`.code_my_spec/sessions/completed`)."
  def completed_sessions_dir, do: Path.join(@base_dir, "sessions/completed")

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

  @doc "Design system HTML file."
  def design_system_path, do: Path.join(@base_dir, "design/design_system.html")

  @doc "Implementation status JSON file."
  def implementation_status_path, do: Path.join(@base_dir, "status/implementation_status.json")

  # ============================================================================
  # Derived paths (take a module path or topic name)
  # ============================================================================

  @doc "Spec file path for a module path (e.g., `my_app/accounts` → `.code_my_spec/spec/my_app/accounts.spec.md`)."
  def spec_file(module_path), do: Path.join(spec_dir(), "#{module_path}.spec.md")

  @doc "Design file path for a module path."
  def design_file(module_path), do: Path.join(design_dir(), "#{module_path}.md")

  @doc "Design review file path for a context module path."
  def review_file(module_path), do: Path.join(spec_dir(), "#{module_path}/design_review.md")

  @doc "Decision record file for a topic."
  def decision_file(topic), do: Path.join(decisions_dir(), "#{topic}.md")

  @doc "Research prompt file for a topic."
  def research_file(topic), do: Path.join(research_dir(), "#{topic}.md")

  @doc "Knowledge directory for a topic."
  def knowledge_topic_dir(topic), do: Path.join(knowledge_dir(), topic)

  @doc "Status file for a named entity (e.g., app name)."
  def status_file(name), do: Path.join(status_dir(), "#{name}.md")

  # ============================================================================
  # Glob patterns
  # ============================================================================

  @doc "Glob pattern for all spec files."
  def spec_glob, do: Path.join(spec_dir(), "**/*.spec.md")

  @doc "Glob pattern for decision files."
  def decisions_glob, do: Path.join(decisions_dir(), "*.md")

  @doc "Glob pattern for knowledge files under a topic."
  def knowledge_topic_glob(topic), do: Path.join(knowledge_dir(), "#{topic}/**")

  @doc "Glob pattern for research prompt files."
  def research_glob, do: Path.join(research_dir(), "*.md")

  # ============================================================================
  # Prefix helpers (for stripping/adding spec dir prefix)
  # ============================================================================

  @doc """
  The spec directory prefix with trailing slash, for use in `String.replace_prefix/2`.

  Returns `".code_my_spec/spec/"`.
  """
  def spec_prefix, do: spec_dir() <> "/"
end
