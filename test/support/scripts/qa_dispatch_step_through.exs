# QA Story Step-Through via Dispatch (:orchestrate scope)
#
# Tests the QA story lifecycle as StartImplementation would invoke it,
# by calling Dispatch.command/evaluate directly with a constructed Requirement.
#
# Usage:
#   mix run test/support/scripts/qa_dispatch_step_through.exs <story_id> [project_dir]
#
# Prerequisites:
#   - Database running (app started by mix run)
#   - Story exists in DB
#   - Target project has .code_my_spec/config.yml

alias CodeMySpec.AgentTasks.QaStory
alias CodeMySpec.Environments
alias CodeMySpec.ProjectCoordinator.Dispatch
alias CodeMySpec.Requirements.Requirement
alias CodeMySpec.Users.Scope

# -- Args ----------------------------------------------------------------------

{story_id_str, project_dir} =
  case System.argv() do
    [sid] -> {sid, File.cwd!()}
    [sid, dir] -> {sid, dir}
    _ ->
      IO.puts("Usage: mix run test/support/scripts/qa_dispatch_step_through.exs <story_id> [project_dir]")
      System.halt(1)
  end

story_id =
  case Integer.parse(story_id_str) do
    {id, _} -> id
    :error ->
      IO.puts("ERROR: story_id must be an integer, got: #{story_id_str}")
      System.halt(1)
  end

# -- Build scope ---------------------------------------------------------------

{:ok, scope} = Scope.from_local_config(project_dir)
env = scope.environment
qa_dir = Path.join(env.cwd, ".code_my_spec/qa")
status_dir = Path.join(env.cwd, ".code_my_spec/status/qa")

IO.puts("============================================================")
IO.puts("  QA Dispatch Step-Through (:orchestrate scope)")
IO.puts("============================================================")
IO.puts("")
IO.puts("  Story ID:    #{story_id}")
IO.puts("  Project:     #{scope.active_project.name}")
IO.puts("  Project Dir: #{env.cwd}")
IO.puts("")

# -- Build Requirement ---------------------------------------------------------
#
# This mirrors what the requirement graph would produce for qa_complete.
# See RequirementDefinitionData.qa_complete/0.

req = %Requirement{
  name: "qa_complete",
  artifact_type: :review,
  description: "QA brief and result artifacts valid",
  checker_module: CodeMySpec.Requirements.StoryQaChecker,
  satisfied_by: QaStory,
  scope: :orchestrate,
  satisfied: false,
  story_id: story_id,
  project_id: scope.active_project.id
}

IO.puts("  Requirement: #{req.name} (scope: #{req.scope})")
IO.puts("  Task Module: #{inspect(req.satisfied_by)}")
IO.puts("  Status Dir:  .code_my_spec/status/qa/")
IO.puts("")

# -- Helpers -------------------------------------------------------------------

pause = fn ->
  IO.puts("")
  IO.write(">>> Press Enter to continue...")
  IO.read(:stdio, :line)
  IO.puts("")
end

print_result = fn label, result ->
  case result do
    {:ok, prompt} when is_binary(prompt) ->
      IO.puts("#{label}: OK (#{String.length(prompt)} chars)")
      IO.puts("--- first 600 chars ---")
      IO.puts(String.slice(prompt, 0..599))
      IO.puts("---")

    {:ok, :valid} ->
      IO.puts("#{label}: VALID")

    {:ok, :invalid, feedback} ->
      IO.puts("#{label}: INVALID")
      IO.puts("--- feedback ---")
      IO.puts(String.slice(feedback, 0..800))
      IO.puts("---")

    {:error, reason} ->
      IO.puts("#{label}: ERROR")
      IO.puts("  #{inspect(reason)}")
  end
end

write_file! = fn relative_path, content ->
  full_path = Path.join(env.cwd, relative_path)
  full_path |> Path.dirname() |> File.mkdir_p!()
  File.write!(full_path, content)
  IO.puts("Wrote #{relative_path}")
end

show_status_files = fn ->
  prompt_file = Path.join(status_dir, "story_#{story_id}_qa_story.md")
  problem_file = Path.join(status_dir, "story_#{story_id}_qa_story_problems.md")

  IO.puts("")
  IO.puts("--- status files ---")

  if File.exists?(prompt_file) do
    content = File.read!(prompt_file)
    IO.puts("PROMPT (#{String.length(content)} chars): #{Path.relative_to_cwd(prompt_file)}")
    IO.puts("  First line: #{content |> String.split("\n") |> hd()}")
  else
    IO.puts("PROMPT: (not written yet)")
  end

  if File.exists?(problem_file) do
    content = File.read!(problem_file)
    IO.puts("PROBLEMS (#{String.length(content)} chars): #{Path.relative_to_cwd(problem_file)}")
    IO.puts("  #{String.slice(content, 0..200)}")
  else
    IO.puts("PROBLEMS: (none)")
  end

  IO.puts("---")
end

# == Step 1: Dispatch.command (:orchestrate) ===================================

IO.puts("============================================================")
IO.puts("  STEP 1: Dispatch.command (orchestrate)")
IO.puts("  This is what StartImplementation.command does after graph walk")
IO.puts("============================================================")
IO.puts("")

result = Dispatch.command(req, scope, %{})
print_result.("command", result)
show_status_files.()
pause.()

# == Step 2: Dispatch.evaluate -- no plan ======================================

IO.puts("============================================================")
IO.puts("  STEP 2: Dispatch.evaluate (no plan yet)")
IO.puts("  Expected: INVALID with 'QA plan not found' -> PROBLEMS file")
IO.puts("============================================================")
IO.puts("")

