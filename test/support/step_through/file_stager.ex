defmodule CodeMySpec.StepThrough.FileStager do
  @moduledoc """
  Satisfies requirements by copying files from a golden source or performing DB operations.

  Given a requirement returned by `ProjectCoordinator.get_next_actions/1`, determines
  what action is needed and performs it. File-based requirements copy from `golden_dir`
  to `working_dir`. DB-based requirements update records directly.

  Designed for math_test_project but the pattern generalizes.
  """

  alias CodeMySpec.BddSpecs
  alias CodeMySpec.Components
  alias CodeMySpec.Components.HierarchicalTree
  alias CodeMySpec.{Environments, Issues, Paths, Problems}
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils
  alias CodeMySpec.Validation.Pipeline

  # Story title → surface component module_name mapping for math_test_project
  @story_component_map %{
    "Addition" => "MathTestProjectWeb.CalculationLive.Addition",
    "Subtraction" => "MathTestProjectWeb.CalculationLive.Subtraction",
    "Calculation History" => "MathTestProjectWeb.CalculationLive.History",
    "Clear History" => "MathTestProjectWeb.CalculationLive.History"
  }

  @type action :: {:copied, [String.t()]} | {:db_op, String.t()} | {:no_op, String.t()} | {:error, String.t()}

  @doc """
  Satisfy a requirement by copying files or performing DB operations.
  Returns `{:ok, action}` describing what was done.
  """
  @spec satisfy(Requirement.t(), Scope.t(), String.t()) :: {:ok, action()}
  def satisfy(%Requirement{} = req, %Scope{} = scope, golden_dir) do
    cond do
      req.component_id -> satisfy_component(req, scope, golden_dir)
      req.story_id -> satisfy_story(req, scope, golden_dir)
      req.project_id -> satisfy_project(req, scope, golden_dir)
      true -> {:ok, {:error, "Requirement has no entity: #{req.name}"}}
    end
  end

  # ============================================================================
  # Component Requirements
  # ============================================================================

  defp satisfy_component(req, scope, golden_dir) do
    component = Components.get_component!(scope, req.component_id)
    project = scope.active_project
    files = Utils.component_files(component, project)
    working_dir = scope.cwd

    case req.name do
      # File-based: copy from golden
      name when name in ~w(spec_file implementation_file test_file review_file json_file) ->
        file_key = file_key(name)
        rel_path = Map.get(files, file_key)
        IO.puts("    #{component.module_name} #{name} → #{file_key}: #{rel_path || "nil"}")

        if rel_path do
          copy_file(golden_dir, working_dir, rel_path)
        else
          {:ok, {:error, "No #{file_key} path for #{component.module_name}"}}
        end

      # Children: copy all children's files of the required type
      "children_designs" ->
        copy_children_artifact(component, scope, golden_dir, :spec_file)

      "children_implementations" ->
        copy_children_artifact(component, scope, golden_dir, :code_file)

      # Derived/computed: satisfied when prerequisites are met
      name when name in ~w(spec_valid review_valid test_spec_alignment tests_passing dependencies_satisfied) ->
        {:ok, {:no_op, "#{name}: satisfied by prerequisites"}}

      other ->
        {:ok, {:error, "Unknown component requirement: #{other}"}}
    end
  end

  defp copy_children_artifact(parent, scope, golden_dir, file_key) do
    children = Components.list_child_components(scope, parent.id)
    project = scope.active_project
    working_dir = scope.cwd

    copied =
      children
      |> Enum.map(fn child ->
        child_files = Utils.component_files(child, project)
        rel_path = Map.get(child_files, file_key)
        copy_if_missing(golden_dir, working_dir, rel_path)
      end)
      |> Enum.reject(&is_nil/1)

    if copied == [] do
      {:ok, {:no_op, "All children already have #{file_key}"}}
    else
      {:ok, {:copied, copied}}
    end
  end

  # ============================================================================
  # Story Requirements
  # ============================================================================

  defp satisfy_story(req, scope, golden_dir) do
    story = Stories.get_story!(scope, req.story_id)

    case req.name do
      "component_linked" ->
        link_story_to_component(story, scope)

      "bdd_specs_exist" ->
        copy_bdd_specs(story, scope, golden_dir)

      "bdd_specs_passing" ->
        run_spex_for_story(story, scope)

      "component_complete" ->
        # Descend into the component tree and copy all missing files,
        # then run spex to populate the problems table
        with {:ok, action} <- satisfy_component_tree(story, scope, golden_dir) do
          spex_result = run_spex_for_story(story, scope)
          IO.puts("    Spex after component_complete: #{inspect(elem(spex_result, 1))}")
          {:ok, action}
        end

      "qa_complete" ->
        create_story_qa_result(story, scope)

      other ->
        {:ok, {:error, "Unknown story requirement: #{other}"}}
    end
  end

  defp satisfy_component_tree(%{component_id: nil} = story, _scope, _golden_dir) do
    {:ok, {:error, "Story '#{story.title}' has no linked component"}}
  end

  defp satisfy_component_tree(story, scope, golden_dir) do
    root = Components.get_component!(scope, story.component_id)
    all_components = Components.list_components(scope)
    descendants = HierarchicalTree.get_all_descendants(root, all_components)
    tree = [root | descendants]

    copied = copy_missing_tree_files(tree, scope, golden_dir)

    if copied == [] do
      {:ok, {:no_op, "All files already exist in component tree (#{length(tree)} components)"}}
    else
      {:ok, {:copied, copied}}
    end
  end

  defp copy_missing_tree_files(tree, scope, golden_dir) do
    project = scope.active_project
    working_dir = scope.cwd

    all_paths = Enum.flat_map(tree, &missing_component_files(&1, project))
    missing = Enum.filter(all_paths, &(!file_exists_in_dir?(working_dir, &1)))

    IO.puts("    Tree files: #{length(all_paths)} total, #{length(missing)} missing in working dir")

    Enum.flat_map(missing, fn rel_path ->
      result = copy_file(golden_dir, working_dir, rel_path)

      case result do
        {:ok, {:copied, _}} ->
          [rel_path]

        {:ok, {:error, reason}} ->
          IO.puts("    SKIP: #{rel_path} — #{reason}")
          []
      end
    end)
  end

  defp link_story_to_component(story, scope) do
    # Find matching component by story title
    components = Components.list_components(scope)

    target_module =
      Enum.find_value(@story_component_map, fn {title_pattern, module_name} ->
        if String.contains?(story.title, title_pattern), do: module_name
      end)

    component = Enum.find(components, &(&1.module_name == target_module))

    if component do
      {:ok, _} = Stories.set_story_component(scope, story, component.id)
      {:ok, {:db_op, "Linked '#{story.title}' → #{component.module_name}"}}
    else
      {:ok, {:error, "No component match for story '#{story.title}'"}}
    end
  end

  defp copy_bdd_specs(story, scope, golden_dir) do
    env = scope.environment
    working_dir = scope.cwd

    # Find BDD spec files in the golden source
    golden_env = %{env | cwd: golden_dir}
    specs = BddSpecs.list_specs_for_story(golden_env, story.id)

    if specs == [] do
      # No specs in golden source — create a minimal passing spec
      {:ok, {:no_op, "No BDD specs in golden for story ##{story.id} '#{story.title}'"}}
    else
      copied =
        Enum.map(specs, fn spec ->
          # spec.file_path may be absolute — make it relative to golden_dir
          rel_path = Path.relative_to(spec.file_path, golden_dir)
          copy_file(golden_dir, working_dir, rel_path)
          rel_path
        end)

      {:ok, {:copied, copied}}
    end
  end

  defp create_story_qa_result(story, scope) do
    working_dir = scope.cwd
    qa_dir = Path.join(working_dir, ".code_my_spec/qa/#{story.id}")
    result_path = Path.join(qa_dir, "result.md")

    File.mkdir_p!(qa_dir)

    File.write!(result_path, String.trim_leading("""
    # QA Result: #{story.title}

    ## Status: passed

    ## Summary
    All acceptance criteria verified via automated step-through.

    ## Evidence
    - Step-through auto-satisfied all requirements
    """))

    {:ok, {:copied, [".code_my_spec/qa/#{story.id}/result.md"]}}
  end

  defp run_spex_for_story(story, scope) do
    env = scope.environment
    working_dir = scope.cwd
    specs = BddSpecs.list_specs_for_story(env, story.id)

    if specs == [] do
      {:ok, {:no_op, "No BDD spec files for story ##{story.id}"}}
    else
      spex_files = Enum.map(specs, & &1.file_path)
      IO.puts("    Running spex for story ##{story.id}: #{length(spex_files)} file(s)")

      {:ok, problems} = Pipeline.run_spex(spex_files, scope)

      # Store problems with relative paths to avoid varchar(255) overflow
      rel_spex_files = Enum.map(spex_files, &Path.relative_to(&1, working_dir))

      rel_problems =
        Enum.map(problems, fn p ->
          %{p | file_path: Path.relative_to(p.file_path || "", working_dir)}
        end)

      Problems.replace_problems_for_files(scope, rel_spex_files, rel_problems)

      if problems == [] do
        {:ok, {:db_op, "Spex passed for story ##{story.id} (#{length(spex_files)} files, 0 problems)"}}
      else
        {:ok, {:db_op, "Spex ran for story ##{story.id} (#{length(problems)} problems)"}}
      end
    end
  end

  # ============================================================================
  # Project Requirements
  # ============================================================================

  defp satisfy_project(req, scope, _golden_dir) do
    case req.name do
      # Already satisfied by architecture files that exist
      name when name in ~w(technical_strategy architecture_designed) ->
        {:ok, {:no_op, "#{name}: architecture files should already exist"}}

      "issues_triaged" ->
        triage_all_incoming_issues(scope)

      "issues_resolved" ->
        resolve_all_accepted_issues(scope)

      "all_stories_complete" ->
        {:ok, {:no_op, "all_stories_complete: satisfied when sub-requirements are met"}}

      "all_bdd_specs_passing" ->
        # Clear stale spex problems (from previous runs with different working dirs)
        Problems.clear_problems_for_source(scope, [source: "spex"], :all)
        {:ok, {:db_op, "Cleared stale spex problems"}}

      "qa_journey_plan" ->
        create_qa_journey_artifact(scope, "journey_plan.md", "QA Journey Plan")

      "qa_journey_execute" ->
        create_qa_journey_artifact(scope, "journey_result.md", "QA Journey Result")

      "qa_journey_wallaby" ->
        create_wallaby_test(scope)

      other ->
        {:ok, {:error, "Unknown project requirement: #{other}"}}
    end
  end

  defp create_qa_journey_artifact(scope, "journey_plan.md" = filename, _title) do
    working_dir = scope.cwd
    qa_dir = Path.join(working_dir, ".code_my_spec/qa")
    path = Path.join(qa_dir, filename)

    File.mkdir_p!(qa_dir)

    File.write!(path, String.trim_leading("""
    # QA Journey Plan

    ## Prerequisites

    - Application running locally
    - Database seeded with test data

    ## Journeys

    ### Perform Addition
    - Role: User
    - Steps:
      1. Navigate to /addition
      2. Enter first number and second number
      3. Click Calculate
    - Expected outcome: Sum is displayed

    ### Perform Subtraction
    - Role: User
    - Steps:
      1. Navigate to /subtraction
      2. Enter first number and second number
      3. Click Calculate
    - Expected outcome: Difference is displayed
    """))

    {:ok, {:copied, [".code_my_spec/qa/#{filename}"]}}
  end

  defp create_qa_journey_artifact(scope, "journey_result.md" = filename, _title) do
    working_dir = scope.cwd
    qa_dir = Path.join(working_dir, ".code_my_spec/qa")
    path = Path.join(qa_dir, filename)

    File.mkdir_p!(qa_dir)

    File.write!(path, String.trim_leading("""
    # QA Journey Result

    ## Status

    pass

    ## Journey Results

    ### Perform Addition
    - Status: passed
    - All acceptance criteria verified

    ### Perform Subtraction
    - Status: passed
    - All acceptance criteria verified
    """))

    {:ok, {:copied, [".code_my_spec/qa/#{filename}"]}}
  end

  defp create_wallaby_test(scope) do
    working_dir = scope.cwd
    dir = Path.join(working_dir, "test/journeys")
    path = Path.join(dir, "calculation_journey_test.exs")

    File.mkdir_p!(dir)

    File.write!(path, String.trim_leading("""
    defmodule MathTestProjectWeb.CalculationJourneyTest do
      use ExUnit.Case

      # Auto-generated by step-through runner
      test "placeholder journey test" do
        assert true
      end
    end
    """))

    {:ok, {:copied, ["test/journeys/calculation_journey_test.exs"]}}
  end

  # ============================================================================
  # Issue Triage & Resolution
  # ============================================================================

  defp triage_all_incoming_issues(scope) do
    env = scope.environment
    incoming = Issues.list_by_status(scope, :incoming)

    if incoming == [] do
      {:ok, {:no_op, "issues_triaged: no incoming issues"}}
    else
      # Edit each projected file: change ## Status from incoming → accepted
      Enum.each(incoming, fn issue ->
        filename = Issues.projected_filename(issue)
        path = Path.join(Paths.issues_incoming_dir(), filename)

        case Environments.read_file(env, path) do
          {:ok, content} ->
            updated = String.replace(content, ~r/^(## Status\s*\n\s*)incoming/m, "\\1accepted")
            Environments.write_file(env, path, updated)

          {:error, _} ->
            :skip
        end
      end)

      # Reconcile reads the status field, updates DB, re-projects (moves files)
      Issues.reconcile_triage(scope)

      {:ok, {:db_op, "Triaged #{length(incoming)} incoming issues → accepted"}}
    end
  end

  defp resolve_all_accepted_issues(scope) do
    env = scope.environment
    accepted = Issues.list_by_status(scope, :accepted)
    # Only resolve medium+ (matching what the checker looks at)
    actionable = Enum.filter(accepted, &(&1.severity in [:critical, :high, :medium]))

    if actionable == [] do
      {:ok, {:no_op, "issues_resolved: no medium+ accepted issues"}}
    else
      # Edit each projected file: add ## Resolution section
      Enum.each(actionable, fn issue ->
        filename = Issues.projected_filename(issue)
        path = Path.join(Paths.issues_accepted_dir(), filename)

        case Environments.read_file(env, path) do
          {:ok, content} ->
            unless String.contains?(content, "## Resolution") do
              updated = content <> "\n## Resolution\n\nResolved via step-through auto-walker.\n"
              Environments.write_file(env, path, updated)
            end

          {:error, _} ->
            :skip
        end
      end)

      # Reconcile reads resolution sections, updates DB
      Issues.reconcile_resolutions(scope)

      {:ok, {:db_op, "Resolved #{length(actionable)} accepted issues"}}
    end
  end

  # ============================================================================
  # File Helpers
  # ============================================================================

  defp copy_file(golden_dir, working_dir, rel_path) do
    src = Path.join(golden_dir, rel_path)
    dst = Path.join(working_dir, rel_path)

    if File.exists?(src) do
      File.mkdir_p!(Path.dirname(dst))
      File.cp!(src, dst)
      {:ok, {:copied, [rel_path]}}
    else
      {:ok, {:error, "Golden file missing: #{rel_path}"}}
    end
  end

  defp missing_component_files(component, project) do
    files = Utils.component_files(component, project)

    [:spec_file, :code_file, :test_file, :review_file]
    |> Enum.map(&Map.get(files, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp file_exists_in_dir?(dir, rel_path) do
    Path.join(dir, rel_path) |> File.exists?()
  end

  defp copy_if_missing(_golden_dir, _working_dir, nil), do: nil

  defp copy_if_missing(golden_dir, working_dir, rel_path) do
    if file_exists_in_dir?(working_dir, rel_path) do
      nil
    else
      case copy_file(golden_dir, working_dir, rel_path) do
        {:ok, {:copied, _}} -> rel_path
        _ -> nil
      end
    end
  end

  defp file_key("spec_file"), do: :spec_file
  defp file_key("implementation_file"), do: :code_file
  defp file_key("test_file"), do: :test_file
  defp file_key("review_file"), do: :review_file
  defp file_key("json_file"), do: :json_file

  # ============================================================================
  # Project Stripping (for full walkthrough from zero)
  # ============================================================================

  @doc """
  Strips a project working directory to skeleton state.
  Removes specs, implementations, tests, BDD specs, reviews, QA artifacts.
  Keeps: Phoenix boilerplate, config.yml, architecture files, rules, framework.
  """
  def strip_to_skeleton(working_dir) do
    # Keep spec files — they drive component discovery during sync.
    # The step-through creates implementations, tests, and BDD specs incrementally.

    # Remove review files (created by design review task)
    glob_delete(working_dir, ".code_my_spec/spec/**/design_review.md")

    # Remove QA artifacts
    qa_dir = Path.join(working_dir, ".code_my_spec/qa")
    if File.dir?(qa_dir), do: File.rm_rf!(qa_dir)

    # Remove BDD spec files (test/spex/)
    spex_dir = Path.join(working_dir, "test/spex")
    if File.dir?(spex_dir), do: File.rm_rf!(spex_dir)

    # Remove journey tests
    journeys_dir = Path.join(working_dir, "test/journeys")
    if File.dir?(journeys_dir), do: File.rm_rf!(journeys_dir)

    # Remove custom implementation files (contexts, schemas, LiveViews)
    # Keep Phoenix boilerplate: application.ex, endpoint.ex, router.ex, gettext.ex,
    # telemetry.ex, repo.ex, mailer.ex, core_components.ex, error_*, page_*
    strip_custom_implementations(working_dir)

    # Remove custom test files (LiveView tests)
    # Keep: conn_case.ex, data_case.ex, test_helper.exs, controller tests
    strip_custom_tests(working_dir)

    :ok
  end

  # Files that are Phoenix boilerplate and should NOT be stripped
  @boilerplate_patterns ~w(
    application.ex endpoint.ex router.ex gettext.ex telemetry.ex
    repo.ex mailer.ex core_components.ex layouts.ex
    root.html.heex app.html.heex
    error_html.ex error_json.ex page_controller.ex page_html.ex home.html.heex
  )

  defp strip_custom_implementations(working_dir) do
    lib_dir = Path.join(working_dir, "lib")

    Path.wildcard(Path.join(lib_dir, "**/*.{ex,heex}"))
    |> Enum.reject(fn path -> boilerplate_file?(path) or root_module_file?(path, lib_dir) end)
    |> Enum.each(&File.rm/1)

    # Clean up empty directories left behind
    cleanup_empty_dirs(Path.join(working_dir, "lib"))
  end

  defp strip_custom_tests(working_dir) do
    test_dir = Path.join(working_dir, "test")

    # Remove custom test files, keep controller tests and support files
    Path.wildcard(Path.join(test_dir, "**/*_test.exs"))
    |> Enum.reject(fn path -> boilerplate_file?(path) or controller_test?(path) end)
    |> Enum.each(&File.rm/1)

    cleanup_empty_dirs(Path.join(working_dir, "test"))
  end

  defp boilerplate_file?(path) do
    basename = Path.basename(path)
    Enum.any?(@boilerplate_patterns, &(basename == &1))
  end

  # Root-level modules (e.g. lib/math_test_project.ex, lib/math_test_project_web.ex)
  # are Phoenix boilerplate and should never be stripped.
  defp root_module_file?(path, lib_dir) do
    Path.dirname(path) == lib_dir
  end

  # Controller tests are Phoenix boilerplate (error_html_test, page_controller_test, etc.)
  defp controller_test?(path) do
    String.contains?(path, "/controllers/")
  end

  defp cleanup_empty_dirs(dir) do
    if File.dir?(dir) do
      Path.wildcard(Path.join(dir, "**"))
      |> Enum.sort(:desc)
      |> Enum.filter(fn path -> File.dir?(path) and File.ls!(path) == [] end)
      |> Enum.each(&File.rmdir/1)
    end
  end

  defp glob_delete(base_dir, pattern) do
    Path.wildcard(Path.join(base_dir, pattern))
    |> Enum.each(&File.rm/1)
  end
end
