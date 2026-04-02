# Step-Through Auto Walker
#
# Walks the requirement graph on a project, auto-satisfying each requirement
# by copying files from the golden source. Verifies requirements flip to satisfied
# after each step.
#
# Usage:
#   mix run test/support/scripts/step_through_auto.exs /path/to/math_test_project [options]
#
# Options:
#   --strip       Strip project to skeleton before walking (full walkthrough)
#   --pause       Pause between steps (press Enter to continue)
#   --max N       Maximum steps before stopping (default: 50)
#   --orchestrate Exercise real Dispatch.command/evaluate flow (validates prompts + cleanup)
#
# Prerequisites:
#   - Database running (app started by mix run)
#   - Target project has .code_my_spec/config.yml
#   - Project is the "golden" complete source (all files present)

# -- Load step-through modules ------------------------------------------------

Code.compile_file("test/support/step_through/file_stager.ex")
Code.compile_file("test/support/step_through/project_prep.ex")

# Suppress noisy SQL and info logging during the walk
Logger.configure(level: :warning)

alias CodeMySpec.Components
alias CodeMySpec.ProjectCoordinator
alias CodeMySpec.ProjectCoordinator.Dispatch
alias CodeMySpec.Repo
alias CodeMySpec.Requirements.Requirement
alias CodeMySpec.Requirements.Sync, as: RequirementsSync
alias CodeMySpec.StepThrough.FileStager
alias CodeMySpec.StepThrough.ProjectPrep
alias CodeMySpec.Stories

# -- Parse args ----------------------------------------------------------------

{opts, args} =
  System.argv()
  |> OptionParser.parse!(
    strict: [strip: :boolean, pause: :boolean, max: :integer, orchestrate: :boolean],
    aliases: [s: :strip, p: :pause, m: :max, o: :orchestrate]
  )

golden_dir =
  case args do
    [] -> File.cwd!()
    [dir] -> Path.expand(dir)
    _ ->
      IO.puts("Usage: mix run test/support/scripts/step_through_auto.exs [project_dir] [options]")
      System.halt(1)
  end

max_steps = Keyword.get(opts, :max, 50)
pause? = Keyword.get(opts, :pause, false)
strip? = Keyword.get(opts, :strip, false)
orchestrate? = Keyword.get(opts, :orchestrate, false)

# -- Helpers -------------------------------------------------------------------

# ANSI color helpers
dim = fn text -> "\e[2m#{text}\e[0m" end
bold = fn text -> "\e[1m#{text}\e[0m" end
green = fn text -> "\e[32m#{text}\e[0m" end
red = fn text -> "\e[31m#{text}\e[0m" end
yellow = fn text -> "\e[33m#{text}\e[0m" end
cyan = fn text -> "\e[36m#{text}\e[0m" end

print_separator = fn title ->
  IO.puts("")
  IO.puts(bold.("─── #{title} " <> String.duplicate("─", max(0, 56 - String.length(title)))))
  IO.puts("")
end

# Resolve a human-readable entity label from a requirement
resolve_entity = fn req, scope ->
  cond do
    req.story_id ->
      story = Stories.get_story!(scope, req.story_id)
      "story \"#{story.title}\" (##{story.id})"

    req.component_id ->
      case Components.get_component(scope, req.component_id) do
        nil -> "component #{req.component_id} (deleted)"
        c -> "component #{c.module_name}"
      end

    req.project_id ->
      "project"

    true ->
      "unknown"
  end
end