result = Dispatch.evaluate(req, scope, %{})
print_result.("evaluate", result)
show_status_files.()
pause.()

# == Step 3: Write plan, evaluate ==============================================

IO.puts("============================================================")
IO.puts("  STEP 3: Write plan.md, then Dispatch.evaluate")
IO.puts("  Expected: ADVANCE to brief phase")
IO.puts("  The PROMPT file should update with brief-phase instructions.")
IO.puts("  The PROBLEMS file should be cleaned up (no problems).")
IO.puts("============================================================")
IO.puts("")

write_file!.(".code_my_spec/qa/plan.md", """
# QA Plan

## App Overview

Phoenix app with session-based auth on port 4000.

## Tools Registry

### web tool
Use for LiveView pages.

## Seed Strategy

- `mix run priv/repo/qa_seeds.exs`
""")

result = Dispatch.evaluate(req, scope, %{})
print_result.("evaluate", result)
show_status_files.()
pause.()

# == Step 4: Write INVALID brief, evaluate =====================================

IO.puts("============================================================")
IO.puts("  STEP 4: Write invalid brief.md (missing sections), evaluate")
IO.puts("  Expected: INVALID with 'Brief is invalid' -> PROBLEMS file")
IO.puts("============================================================")
IO.puts("")

write_file!.(".code_my_spec/qa/#{story_id}/brief.md", """
# QA Brief

## Tool

web

This brief is missing Auth, Seeds, What To Test, and Result Path sections.
""")

result = Dispatch.evaluate(req, scope, %{})
print_result.("evaluate", result)
show_status_files.()
pause.()

# == Step 5: Write VALID brief, evaluate =======================================

IO.puts("============================================================")
IO.puts("  STEP 5: Overwrite with valid brief.md, then evaluate")
IO.puts("  Expected: INVALID -> advance to test phase")
IO.puts("  The PROMPT file should update with test-phase instructions.")
IO.puts("  The PROBLEMS file should be cleaned up.")
IO.puts("============================================================")
IO.puts("")

write_file!.(".code_my_spec/qa/#{story_id}/brief.md", """
# QA Brief: Story #{story_id}

## Tool

web

## Auth

Login as admin@example.com / password123

## Seeds

mix run priv/repo/qa_seeds.exs

## What To Test

- Visit /users/log_in
- Enter credentials
- Verify redirect to dashboard

## Result Path

.code_my_spec/qa/#{story_id}/result.md
""")

result = Dispatch.evaluate(req, scope, %{})
print_result.("evaluate", result)
show_status_files.()
pause.()

# == Step 6: Write result with issue, evaluate =================================

IO.puts("============================================================")
IO.puts("  STEP 6: Write result.md (with an issue), then Dispatch.evaluate")
IO.puts("  Expected: VALID (all phases complete)")
IO.puts("  An issue file should be created in .code_my_spec/issues/incoming/")
IO.puts("============================================================")
IO.puts("")

write_file!.(".code_my_spec/qa/#{story_id}/result.md", """
# QA Result: Story #{story_id}

## Status

partial

## Scenarios

### Login flow
- Visited /users/log_in
- Entered credentials
- Redirected to dashboard
- **Pass**

### Password reset link
- Visited /users/log_in
- Clicked "Forgot password?"
- Got 500 error page
- **Fail**

## Evidence

- `.code_my_spec/qa/#{story_id}/screenshots/login.png` -- login page
- `.code_my_spec/qa/#{story_id}/screenshots/dashboard.png` -- after login
- `.code_my_spec/qa/#{story_id}/screenshots/password_reset_500.png` -- 500 error

## Issues

### Password reset page returns 500

#### Severity

high

#### Scope

app

#### Description

Clicking the "Forgot password?" link on the login page navigates to /users/reset-password
which returns a 500 Internal Server Error. The feature appears to be unimplemented or has
a routing/controller error.
""")

result = Dispatch.evaluate(req, scope, %{})
print_result.("evaluate", result)
show_status_files.()

# -- Check issue files ---------------------------------------------------------

issues_dir = Path.join(env.cwd, ".code_my_spec/issues/incoming")

IO.puts("")
IO.puts("--- issue files ---")

if File.exists?(issues_dir) do
  case File.ls!(issues_dir) do
    [] ->
      IO.puts("  (no issue files created)")

    files ->
      qa_issues = Enum.filter(files, &String.starts_with?(&1, "qa-#{story_id}-"))

      if Enum.empty?(qa_issues) do
        IO.puts("  (no issue files for story #{story_id})")
      else
        Enum.each(qa_issues, fn file ->
          path = Path.join(issues_dir, file)
          content = File.read!(path)
          IO.puts("  #{file} (#{String.length(content)} chars)")
          IO.puts("    First line: #{content |> String.split("\n") |> Enum.find(&(&1 != ""))}")
        end)
      end
  end
else
  IO.puts("  (issues/incoming/ directory does not exist)")
end

IO.puts("---")

# -- Done ----------------------------------------------------------------------

IO.puts("")
IO.puts("============================================================")
IO.puts("  DONE")
IO.puts("============================================================")
IO.puts("")
IO.puts("QA artifacts written to: #{qa_dir}/")
IO.puts("  plan.md")
IO.puts("  #{story_id}/brief.md")
IO.puts("  #{story_id}/result.md")
IO.puts("")
IO.puts("Status files written to: .code_my_spec/status/qa/")
IO.puts("  story_#{story_id}_qa_story.md (prompt)")
IO.puts("  story_#{story_id}_qa_story_problems.md (if incomplete)")
IO.puts("")
IO.puts("Issue files written to: .code_my_spec/issues/incoming/")
IO.puts("  qa-#{story_id}-password_reset_page_returns_500.md (expected)")
