# ContextComponentSpecs Step-Through via Dispatch (:children scope)
#
# Tests the children_designs lifecycle as StartImplementation would invoke it,
# by calling Dispatch.command/evaluate directly with a constructed Requirement.
#
# The :children scope orchestration:
#   1. Dispatch.command loads context + descendants, finds actionable children,
#      calls task_module.orchestrate for each → writes prompt files
#   2. Dispatch.evaluate re-checks children, calls orchestrate_evaluate for each,
#      returns :valid when all children are complete
#
# Self-contained: creates TestContext + children, syncs requirements, steps through
# the incomplete → complete lifecycle, then cleans up spec files (not status files —
# those should be cleaned by the code under test).
#
# Usage:
#   mix run test/support/scripts/children_designs_step_through.exs [project_dir]
#
# Prerequisites:
#   - Database running (app started by mix run)
#   - Target project has .code_my_spec/config.yml

alias CodeMySpec.AgentTasks.ContextComponentSpecs
alias CodeMySpec.Components
alias CodeMySpec.Environments
alias CodeMySpec.ProjectCoordinator
alias CodeMySpec.ProjectCoordinator.Dispatch
alias CodeMySpec.Requirements.Requirement
alias CodeMySpec.Requirements.Sync, as: RequirementsSync
alias CodeMySpec.Users.Scope

# -- Args ----------------------------------------------------------------------

project_dir =
  case System.argv() do
    [] -> File.cwd!()
    [dir] -> dir
    _ ->
      IO.puts("Usage: mix run test/support/scripts/children_designs_step_through.exs [project_dir]")
      System.halt(1)
  end

# -- Build scope ---------------------------------------------------------------

{:ok, scope} = Scope.from_local_config(project_dir)
env = scope.environment

IO.puts("============================================================")
IO.puts("  ContextComponentSpecs Step-Through (:children scope)")
IO.puts("============================================================")
IO.puts("")
IO.puts("  Project:     #{scope.active_project.name}")
IO.puts("  Project Dir: #{env.cwd}")
IO.puts("")

# -- Spec file paths -----------------------------------------------------------

context_spec_path = ".code_my_spec/spec/code_my_spec/test_context.spec.md"
widget_spec_path = ".code_my_spec/spec/code_my_spec/test_context/widget.spec.md"
widget_repo_spec_path = ".code_my_spec/spec/code_my_spec/test_context/widget_repository.spec.md"

child_spec_paths = [widget_spec_path, widget_repo_spec_path]

# -- Spec file content ---------------------------------------------------------

context_spec_content = """
# CodeMySpec.TestContext

**Type**: context

Test context for the children_designs step-through script.

## Functions

### list_widgets/1

Returns all widgets.

```elixir
@spec list_widgets(Scope.t()) :: [Widget.t()]
```

**Process**:
1. Delegate to WidgetRepository.list_widgets/1

**Test Assertions**:
- returns widgets belonging to the scope

## Dependencies

- CodeMySpec.TestContext.Widget
- CodeMySpec.TestContext.WidgetRepository
- CodeMySpec.Users.Scope

## Components

### CodeMySpec.TestContext.Widget

Ecto schema for widgets.

### CodeMySpec.TestContext.WidgetRepository

Data access layer for widgets.
"""

# Schema spec: requires "fields" section
widget_spec_content = """
# CodeMySpec.TestContext.Widget

Ecto schema representing a widget with a name and description.

## Fields

| Field       | Type    | Required | Description       | Constraints    |
| ----------- | ------- | -------- | ----------------- | -------------- |
| id          | integer | Yes      | Primary key       | Auto-generated |
| name        | string  | Yes      | Widget name       | Max: 255       |
| description | string  | No       | Widget description|                |
"""

# Repository spec: requires "functions" or "delegates", plus "dependencies"
widget_repo_spec_content = """
# CodeMySpec.TestContext.WidgetRepository

Data access layer for widget entities.

## Functions

### list_widgets/1

Lists all widgets for the scope.

```elixir
@spec list_widgets(Scope.t()) :: [Widget.t()]
```

**Process**:
1. Query widgets table

**Test Assertions**:
- returns all widgets

## Dependencies

- CodeMySpec.TestContext.Widget
- Ecto.Repo
"""

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
      IO.puts("--- first 800 chars ---")
      IO.puts(String.slice(prompt, 0..799))
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

