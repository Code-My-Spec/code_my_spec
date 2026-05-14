defmodule CodeMySpec.AgentTasks.QaStory do
  @moduledoc """
  QA-test a single user story end-to-end.

  See spec: `.code_my_spec/spec/code_my_spec/agent_tasks/qa_story.spec.md`.
  """

  require Logger

  alias CodeMySpec.{BddSpecs, Components, Environments, Issues, Paths, Stories}
  alias CodeMySpec.Documents
  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.Utils

  @required_plan_sections ["app overview", "tools registry", "seed strategy"]

  # ============================================================================
  # orchestrate — relevance signal for the requirement graph
  # ============================================================================

  def orchestrate(_node) do
    "Run a per-story QA session: write a testing brief, execute it against " <>
      "the running app (MCP browser for UI, curl for API), and produce a " <>
      "pass/fail result with issues filed. Use when a story has passing BDD " <>
      "specs and is ready for QA. Sub-agent: spawn @qa to call `start_task`."
  end

  # ============================================================================
  # Command — full prompt for the QA session
  # ============================================================================

  @doc """
  Build the full QA prompt for a story. Returns `{:ok, prompt_text}`.
  """
  def command(scope, task) do
    with {:ok, story_id} <- get_story_id(task) do
      env = scope.environment
      story = Stories.get_story!(scope, story_id)
      ensure_qa_dirs(env, story_id)
      {:ok, build_prompt(scope, story)}
    end
  end

  # ============================================================================
  # Evaluate — phase chain + renames on pass/fail
  # ============================================================================

  @doc """
  Validate the QA cycle for a story.

  Walks plan → brief → result. Files issues from the result to the DB and
  renames `result.md` to `result_complete.md` (on pass) or
  `result_failed_<ts>.md` (on fail). Returns `:valid` once the result is
  structurally valid — pass/fail is encoded in the file rename, not the
  evaluate return value (the requirement graph checks for
  `result_complete.md` separately).
  """
  def evaluate(scope, task) do
    with {:ok, story_id} <- get_story_id(task) do
      env = scope.environment
      Logger.info("[QaStory] evaluate: story_id=#{story_id}")

      if Environments.file_exists?(env, result_complete_path(story_id)) do
        Logger.info("[QaStory] evaluate: result_complete.md exists, already passed")
        {:ok, :valid}
      else
        do_evaluate(scope, env, story_id)
      end
    end
  end

  defp do_evaluate(scope, env, story_id) do
    with :ok <- check_plan(env),
         :ok <- check_brief(env, story_id),
         {:ok, document} <- check_result(env, story_id) do
      finalize_result(scope, env, story_id, document)
    else
      {:ok, :invalid, feedback} = result ->
        Logger.info("[QaStory] evaluate: invalid — #{String.slice(feedback, 0..120)}")
        result
    end
  end

  defp finalize_result(scope, env, story_id, document) do
    ensure_issues_filed(scope, story_id, document)

    if qa_passed?(document) do
      Logger.info("[QaStory] evaluate(#{story_id}): QA passed — promoting to result_complete.md")
      move_file(env, result_path(story_id), result_complete_path(story_id))
    else
      timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d_%H%M%S")
      failed_path = result_failed_path(story_id, timestamp)
      Logger.info("[QaStory] evaluate(#{story_id}): QA failed — archiving to #{failed_path}, issues filed for triage")
      move_file(env, result_path(story_id), failed_path)
    end

    # Always return :valid — session is done. The requirement graph checks
    # for result_complete.md, so the story stays open until QA actually passes.
    {:ok, :valid}
  end

  defp qa_passed?(document) do
    status =
      document.sections
      |> Map.get("status", "")
      |> to_string()
      |> String.downcase()
      |> String.trim()

    status in ["pass", "passed"]
  end

  defp move_file(env, from, to) do
    case Environments.read_file(env, from) do
      {:ok, content} ->
        Environments.write_file(env, to, content)
        Environments.delete_file(env, from)

      {:error, _} ->
        :ok
    end
  end

  defp ensure_issues_filed(scope, story_id, document) do
    {:ok, created} = Issues.create_from_qa_result(scope, story_id, document)
    issues_in_result = Map.get(document.sections, "issues", [])

    if issues_in_result == [] or issues_in_result == "None" do
      Logger.info("[QaStory] ensure_issues_filed(#{story_id}): no issues to file")
      :ok
    else
      Logger.info(
        "[QaStory] ensure_issues_filed(#{story_id}): #{length(created)} issues filed"
      )

      :ok
    end
  end

  # ============================================================================
  # Phase Checks
  # ============================================================================

  defp check_plan(env) do
    case Environments.read_file(env, Paths.qa_plan()) do
      {:ok, content} when is_binary(content) and byte_size(content) > 0 ->
        validate_plan_sections(content)

      _ ->
        {:ok, :invalid,
         "QA plan not found at `#{Paths.qa_plan()}`. " <>
           "Run the `qa_setup` task first — that task owns the project-wide plan."}
    end
  end

  defp validate_plan_sections(content) do
    content_lower = String.downcase(content)

    missing =
      Enum.reject(@required_plan_sections, fn section ->
        String.contains?(content_lower, "## #{section}")
      end)

    case missing do
      [] ->
        :ok

      sections ->
        section_list = Enum.map_join(sections, ", ", &"`## #{title_case(&1)}`")

        {:ok, :invalid,
         "QA plan at `#{Paths.qa_plan()}` is missing required section(s): #{section_list}. " <>
           "Re-run `qa_setup` to complete the plan, then re-run this task."}
    end
  end

  defp check_brief(env, story_id) do
    path = brief_path(story_id)

    case Environments.read_file(env, path) do
      {:ok, content} when is_binary(content) and byte_size(content) > 0 ->
        case Documents.create_dynamic_document(content, "qa_story_brief") do
          {:ok, _document} ->
            :ok

          {:error, reason} ->
            {:ok, :invalid,
             "Brief at `#{path}` is invalid: #{reason}. Fix the brief and stop the session again."}
        end

      _ ->
        {:ok, :invalid,
         "Brief not found at `#{path}`. Write the brief following the format specification, then stop the session."}
    end
  end

  defp check_result(env, story_id) do
    path = result_path(story_id)
    result_spec = DocumentSpecProjector.project_spec("qa_result")

    case Environments.read_file(env, path) do
      {:ok, content} when is_binary(content) and byte_size(content) > 0 ->
        case Documents.create_dynamic_document(content, "qa_result") do
          {:ok, document} ->
            {:ok, document}

          {:error, reason} ->
            {:ok, :invalid,
             "Brief validated. Result at `#{path}` is invalid: #{reason}. " <>
               "Fix the result to match this specification and stop the session.\n\n" <>
               result_spec}
        end

      _ ->
        screenshot_dir = screenshot_dir(story_id)

        {:ok, :invalid,
         "Brief validated. Now execute the test plan from the brief and write the result to `#{path}`. " <>
           "Save screenshots to `#{screenshot_dir}/`. " <>
           "Stop the session when done."}
    end
  end

  # ============================================================================
  # Combined Prompt — slim, points at knowledge docs
  # ============================================================================

  defp build_prompt(scope, story) do
    env = scope.environment
    story_id = story.id
    endpoint_module = endpoint_module_name(scope)
    criteria_text = format_criteria(Map.get(story, :criteria, []))
    spec_paths = collect_spec_file_paths(env, story_id)
    specs_text = format_spec_paths(spec_paths)
    existing_scripts = list_scripts(env)
    scripts_section = build_scripts_section(existing_scripts)
    component_section = build_component_section(scope, story)
    brief_spec = DocumentSpecProjector.project_spec("qa_story_brief")
    result_spec = DocumentSpecProjector.project_spec("qa_result")

    sections =
      [
        header_section(story_id, story, endpoint_module, criteria_text, specs_text),
        component_section,
        scripts_section,
        plan_section(),
        playbook_section(),
        document_specs_section(brief_spec, result_spec, story_id),
        done_signal_section(story_id)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp header_section(story_id, story, endpoint_module, criteria_text, specs_text) do
    """
    # QA Story #{story_id}: #{story.title}

    Run a full QA session for this story. Two phases: write a testing brief,
    then execute it. The playbook below has the detailed procedure.

    **App URL:** Run `mix run -e 'IO.puts(#{endpoint_module}.url())'`.

    ## Story description

    #{story.description || "_No description._"}

    ## Acceptance criteria

    #{criteria_text}

    ## BDD spec files

    #{specs_text}\
    """
  end

  defp plan_section do
    """
    ## Required reading: QA plan

    Read `#{Paths.qa_plan()}` first. It contains the App Overview, Tools
    Registry, auth strategy, and Seed Strategy you need before writing the
    brief. The plan is produced and maintained by the `qa_setup` task; if
    it's missing or incomplete, the evaluator will tell you to run that
    task first.\
    """
  end

  defp playbook_section do
    """
    ## Read the playbook

    - `priv/knowledge/qa_story/workflow.md` — two-phase procedure (brief,
      test), tool rules (`:browser` vs `:api` pipelines), testing approach,
      and what the evaluator does when you stop.
    - `priv/knowledge/qa-tooling.md` — testing tool patterns and selection.
    - `priv/knowledge/qa-tooling/` — tool-specific cheat sheets.\
    """
  end

  defp document_specs_section(brief_spec, result_spec, story_id) do
    """
    ## Document format specs

    Match these exactly — the evaluator validates against them.

    ### Phase 1: qa_story_brief (write to `#{brief_path(story_id)}`)

    #{brief_spec}

    ### Phase 2: qa_result (write to `#{result_path(story_id)}`)

    #{result_spec}\
    """
  end

  defp done_signal_section(story_id) do
    """
    ## Done signal

    Write the result to `#{result_path(story_id)}` and stop the session.
    The evaluator validates the result, files issues to the DB, and renames
    the result file based on `status` (pass → `result_complete.md`,
    fail/partial → `result_failed_<timestamp>.md`). Story QA is complete
    when `result_complete.md` exists.\
    """
  end

  # ============================================================================
  # Shared prompt helpers
  # ============================================================================

  defp build_scripts_section([]), do: nil

  defp build_scripts_section(scripts) do
    script_list = Enum.map_join(scripts, "\n", &"- `#{&1}`")

    """
    ## Available scripts

    Reference these by path in the brief instead of inlining commands:

    #{script_list}\
    """
  end

  defp build_component_section(scope, story) do
    case story.component_id do
      nil ->
        nil

      component_id ->
        try do
          component = Components.get_component!(scope, component_id)
          files = Utils.component_files(component, scope.active_project)
          file_list = format_component_files(files)

          """
          ## Linked component: #{component.name}

          This story is implemented by `#{component.module_name}` (#{component.type}).
          Reading the source code and spec will help you understand what to
          test and how the feature works.

          #{file_list}\
          """
        rescue
          _ -> nil
        end
    end
  end

  defp format_component_files(files) do
    files
    |> Enum.map(fn
      {:spec_file, path} -> "- Spec: `#{path}`"
      {:code_file, path} -> "- Source: `#{path}`"
      {:test_file, path} -> "- Tests: `#{path}`"
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # ============================================================================
  # Data Loading
  # ============================================================================

  defp endpoint_module_name(scope) do
    case scope.active_project do
      %{module_name: name} when is_binary(name) and name != "" ->
        "#{name}Web.Endpoint"

      _ ->
        "MyAppWeb.Endpoint"
    end
  end

  @scripts_dir Path.join(Paths.qa_dir(), "scripts")

  defp list_scripts(env) do
    case Environments.glob(env, Path.join(@scripts_dir, "*")) do
      files when is_list(files) and files != [] -> files
      _ -> []
    end
  end

  defp collect_spec_file_paths(env, story_id) do
    specs = BddSpecs.list_specs_for_story(env, story_id)
    Enum.map(specs, & &1.file_path)
  end

  # ============================================================================
  # Path Helpers
  # ============================================================================

  defp brief_path(story_id) do
    Path.join([Paths.qa_dir(), to_string(story_id), "brief.md"])
  end

  defp result_path(story_id) do
    Path.join([Paths.qa_dir(), to_string(story_id), "result.md"])
  end

  defp result_complete_path(story_id) do
    Path.join([Paths.qa_dir(), to_string(story_id), "result_complete.md"])
  end

  defp result_failed_path(story_id, timestamp) do
    Path.join([Paths.qa_dir(), to_string(story_id), "result_failed_#{timestamp}.md"])
  end

  defp screenshot_dir(story_id) do
    Path.join([Paths.qa_dir(), to_string(story_id), "screenshots"])
  end

  defp ensure_qa_dirs(env, story_id) do
    Environments.ensure_dir(env, screenshot_dir(story_id))
    :ok
  end

  # ============================================================================
  # Session Helpers
  # ============================================================================

  defp get_story_id(%{story_id: story_id}) when not is_nil(story_id) do
    case Integer.parse(to_string(story_id)) do
      {id, _} -> {:ok, id}
      :error -> {:error, "QaStory requires a numeric story ID, got: #{inspect(story_id)}"}
    end
  end

  defp get_story_id(_task) do
    {:error, "QaStory requires a story ID argument. Usage: /qa-story <story_id>"}
  end

  # ============================================================================
  # Formatting Helpers
  # ============================================================================

  defp format_criteria(nil), do: "_None defined._"
  defp format_criteria([]), do: "_None defined._"

  defp format_criteria(criteria) do
    Enum.map_join(criteria, "\n", fn c -> "- #{c.description}" end)
  end

  defp format_spec_paths([]),
    do: "_No BDD specs found. Read the router and app code to understand this story's scope._"

  defp format_spec_paths(paths) do
    Enum.map_join(paths, "\n", &"- `#{&1}`")
  end

  defp title_case(string) do
    string
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