print_requirement = fn req, scope ->
  entity = resolve_entity.(req, scope)

  IO.puts("  #{bold.("Target:")}  #{entity}")
  IO.puts("  #{bold.("Need:")}    #{req.name} #{dim.("(scope: #{req.scope})")}")
  IO.puts("  #{bold.("Via:")}     #{inspect(req.satisfied_by)}")
end

print_stories = fn scope ->
  stories =
    Stories.list_project_stories_by_priority(scope)
   

  IO.puts("  #{bold.("Stories")} (#{length(stories)}):")

  Enum.each(stories, fn story ->
    reqs = story.requirements || []
    satisfied = Enum.count(reqs, & &1.satisfied)
    total = length(reqs)

    component_label =
      if story.component_id do
        case Components.get_component(scope, story.component_id) do
          nil -> dim.("(deleted)")
          c -> c.module_name
        end
      else
        yellow.("(unlinked)")
      end

    # Progress bar: [■■■□□] style
    filled = String.duplicate("■", satisfied)
    empty = String.duplicate("□", total - satisfied)
    progress = "[#{filled}#{empty}]"

    progress_colored =
      cond do
        satisfied == total -> green.(progress)
        satisfied == 0 -> red.(progress)
        true -> yellow.(progress)
      end

    # Individual requirement status
    req_details =
      reqs
      |> Enum.sort_by(& &1.name)
      |> Enum.map(fn r ->
        if r.satisfied, do: green.("✓#{r.name}"), else: red.("✗#{r.name}")
      end)
      |> Enum.join(" ")

    IO.puts("    ##{story.id} #{story.title}")
    IO.puts("         → #{component_label}")
    IO.puts("         #{progress_colored} #{satisfied}/#{total}  #{req_details}")
  end)
end

print_action = fn action ->
  case action do
    {:copied, paths} ->
      IO.puts("  #{green.("COPIED")} #{length(paths)} file(s):")
      Enum.each(paths, &IO.puts("    #{green.("+")} #{&1}"))

    {:db_op, desc} ->
      IO.puts("  #{cyan.("DB OP")} #{desc}")

    {:no_op, desc} ->
      IO.puts("  #{dim.("NO-OP")} #{desc}")

    {:error, desc} ->
      IO.puts("  #{red.("ERROR")} #{desc}")
  end
end

pause = fn ->
  if pause? do
    IO.write(">>> Press Enter to continue...")
    IO.read(:stdio, :line)
  end
end

# -- Orchestrate helpers -------------------------------------------------------

# Display prompt text with indentation, truncated to max_lines
print_prompt = fn prompt_text ->
  lines = String.split(prompt_text, "\n")
  display_lines = Enum.take(lines, 40)
  truncated = length(lines) > 40

  IO.puts("  #{bold.("PROMPT")} (#{length(lines)} lines):")
  Enum.each(display_lines, fn line ->
    IO.puts("    #{dim.(line)}")
  end)

  if truncated do
    IO.puts("    #{dim.("... (#{length(lines) - 40} more lines)")}")
  end
end

# List prompt/problems files in a status directory
list_status_files = fn working_dir, status_dir ->
  abs_dir = Path.join(working_dir, status_dir)
  if File.dir?(abs_dir) do
    Path.wildcard(Path.join(abs_dir, "**/*.md"))
    |> Enum.map(&Path.relative_to(&1, working_dir))
  else
    []
  end
end

# Check if prompt files were cleaned up after evaluate
# Only checks files that were NEW in this step (not inherited from previous steps)
verify_cleanup = fn working_dir, status_dir, new_files_this_step, eval_valid? ->
  if new_files_this_step == [] do
    IO.puts("  #{dim.("CLEANUP: no prompt files written this step")}")
  else
    files_after = list_status_files.(working_dir, status_dir)
    cleaned = new_files_this_step -- files_after
    still_present = new_files_this_step -- cleaned

    if eval_valid? do
      if cleaned != [] do
        IO.puts("  #{green.("CLEANUP")} #{length(cleaned)} file(s) removed:")
        Enum.each(cleaned, &IO.puts("    #{green.("-")} #{&1}"))
      end

      if still_present != [] do
        IO.puts("  #{red.("CLEANUP MISSED")} #{length(still_present)} file(s) still present:")
        Enum.each(still_present, &IO.puts("    #{red.("!")} #{&1}"))
      end
    else
      IO.puts("  #{dim.("CLEANUP: eval was invalid, files retained (expected):")}")
      Enum.each(new_files_this_step, &IO.puts("    #{dim.("~")} #{&1}"))
    end
  end
end

# Derive status dir for a requirement (for cleanup verification)
status_dir_for_req = fn req, scope ->
  cond do
    req.component_id ->
      component = Components.get_component!(scope, req.component_id)
      ProjectCoordinator.component_status_dir(component)

    req.story_id ->
      story = Stories.get_story!(scope, req.story_id)
      if story.component_id do
        component = Components.get_component!(scope, story.component_id)
        ProjectCoordinator.component_status_dir(component)
      else
        nil
      end

    req.project_id ->
      # Project-scoped orchestrate tasks use a project-level tasks dir
      ".code_my_spec/tasks"

    true ->
      nil
  end
end

# Run one step using Dispatch.command → FileStager.satisfy → Dispatch.evaluate
orchestrate_step = fn req, scope, golden_dir, working_dir ->
  parent_session = %{project: scope.active_project}
  status_dir = status_dir_for_req.(req, scope)

  # 1. Snapshot prompt files before command
  files_before = if status_dir, do: list_status_files.(working_dir, status_dir), else: []

  # 2. Generate prompt via Dispatch.command
  IO.puts("  #{cyan.("▶ Dispatch.command")} (scope: #{req.scope})")

  command_result =
    try do
      # Temporarily allow info logging for dispatch
      Logger.configure(level: :info)
      result = Dispatch.command(req, scope, parent_session)
      Logger.configure(level: :warning)
      result
    rescue
      e ->
        Logger.configure(level: :warning)
        {:error, Exception.message(e)}
    catch
      kind, reason ->
        Logger.configure(level: :warning)
        {:error, "#{kind}: #{inspect(reason)}"}
    end

  case command_result do
    {:ok, prompt_text} ->
      IO.puts("")
      print_prompt.(prompt_text)

      # Show any prompt files that were written
      files_after_command = if status_dir, do: list_status_files.(working_dir, status_dir), else: []
      new_files = files_after_command -- files_before

      if new_files != [] do
        IO.puts("")
        IO.puts("  #{cyan.("PROMPT FILES")} written:")
        Enum.each(new_files, fn f ->
          IO.puts("    #{cyan.("+")} #{f}")
          # Show the actual file content
          abs_path = Path.join(working_dir, f)
          if File.exists?(abs_path) do
            content = File.read!(abs_path)
            content_lines = String.split(content, "\n")
            preview = Enum.take(content_lines, 10) |> Enum.join("\n")
            IO.puts("      #{dim.(preview)}")
            if length(content_lines) > 10 do
              IO.puts("      #{dim.("... (#{length(content_lines) - 10} more lines)")}")
            end
          end
        end)
      end

      IO.puts("")

      # 3. Copy golden files via FileStager
      IO.puts("  #{green.("▶ FileStager.satisfy")} (simulating subagent output)")
      {:ok, action} = FileStager.satisfy(req, scope, golden_dir)
      print_action.(action)
      IO.puts("")

      # 4. Evaluate via Dispatch.evaluate
      IO.puts("  #{cyan.("▶ Dispatch.evaluate")}")

      eval_result =
        try do
          Logger.configure(level: :info)
          result = Dispatch.evaluate(req, scope, parent_session)
          Logger.configure(level: :warning)
          result
        rescue
          e ->
            Logger.configure(level: :warning)
            {:error, Exception.message(e)}
        catch
          kind, reason ->
            Logger.configure(level: :warning)
            {:error, "#{kind}: #{inspect(reason)}"}
        end

      eval_valid? =
        case eval_result do
          {:ok, :valid} ->
            IO.puts("  #{green.("EVAL: ✓ valid")}")
            true

          {:ok, :invalid, feedback} ->
            feedback_preview = feedback |> String.split("\n") |> Enum.take(5) |> Enum.join("\n")
            IO.puts("  #{yellow.("EVAL: ✗ invalid")}")
            IO.puts("    #{dim.(feedback_preview)}")
            false

          {:error, reason} ->
            IO.puts("  #{red.("EVAL ERROR:")} #{inspect(reason)}")
            false
        end

      # 5. Verify cleanup (only for files created this step)
      IO.puts("")
      verify_cleanup.(working_dir, status_dir || ".code_my_spec/tasks", new_files, eval_valid?)

    {:error, reason} ->
      IO.puts("  #{yellow.("COMMAND SKIPPED:")} #{inspect(reason)}")
      IO.puts("  #{dim.("Falling back to direct FileStager.satisfy")}")
      IO.puts("")

      # Fallback: just copy files directly
      {:ok, action} = FileStager.satisfy(req, scope, golden_dir)
      print_action.(action)
  end
end

# -- Prepare project -----------------------------------------------------------

print_separator.("STEP-THROUGH AUTO WALKER")

IO.puts("  Golden source: #{golden_dir}")
IO.puts("  Max steps:     #{max_steps}")
IO.puts("  Strip:         #{strip?}")
IO.puts("  Pause:         #{pause?}")
IO.puts("  Orchestrate:   #{orchestrate?}")
IO.puts("")

{:ok, %{scope: scope, working_dir: working_dir}} =
  ProjectPrep.prepare(golden_dir, strip: strip?, link_stories: true)

IO.puts("")
print_stories.(scope)

pause.()

# -- Walk the graph (wrapped in CLI cassette for speed) ------------------------

# Record/replay System.cmd calls (mix test, mix credo, etc.) so subsequent
# runs replay instantly instead of running real commands.
cassette_name = "step_through_#{Path.basename(golden_dir)}"
ExCliVcr.start_cassette(cassette_name, record: :once, match_requests_on: [:command, :args])

walk = fn walk, step ->
  if step > max_steps do
    IO.puts("")
    IO.puts("  #{yellow.("⚠")} Reached max steps (#{max_steps}), stopping.")
    {:halt, :max_steps}
  else
    print_separator.("STEP #{step}")

    case ProjectCoordinator.get_next_actions(scope) do
      {:ok, %Requirement{} = req} ->
        print_requirement.(req, scope)
        IO.puts("")

        # Satisfy the requirement — either via orchestration or direct copy
        if orchestrate? do
          orchestrate_step.(req, scope, golden_dir, working_dir)
        else
          {:ok, action} = FileStager.satisfy(req, scope, golden_dir)
          print_action.(action)
        end

        # Re-sync requirements (orchestrate mode already did FileStager + evaluate internally)
        IO.puts("")
        IO.puts("  #{dim.("Syncing requirements...")}")
        sync_start = System.monotonic_time(:millisecond)

        # Full re-sync: components → stories → project
        all_components = Components.list_components(scope)
        RequirementsSync.sync_all_requirements(all_components, scope)
        stories = Stories.list_project_stories_by_priority(scope)
        RequirementsSync.sync_story_requirements(stories, scope)
        RequirementsSync.sync_project_requirements(scope)

        sync_ms = System.monotonic_time(:millisecond) - sync_start
        IO.puts("  #{dim.("Synced in #{sync_ms}ms")}")

        IO.puts("")
        print_stories.(scope)

        pause.()

        # Check for infinite loops: if we get the exact same requirement again,
        # something is wrong
        prev_name = req.name
        prev_comp = req.component_id
        prev_story = req.story_id

        case ProjectCoordinator.get_next_actions(scope) do
          {:ok, %Requirement{name: ^prev_name, component_id: ^prev_comp, story_id: ^prev_story}} ->
            IO.puts("")
            IO.puts("  #{red.("⚠ STUCK: Same requirement returned after satisfaction attempt!")}")
            IO.puts("    Requirement: #{req.name}")
            IO.puts("    Entity:      #{resolve_entity.(req, scope)}")

            # Diagnostics: show unsatisfied requirements in component tree
            if req.story_id do
              story = Stories.get_story!(scope, req.story_id)

              if story.component_id do
                component = Components.get_component(scope, story.component_id)

                if component do
                  all_comps = Components.list_components(scope)
                  descendants = CodeMySpec.Components.HierarchicalTree.get_all_descendants(component, all_comps)
                  tree = [component | descendants]

                  IO.puts("")
                  IO.puts("  #{bold.("Component tree diagnostics:")}")

                  Enum.each(tree, fn c ->
                    c = Repo.preload(c, :requirements)
                    unsatisfied = Enum.reject(c.requirements || [], & &1.satisfied)

                    if unsatisfied != [] do
                      IO.puts("    #{c.module_name} (#{c.type}):")

                      Enum.each(unsatisfied, fn r ->
                        details = if r.details, do: " — #{inspect(Map.get(r.details, "reason", ""))}", else: ""
                        IO.puts("      #{red.("✗")} #{r.name}#{details}")
                      end)
                    end
                  end)
                else
                  IO.puts("  Component #{story.component_id} not found (may have been removed during strip)")
                end
              end
            end

            IO.puts("")
            IO.puts("  Aborting to prevent infinite loop.")
            {:halt, :stuck}

          _ ->
            # Different requirement or complete — continue walking
            walk.(walk, step + 1)
        end

      :complete ->
        IO.puts("  #{green.("✓ COMPLETE — All requirements satisfied!")}")
        IO.puts("")
        print_stories.(scope)
        {:ok, :complete}

      {:error, reason} ->
        IO.puts("  #{red.("✗ ERROR:")} #{inspect(reason)}")
        IO.puts("")

        # Try a full re-sync and retry once
        IO.puts("  Attempting full re-sync...")
        components = Components.list_components(scope)
        RequirementsSync.sync_all_requirements(components, scope)
        stories = Stories.list_project_stories_by_priority(scope)
        RequirementsSync.sync_story_requirements(stories, scope)
        RequirementsSync.sync_project_requirements(scope)

        print_stories.(scope)
        pause.()

        walk.(walk, step + 1)
    end
  end
end

result = walk.(walk, 1)

# Stop the CLI cassette recorder (saves recordings for replay)
ExCliVcr.stop_cassette()

# -- Summary ------------------------------------------------------------------

print_separator.("DONE")

case result do
  {:ok, :complete} ->
    IO.puts("  #{green.("Result: SUCCESS — walked to completion")}")

  {:halt, :max_steps} ->
    IO.puts("  #{yellow.("Result: HALTED — reached max steps")}")

  {:halt, :stuck} ->
    IO.puts("  #{red.("Result: HALTED — got stuck on a requirement")}")

  other ->
    IO.puts("  Result: #{inspect(other)}")
end

IO.puts("")
IO.puts("  Working directory: #{working_dir}")
IO.puts("  (inspect or clean up as needed)")
IO.puts("")