show_status_files = fn status_dir ->
  full_status_dir = Path.join(env.cwd, status_dir)

  IO.puts("")
  IO.puts("--- status files in #{status_dir}/ ---")

  if File.exists?(full_status_dir) do
    case File.ls!(full_status_dir) do
      [] ->
        IO.puts("  (empty)")

      files ->
        files
        |> Enum.sort()
        |> Enum.each(fn file ->
          full_path = Path.join(full_status_dir, file)
          content = File.read!(full_path)
          tag = if String.ends_with?(file, "_problems.md"), do: "PROBLEMS", else: "PROMPT"
          IO.puts("  #{tag}: #{file} (#{String.length(content)} chars)")
          IO.puts("    First line: #{content |> String.split("\n") |> Enum.find(&(&1 != ""))}")
        end)
    end
  else
    IO.puts("  (directory does not exist yet)")
  end

  IO.puts("---")
end

sync_requirements! = fn components ->
  reloaded = Enum.map(components, &Components.get_component!(scope, &1.id))
  synced = RequirementsSync.sync_all_requirements(reloaded, scope)

  Enum.each(synced, fn c ->
    reqs = c.requirements || []
    satisfied = Enum.count(reqs, & &1.satisfied)
    total = length(reqs)
    IO.puts("  #{c.module_name}: #{satisfied}/#{total} requirements satisfied")
  end)

  synced
end

# == Step 0: Create TestContext + children, sync requirements ==================

IO.puts("============================================================")
IO.puts("  STEP 0: Create TestContext with children, sync requirements")
IO.puts("  Upserts context + 2 children, writes context spec file,")
IO.puts("  clears child specs, then syncs so children are unsatisfied.")
IO.puts("============================================================")
IO.puts("")

# Upsert context
context = Components.upsert_component(scope, %{
  name: "TestContext",
  module_name: "CodeMySpec.TestContext",
  type: "context",
  description: "Test context for children_designs step-through"
})

IO.puts("  Context: #{context.module_name} (id: #{context.id})")

# Upsert children
widget = Components.upsert_component(scope, %{
  name: "Widget",
  module_name: "CodeMySpec.TestContext.Widget",
  type: "schema",
  parent_component_id: context.id,
  description: "Schema child for step-through test"
})

IO.puts("  Child:   #{widget.module_name} (id: #{widget.id})")

widget_repo = Components.upsert_component(scope, %{
  name: "WidgetRepository",
  module_name: "CodeMySpec.TestContext.WidgetRepository",
  type: "repository",
  parent_component_id: context.id,
  description: "Repository child for step-through test"
})

IO.puts("  Child:   #{widget_repo.module_name} (id: #{widget_repo.id})")

# Write context spec (so context's spec_file/spec_valid are satisfied)
:ok = Environments.write_file(env, context_spec_path, context_spec_content)
IO.puts("  Wrote:   #{context_spec_path}")

# Delete child spec files (so children have unsatisfied spec_file)
Enum.each(child_spec_paths, &Environments.delete_file(env, &1))
IO.puts("  Cleared child spec files (so spec_file requirements are unsatisfied)")

# Sync requirements
IO.puts("")
IO.puts("  Syncing requirements...")
all_components = [context, widget, widget_repo]
sync_requirements!.(all_components)

# Reload context with fresh requirements
context = Components.get_component!(scope, context.id)

pause.()

# -- Show context state --------------------------------------------------------

children = Components.list_child_components(scope, context.id)
status_dir = ProjectCoordinator.component_status_dir(context)

IO.puts("  Context ID:  #{context.id}")
IO.puts("  Type:        #{context.type}")
IO.puts("  Children:    #{length(children)}")
IO.puts("  Status Dir:  #{status_dir}")
IO.puts("")

IO.puts("--- children ---")

Enum.each(children, fn child ->
  reqs = child.requirements || []
  satisfied_names = reqs |> Enum.filter(& &1.satisfied) |> Enum.map_join(", ", & &1.name)
  unsatisfied_names = reqs |> Enum.reject(& &1.satisfied) |> Enum.map_join(", ", & &1.name)

  IO.puts("  #{child.module_name} (#{child.type})")
  IO.puts("    satisfied:   #{if satisfied_names == "", do: "(none)", else: satisfied_names}")
  IO.puts("    unsatisfied: #{if unsatisfied_names == "", do: "(none)", else: unsatisfied_names}")
end)

IO.puts("---")
IO.puts("")

# -- Show actionable children --------------------------------------------------

components = ProjectCoordinator.collect_components(scope, context)
actionable = ProjectCoordinator.find_actionable(scope, components)

IO.puts("--- actionable (via find_actionable) ---")

