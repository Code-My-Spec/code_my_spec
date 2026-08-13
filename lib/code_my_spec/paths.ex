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

  @doc "Tools directory (`.code_my_spec/tools`). Copied from app's priv/tools/ on CLI startup."
  def tools_dir, do: Path.join(@base_dir, "tools")

  @doc "Rules directory (`.code_my_spec/rules`)."
  def rules_dir, do: Path.join(@base_dir, "rules")

  @doc "Design assets directory (`.code_my_spec/design`)."
  def design_dir, do: Path.join(@base_dir, "design")

  @doc """
  Braindump directory (`.code_my_spec/issues`). Hand-written notes, read by
  `Issues.create_from_braindump/3`. Not a projection — triaged issues live only
  in the database and are reached through the MCP tools.
  """
  def issues_dir, do: Path.join(@base_dir, "issues")

  @doc "QA results directory (`.code_my_spec/qa`)."
  def qa_dir, do: Path.join(@base_dir, "qa")

  @doc "QA scripts directory (`.code_my_spec/qa/scripts`)."
  def qa_scripts_dir, do: Path.join(@base_dir, "qa/scripts")

  @doc "Integrations directory (`.code_my_spec/integrations`)."
  def integrations_dir, do: Path.join(@base_dir, "integrations")

  @doc "DevOps artifacts directory (`.code_my_spec/devops`)."
  def devops_dir, do: Path.join(@base_dir, "devops")

  @doc "DevOps setup record (`.code_my_spec/devops/setup.md`)."
  def devops_setup_record, do: Path.join(devops_dir(), "setup.md")

  @doc "Per-story deploy records directory (`.code_my_spec/devops/deploys`)."
  def devops_deploys_dir, do: Path.join(devops_dir(), "deploys")

  @doc "Deploy record for one story (`.code_my_spec/devops/deploys/story_<id>.md`)."
  def devops_deploy_record(story_id), do: Path.join(devops_deploys_dir(), "story_#{story_id}.md")

  @doc "Prod release records directory (`.code_my_spec/releases`)."
  def releases_dir, do: Path.join(@base_dir, "releases")

  @doc "Release record for one version (`.code_my_spec/releases/<version>.md`)."
  def release_record(version), do: Path.join(releases_dir(), "#{version}.md")

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

  @doc "Integration spec file for a named integration."
  def integration_file(name), do: Path.join(integrations_dir(), "#{name}.md")

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
