defmodule CodeMySpec.AgentTasks.QaStory do
  @moduledoc """
  QA-test a single user story end-to-end.

  `qa_complete` is satisfied by a DB-backed QA attempt
  (`CodeMySpec.Qa.qa_complete?/2`), landed with `submit_qa_result`
  (`CodeMySpec.Qa.submit_qa_result/2`). Files on disk never satisfy it;
  `evaluate/2` still validates the plan and brief, files issues from an
  optional `result.md`, and then demands a submit.

  See knowledge/tools, "Agent task prompts".
  """

  require Logger

  alias CodeMySpec.{Components, Environments, Files, Issues, Paths, Stories}
  alias CodeMySpec.Documents
  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.Utils
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.AppTransport

  @required_plan_sections ["app overview", "tools registry", "seed strategy"]

  # ============================================================================
  # dispatch — relevance signal for the requirement graph
  # ============================================================================

  def dispatch(_node) do
    %{
      role: :qa,
      prompt:
        "Run a per-story QA session: write a testing brief, execute it against " <>
          "the running app (MCP browser for UI, curl for API), and produce a " <>
          "pass/fail result with issues filed. Use when a story has passing BDD " <>
          "specs and is ready for `qa_complete`."
    }
  end

  # ============================================================================
  # Command — full prompt for the QA session
  # ============================================================================

  @doc """
  Build the full QA prompt for a story. Returns `{:ok, prompt_text}`.
  """
  def command(scope, task) do
    # The review is captured where the task is started (`StartAgentTask`,
    # `start_task`), which hold its owner; building the prompt records nothing.
    with {:ok, story_id} <- get_story_id(scope, task) do
      env = CodeMySpec.AgentTasks.environment(scope)
      story = Stories.get_story!(scope, story_id)
      ensure_qa_dirs(env, story.number)
      {:ok, build_prompt(scope, story)}
    end
  end

  # ============================================================================
  # Evaluate — a DB attempt decides; files only shape the feedback
  # ============================================================================

  @doc """
  Validate the QA cycle for a story.

  `{:ok, :valid}` once a passing DB attempt exists. A task owned by a
  sub-agent is left alone (`{:ok, :skip, why}`). With a failed or invalidated
  attempt, demands a fresh submit. Otherwise walks plan → brief → optional
  result (filing the result's issues) and demands a submit.
  """
  def evaluate(scope, task) do
    with {:ok, story_id} <- get_story_id(scope, task) do
      env = CodeMySpec.AgentTasks.environment(scope)
      Logger.info("[QaStory] evaluate: story_id=#{story_id}")

      # Most-recent first, `:invalidations` preloaded — see QaAttempts.list/2.
      attempts = CodeMySpec.Qa.list_qa_attempts(scope, story_id)

      cond do
        CodeMySpec.Qa.qa_complete?(scope, story_id) ->
          # A passing DB attempt: the file checks have nothing to add.
          Logger.info(
            "[QaStory] evaluate(#{story_id}): DB attempt satisfies qa_complete; skipping legacy file checks"
          )

          {:ok, :valid}

        subagent_owns?(task) ->
          # Owned by a sub-agent: the parent's stop must neither demand a
          # submit nor complete the sub-agent's live task, so `:skip`.
          {:ok, :skip, "owned by sub-agent #{task.agent_id}, which has not submitted yet"}

        attempts != [] ->
          # A failed or invalidated attempt: the obligation is to re-run and
          # submit, not to write documents, so the file chain is skipped.
          Logger.info(
            "[QaStory] evaluate(#{story_id}): prior attempt exists but does not satisfy; demanding a fresh submit"
          )

          {:ok, :invalid,
           resubmit_required_feedback(scope, story_id, story_number(scope, story_id), attempts)}

        true ->
          do_evaluate(scope, env, story_id, story_number(scope, story_id))
      end
    end
  end

  defp resubmit_required_feedback(scope, story_id, story_number, attempts) do
    """
    QA for story #{story_number} is not complete. #{describe_latest(scope, story_id, List.first(attempts))}

    QA completion is recorded in the database, not on disk — no file will
    satisfy this requirement. Re-run the QA scenarios against the real surface,
    then call `submit_qa_result` with the outcome.

    Use `list_qa_attempts` with story_number=#{story_number} to see the history,
    including why an attempt was invalidated.
    """
  end

  defp describe_latest(_scope, _story_id, nil), do: "No attempt has been recorded."

  defp describe_latest(_scope, _story_id, %{invalidations: [_ | _] = invalidations}) do
    reason =
      invalidations
      |> List.last()
      |> then(& &1.reason)

    "The most recent attempt was invalidated: #{reason}"
  end

  # b4fe8c48: a recorded, uninvalidated pass can still fail `qa_complete?` on
  # `review_current?/3` alone — the story was re-certified since the review
  # ran. The fallback clause below said only "recorded as pass", explaining
  # nothing; this names the gap `qa_complete?` actually found.
  defp describe_latest(scope, story_id, %{status: :pass} = attempt) do
    case CodeMySpec.Qa.story_review_currency_gap(scope, story_id, attempt) do
      nil -> "The most recent attempt is recorded as pass."
      gap -> "The most recent attempt passed, but no longer counts: #{gap}."
    end
  end

  defp describe_latest(_scope, _story_id, %{status: status}),
    do: "The most recent attempt is recorded as #{status}."

  defp subagent_owns?(%{agent_id: agent_id}) when is_binary(agent_id) and byte_size(agent_id) > 0,
    do: true

  defp subagent_owns?(_), do: false

  defp do_evaluate(scope, env, story_id, story_number) do
    with :ok <- check_plan(scope, env),
         :ok <- check_brief(env, story_number),
         :ok <- maybe_check_result(scope, env, story_id, story_number) do
      # Files validate but no DB attempt exists, and only the attempt
      # satisfies `qa_complete`: demand a submit rather than pass.
      {:ok, :invalid, submit_required_feedback(story_number)}
    else
      {:ok, :invalid, feedback} = result ->
        Logger.info("[QaStory] evaluate: invalid — #{String.slice(feedback, 0..120)}")
        result
    end
  end

  defp submit_required_feedback(story_number) do
    """
    Call `submit_qa_result` to land a DB attempt for story #{story_number} — the
    requirement graph reads completion from the qa_attempts table, not the
    filesystem. It is a code-mode tool, so it is called through `run_script`:

        run_script({ script = [[
          return submit_qa_result({
            task_id = "<task_id from start_task>",
            status = "pass",   -- or "fail" / "partial"
            scenarios = { { name = "...", status = "...", observation = "..." } },
            issue_ids = { ... }   -- ids returned from any create_issue calls
          })
        ]] })

    The scenarios payload is a structured list — one entry per scenario you
    exercised, each carrying its own name, status, and observation. Only
    `status: "pass"` satisfies the `qa_complete` requirement. Non-pass
    (`fail` / `partial`) submissions must carry at least one issue id in
    `issue_ids`; the tool rejects them otherwise.
    """
  end

  # `result.md` is optional evidence. When present, validate it and file its
  # issues; when absent, accept.
  defp maybe_check_result(scope, env, story_id, story_number) do
    if result_exists?(env, story_number) do
      case check_result(env, story_number) do
        {:ok, document} ->
          finalize_result(scope, story_id, story_number, document)
          :ok

        other ->
          other
      end
    else
      :ok
    end
  end

  defp result_exists?(env, story_number) do
    case Environments.read_file(env, result_path(story_number)) do
      {:ok, content} when is_binary(content) and byte_size(content) > 0 -> true
      _ -> false
    end
  end

  defp finalize_result(scope, story_id, story_number, document) do
    ensure_issues_filed(scope, story_id, story_number, document)
    Logger.info("[QaStory] evaluate(#{story_id}): artifacts valid, issues filed")
    {:ok, :valid}
  end

  defp ensure_issues_filed(scope, story_id, story_number, document) do
    {:ok, created} =
      Issues.create_from_qa_result(scope, story_id, document, result_path(story_number))

    issues_in_result = Map.get(document.sections, "issues", [])

    if issues_in_result == [] or issues_in_result == "None" do
      Logger.info("[QaStory] ensure_issues_filed(#{story_id}): no issues to file")
      :ok
    else
      Logger.info("[QaStory] ensure_issues_filed(#{story_id}): #{length(created)} issues filed")

      :ok
    end
  end

  # ============================================================================
  # Phase Checks
  # ============================================================================

  defp check_plan(scope, env) do
    case Environments.read_file(env, Paths.qa_plan()) do
      {:ok, content} when is_binary(content) and byte_size(content) > 0 ->
        validate_plan_sections(content)

      _ ->
        {:ok, :invalid, plan_missing_feedback(scope, env)}
    end
  end

  # Says which project and directory it looked in, so a working directory that
  # resolved to the wrong project is visible at a glance.
  defp plan_missing_feedback(scope, env) do
    where =
      case env do
        %{cwd: cwd} when is_binary(cwd) and cwd != "" -> cwd
        _ -> "an unknown directory"
      end

    case scope do
      %{active_project: %{name: name}} ->
        "QA plan not found at `#{Paths.qa_plan()}`, looking in #{where} for project " <>
          "\"#{name}\". If that is not the project you expected, the working directory " <>
          "resolved to the wrong one — check which project claims #{where}. " <>
          "Otherwise run the `qa_setup` task, which owns the project-wide plan."

      _ ->
        "No project claims #{where}, so there is nothing to look for a QA plan in. " <>
          "A project's `local_path` is what makes a working directory resolve; set it " <>
          "on the project this checkout belongs to."
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

  defp check_brief(env, story_number) do
    path = brief_path(story_number)

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

  defp check_result(env, story_number) do
    path = result_path(story_number)
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
        screenshot_dir = screenshot_dir(story_number)

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
    env = CodeMySpec.AgentTasks.environment(scope)
    endpoint_module = endpoint_module_name(scope)
    criteria_text = format_criteria(Map.get(story, :criteria, []))
    spec_paths = collect_spec_file_paths(scope, story.id)
    specs_text = format_spec_paths(spec_paths)
    existing_scripts = list_scripts(env)
    scripts_section = build_scripts_section(existing_scripts)
    component_section = build_component_section(scope, story)
    brief_spec = DocumentSpecProjector.project_spec("qa_story_brief")

    sections =
      [
        header_section(scope, story, endpoint_module, criteria_text, specs_text),
        changed_since_section(scope, story),
        component_section,
        scripts_section,
        plan_section(),
        single_use_repro_section(),
        interrupted_session_section(),
        playbook_section(),
        document_specs_section(brief_spec, story.number),
        done_signal_section()
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp header_section(scope, story, endpoint_module, criteria_text, specs_text) do
    """
    # QA Story #{story.number}: #{story.title}

    Run a full QA session for this story. Two phases: write a testing brief,
    then execute it. The playbook below has the detailed procedure.

    #{app_url_line(scope, endpoint_module)}

    ## Story description

    #{story.description || "_No description._"}

    ## Acceptance criteria

    #{criteria_text}

    ## BDD spec files

    #{specs_text}\
    """
  end

  # A re-offered story, told what moved since the last pass, so QA does not
  # conclude "nothing changed". The server holds the issue history but not the
  # copy's commit history, so issues are listed and commits are a command to run.
  defp changed_since_section(scope, story) do
    case CodeMySpec.Qa.list_qa_attempts(scope, story.id) do
      [] -> nil
      [last | _] -> changed_since(scope, story, last)
    end
  end

  defp changed_since(scope, story, attempt) do
    since = attempt.submitted_at || attempt.inserted_at

    """
    ## What changed since your last attempt

    Your last attempt (#{attempt.status}) was submitted #{DateTime.to_iso8601(since)}.

    Fixes submitted since then:

    #{format_submitted(submitted_since(scope, story, since))}

    Commits on this copy since then: run
    `git log --oneline --since=#{DateTime.to_iso8601(since)}` in the working copy.
    Re-test against what these changed — "nothing changed" is not a finding
    until both lists are empty.\
    """
  end

  defp submitted_since(scope, story, since) do
    Issues.list_story_submissions(scope, story.id)
    |> Enum.filter(fn issue ->
      not is_nil(issue.story_submission_ref) and not is_nil(issue.story_submitted_at) and
        DateTime.compare(issue.story_submitted_at, since) == :gt
    end)
  end

  defp format_submitted([]), do: "_None._"

  defp format_submitted(issues) do
    Enum.map_join(issues, "\n", fn issue ->
      "- `#{issue.id}` [#{issue.severity}] #{issue.title} — submitted at " <>
        "#{issue.story_submission_revision}: #{issue.story_submission_evidence}"
    end)
  end

  # QA tests the working copy the story's fix landed on, never main's app under
  # the story's name. `main_app_url_line/1` is only for a scope with no copy, or
  # a copy id that does not resolve.
  #
  # The harness replies `starting` after a short inline window and keeps
  # building in the background, so this waits just above that window.
  @app_start_timeout to_timeout(second: 35)

  defp app_url_line(%{active_working_copy_id: id}, endpoint_module)
       when is_binary(id) do
    case WorkingCopies.fetch(id) do
      {:ok, copy} -> own_copy_app_url_line(copy)
      {:error, _} -> main_app_url_line(endpoint_module)
    end
  end

  defp app_url_line(_scope, endpoint_module), do: main_app_url_line(endpoint_module)

  # Never tell the agent to boot a node to ask for the URL: a fresh `mix run`
  # blocks on the compile lock a running app holds and hangs.
  defp main_app_url_line(endpoint_module) do
    "**App URL:** `http://127.0.0.1:4000` (hosted), " <>
      "`http://127.0.0.1:4004` (this checkout's local app). " <>
      "Both are documented in `.code_my_spec/qa/plan.md`. " <>
      "Do not boot a node to ask `#{endpoint_module}.url()` — a fresh `mix run` " <>
      "blocks on the compile lock a running release holds and hangs."
  end

  defp own_copy_app_url_line(copy) do
    case AppTransport.ensure_app_running(copy.id, @app_start_timeout) do
      {:ok, %{status: "serving", url: url, commit: commit}} ->
        "**App URL:** #{url} — this working copy's own instance" <>
          commit_suffix(commit) <> ", not main's. Test against this address."

      {:ok, %{status: "starting", commit: commit}} ->
        "**App URL:** this copy's app is still building" <>
          commit_suffix(commit) <>
          " — a first start can take several minutes (installing dependencies, " <>
          "compiling). Call ensure_app_running again in a minute or two. Don't " <>
          "test against it yet; there is nothing serving there."

      {:ok, %{status: status, commit: commit}} ->
        "**App URL:** this copy's own app is currently `#{status}`" <>
          commit_suffix(commit) <>
          ". Do not fall back to main's app instead — say so and investigate; " <>
          "testing main would test different code than this story's fix."

      {:error, reason} ->
        "**App URL:** this copy's own app could not be started (#{inspect(reason)}). " <>
          "Do not fall back to main's app — that would test different code than " <>
          "this story's fix. Say so and investigate instead."
    end
  end

  defp commit_suffix(nil), do: ""
  defp commit_suffix(commit), do: " (serving #{String.slice(commit, 0, 8)})"

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

  # Some repros are consumed by being run: a system that correctly declines a
  # settled question looks like one that failed to escalate it. In the prompt
  # rather than the playbook because it governs choosing the test, while the
  # brief is written.
  defp single_use_repro_section do
    """
    ## Repros that consume themselves

    Before reusing a concrete input from an earlier attempt's brief, ask whether
    running it *changed* what a second run would measure. Anything the system
    remembers — a question it has answered, a decision it recorded, a name it has
    already taken — is spent once it has been used.

    The failure this prevents is the expensive kind: a system that correctly
    declines to re-answer a settled question looks exactly like one that failed
    to escalate it, and a re-test then reports a working fix as broken.

    Where an input is consumable, choose a fresh one and say in the brief which
    you used, so the next pass knows what is spent. Where you inherit a repro
    from a previous attempt, check it is still unused before trusting the
    result.\
    """
  end

  defp interrupted_session_section do
    """
    ## If your tools stop answering, say so before you stop

    The dev server and the harness both restart under you without warning. The
    box is shared, several sessions ship fixes to it, and a plain deploy takes
    the harness serving every checkout on the machine with it. You will see
    `:econnrefused`, `:harness_not_connected`, or "No session_id and no agent id
    on this call".

    None of that is your story failing. Retry — the session's enrichment comes
    back within a call or two once the harness rejoins — and carry on.

    What matters is the case where you cannot carry on. Submit what you have
    with the interruption named as the reason, rather than going quiet. Nobody
    can tell a subagent that died from one that is mid-browser-check: both
    produce no brief, no attempt and no notification. A pass that ended at
    05:22 was reported as "still running" for three hours on exactly that
    evidence (733ac788).

    An interruption is also a finding about the QA loop, so file it.\
    """
  end

  defp playbook_section do
    """
    ## Read the playbook

    Read these via the `read_knowledge` MCP tool:

    - `qa_story/workflow.md` — two-phase procedure (brief, test), tool
      rules (`:browser` vs `:api` pipelines), testing approach, and what
      the evaluator does when you stop.
    - `qa-tooling.md` — testing tool patterns and selection.
    - Tool-specific cheat sheets under `qa-tooling/` (browse with
      `list_knowledge`, then read individual entries).\
    """
  end

  defp document_specs_section(brief_spec, story_number) do
    """
    ## Brief format spec

    Write the brief to `#{brief_path(story_number)}` matching this spec exactly.
    The evaluator validates the brief structure on stop.

    #{brief_spec}\
    """
  end

  defp done_signal_section do
    """
    ## Findings and done signal

    Every finding you uncover during execution gets filed with `create_issue`
    **as you find it** — not written into a markdown file. Capture the title,
    severity, scope, and a short description; the call returns an issue id.
    Hold those ids.

    Both tools are code mode, so both go through `run_script`:

        run_script({ script = 'return create_issue({ title = "...", severity = "high", scope = "app", description = "..." })' })

    When you finish the session, close the pass the same way, with the
    structured scenarios payload **and** every issue id you filed:

        run_script({ script = [[
          return submit_qa_result({
            task_id = "<task_id>",
            status = "pass",   -- or "partial" / "fail"
            scenarios = { { name = "...", status = "pass", observation = "..." } },
            issue_ids = { "<every id returned from create_issue>" }
          })
        ]] })

    Discipline:

    - **`status: "pass"`** with `issue_ids: []` is fine.
    - **`status: "partial"` or `"fail"`** with `issue_ids: []` is **rejected
      by the tool**. A failure with no filed issue is a finding that just
      disappeared when your session ended — there's nowhere else for it to
      live. File the issues first, then submit.
    - **`mcp__plugin_codemyspec_local__submit_qa_result` does NOT resolve, and
      neither does `create_issue` spelled that way.** Both are code mode tools,
      reached by their bare names inside `run_script` and deliberately not
      advertised as MCP tools. Searching your tool list for them finds nothing,
      which looks exactly like a missing binding and is not one.
      `tool_docs({ names = {"submit_qa_result", "create_issue"} })` gives the
      arguments.
    - Attribution follows automatically: every `scope: app` issue you file
      from this task carries this story unless you pass a `story_number`.
      `qa`, `docs` and `framework` findings are about the tooling, so they
      stay off the story unless you name one. Until each story issue is triaged and every accepted one at the
      project's threshold is submitted and readiness is recertified, this story is not re-offered for QA —
      a `partial` or `fail` result resumes by itself once they are. If an
      issue belongs to a *different* story, pass that `story_number` on the
      `create_issue` call — an explicit attribution is never overwritten.
    - Don't write findings into a result.md file. The harness doesn't read it.
      Screenshots and other evidence still belong on disk, but the canonical
      record is the DB attempt + linked issues.\
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
    with component_id when not is_nil(component_id) <- story.component_id,
         %{} = component <- Components.get_component(scope, component_id) do
      files = Utils.component_files(component, scope.active_project)
      file_list = format_component_files(files)

      """
      ## Linked component: #{component.name}

      This story is implemented by `#{component.module_name}` (#{component.type}).
      Reading the source code and spec will help you understand what to
      test and how the feature works.

      #{file_list}\
      """
    else
      _ -> nil
    end
  end

  defp format_component_files(files) do
    files
    |> Enum.map(fn
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

  # From the synced file records, not a disk, so it works with or without a
  # working copy.
  defp collect_spec_file_paths(scope, story_id) do
    scope
    |> Files.list_files()
    |> Enum.filter(&(&1.role == :bdd_spec and &1.story_id == story_id))
    |> Enum.map(& &1.path)
    |> Enum.sort()
  end

  # ============================================================================
  # Path Helpers
  # ============================================================================

  defp story_number(scope, story_id) do
    case Stories.get_story(scope, story_id) do
      nil -> nil
      story -> story.number
    end
  end

  # Evidence lives under the story number, the name agents and people use.
  defp brief_path(story_number) do
    Path.join([Paths.qa_dir(), to_string(story_number), "brief.md"])
  end

  defp result_path(story_number) do
    Path.join([Paths.qa_dir(), to_string(story_number), "result.md"])
  end

  defp screenshot_dir(story_number) do
    Path.join([Paths.qa_dir(), to_string(story_number), "screenshots"])
  end

  defp ensure_qa_dirs(env, story_number) do
    Environments.ensure_dir(env, screenshot_dir(story_number))
    :ok
  end

  # ============================================================================
  # Session Helpers
  # ============================================================================

  # Both routes (`start_task`, and `StartAgentTask`'s topic route) create the
  # task with `story_id`. A task naming the story number in `requirement_name`,
  # the topic convention other topic tasks use, is also accepted.
  defp get_story_id(_scope, %{story_id: story_id}) when not is_nil(story_id),
    do: parse_integer(story_id)

  defp get_story_id(scope, %{requirement_name: requirement}) when is_binary(requirement) do
    with {:ok, number} <- parse_integer(requirement) do
      case Stories.get_story_by_number(scope, number) do
        nil -> {:error, "QaStory: no story numbered #{number} in this project"}
        story -> {:ok, story.id}
      end
    end
  end

  defp get_story_id(_scope, _task) do
    {:error, "QaStory requires a story number argument. Usage: /qa-story <story_number>"}
  end

  # `Integer.parse/1` alone accepts "892abc"; the remainder must be empty.
  defp parse_integer(value) do
    case Integer.parse(to_string(value)) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "QaStory requires a numeric story number, got: #{inspect(value)}"}
    end
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