if Enum.empty?(actionable) do
  IO.puts("  (none — all children are complete)")
  IO.puts("")
  IO.puts("Nothing to step through. All requirements are satisfied.")
  System.halt(0)
else
  Enum.each(actionable, fn %{component: c, task_module: tm, definitions: defs} ->
    suffix = ProjectCoordinator.task_module_suffix(tm)
    def_names = Enum.map_join(defs, ", ", & &1.name)
    IO.puts("  #{c.module_name} → #{suffix} [#{def_names}]")
  end)
end

IO.puts("---")

# -- Build Requirement ---------------------------------------------------------

req = %Requirement{
  name: "children_designs",
  artifact_type: :hierarchy,
  description: "Child component designs are complete",
  checker_module: CodeMySpec.Requirements.HierarchicalChecker,
  satisfied_by: ContextComponentSpecs,
  scope: :children,
  satisfied: false,
  component_id: context.id
}

IO.puts("")
IO.puts("  Requirement: #{req.name} (scope: #{req.scope})")
IO.puts("  Task Module: #{inspect(req.satisfied_by)}")
IO.puts("")

# == Step 1: Dispatch.command (:children) — incomplete =========================

IO.puts("============================================================")
IO.puts("  STEP 1: Dispatch.command (:children)")
IO.puts("  Generates parent prompt + per-child orchestration prompts.")
IO.puts("  Each actionable child gets a prompt file in the status dir.")
IO.puts("============================================================")
IO.puts("")

result = Dispatch.command(req, scope, %{})
print_result.("command", result)
show_status_files.(status_dir)
pause.()

# == Step 2: Dispatch.evaluate — children incomplete ===========================

IO.puts("============================================================")
IO.puts("  STEP 2: Dispatch.evaluate (children incomplete)")
IO.puts("  Expected: INVALID — children have unsatisfied requirements.")
IO.puts("============================================================")
IO.puts("")

result = Dispatch.evaluate(req, scope, %{})
print_result.("evaluate", result)
show_status_files.(status_dir)
pause.()

# == Step 3: Write child specs, re-sync, re-evaluate ==========================

IO.puts("============================================================")
IO.puts("  STEP 3: Write child spec stubs, re-sync requirements")
IO.puts("  Simulates subagents completing their spec-writing work.")
IO.puts("  After sync, children should have spec_file satisfied.")
IO.puts("============================================================")
IO.puts("")

:ok = Environments.write_file(env, widget_spec_path, widget_spec_content)
IO.puts("  Wrote: #{widget_spec_path}")

:ok = Environments.write_file(env, widget_repo_spec_path, widget_repo_spec_content)
IO.puts("  Wrote: #{widget_repo_spec_path}")

IO.puts("")
IO.puts("  Re-syncing requirements...")
sync_requirements!.(all_components)

pause.()

# == Step 4: Dispatch.evaluate — children complete =============================

IO.puts("============================================================")
IO.puts("  STEP 4: Dispatch.evaluate (children complete)")
IO.puts("  Expected: VALID — all children have spec_file satisfied.")
IO.puts("  Status dir should be cleaned up by the code under test.")
IO.puts("============================================================")
IO.puts("")

result = Dispatch.evaluate(req, scope, %{})
print_result.("evaluate", result)
show_status_files.(status_dir)
pause.()

# == Step 5: Dispatch.command after completion =================================

IO.puts("============================================================")
IO.puts("  STEP 5: Dispatch.command (after completion)")
IO.puts("  Expected: ERROR — no actionable children remain.")
IO.puts("  This is what happens when StartImplementation re-dispatches")
IO.puts("  after the requirement is already satisfied.")
IO.puts("============================================================")
IO.puts("")

result = Dispatch.command(req, scope, %{})
print_result.("command (post-completion)", result)

# == Cleanup ===================================================================

IO.puts("")
IO.puts("============================================================")
IO.puts("  CLEANUP: Removing child spec stubs")
IO.puts("============================================================")
IO.puts("")

# Only delete the child spec files the script wrote to simulate subagent work.
# Context spec, status files, and DB records are left for the code / sync to manage.
Enum.each(child_spec_paths, fn path ->
  case Environments.delete_file(env, path) do
    :ok -> IO.puts("  Deleted: #{path}")
    _ -> IO.puts("  (not found): #{path}")
  end
end)

show_status_files.(status_dir)

# -- Done ----------------------------------------------------------------------

IO.puts("")
IO.puts("============================================================")
IO.puts("  DONE")
IO.puts("============================================================")
