# StartImplementation Step-Through (full graph walk)
#
# Walks through StartImplementation's graph traversal on a real project,
# showing each step: get_next_actions → before_dispatch → Dispatch.command.
#
# Designed for projects with two bounded contexts and cross-context dependencies
# (e.g. math_test_project: Calculations context + CalculationLive live_context).
#
# What this tests:
#   - Graph walk order: project reqs → stories → components → dependencies
#   - before_dispatch callback: skip vs proceed
#   - Re-walk on skip (requirement satisfied by before_dispatch)
#   - Dependency traversal across context boundaries
#   - Requirement progression within a story
#
# Usage:
#   mix run test/support/scripts/start_implementation_step_through.exs [project_dir]
#
# Prerequisites:
#   - Database running (app started by mix run)
#   - Target project has .code_my_spec/config.yml
#   - Project synced (components, stories, requirements in DB)

alias CodeMySpec.Components
alias CodeMySpec.ProjectCoordinator
alias CodeMySpec.ProjectCoordinator.Dispatch
alias CodeMySpec.ProjectSync.Sync
alias CodeMySpec.Repo
alias CodeMySpec.Requirements.Requirement
alias CodeMySpec.Requirements.Sync, as: RequirementsSync
alias CodeMySpec.Stories
alias CodeMySpec.Users.Scope

# -- Args ----------------------------------------------------------------------

project_dir =
  case System.argv() do
    [] -> File.cwd!()
    [dir] -> dir
    _ ->
      IO.puts("Usage: mix run test/support/scripts/start_implementation_step_through.exs [project_dir]")
      System.halt(1)
  end

# -- Build scope ---------------------------------------------------------------

{:ok, scope} = Scope.from_local_config(project_dir)
env = scope.environment

IO.puts("============================================================")
IO.puts("  StartImplementation Step-Through (graph walk)")
IO.puts("============================================================")
IO.puts("")
IO.puts("  Project:     #{scope.active_project.name}")
IO.puts("  Project Dir: #{env.cwd}")
IO.puts("")

# -- Helpers -------------------------------------------------------------------

pause = fn ->
  IO.puts("")
  IO.write(">>> Press Enter to continue...")
  IO.read(:stdio, :line)
  IO.puts("")
end

print_dispatch_result = fn label, result ->
  case result do
    {:ok, :skip} ->
      IO.puts("#{label}: SKIP (before_dispatch satisfied the requirement)")

    {:ok, prompt} when is_binary(prompt) ->
      IO.puts("#{label}: OK (#{String.length(prompt)} chars)")
      IO.puts("--- first 600 chars ---")
      IO.puts(String.slice(prompt, 0..599))
      IO.puts("---")

    {:ok, :valid} ->
      IO.puts("#{label}: VALID")

    {:ok, :invalid, feedback} ->
      IO.puts("#{label}: INVALID")
      IO.puts("--- feedback (first 600 chars) ---")
      IO.puts(String.slice(feedback, 0..599))
      IO.puts("---")

    {:error, reason} ->
      IO.puts("#{label}: ERROR")
      IO.puts("  #{inspect(reason)}")
  end
end

print_requirement = fn req ->
  IO.puts("  Name:         #{req.name}")
  IO.puts("  Scope:        #{req.scope}")
  IO.puts("  Task Module:  #{inspect(req.satisfied_by)}")
  IO.puts("  Satisfied:    #{req.satisfied}")

  cond do
    req.story_id -> IO.puts("  Story ID:     #{req.story_id}")
    req.component_id -> IO.puts("  Component ID: #{req.component_id}")
    req.project_id -> IO.puts("  Project ID:   #{req.project_id}")
    true -> :ok
  end
end

show_stories = fn ->
  stories =
    Stories.list_project_stories_by_priority(scope)
    |> Repo.preload(:requirements)

  IO.puts("--- stories (#{length(stories)}) ---")

  Enum.each(stories, fn story ->
    reqs = story.requirements || []
    satisfied = Enum.count(reqs, & &1.satisfied)
    total = length(reqs)
    component_label =
      if story.component_id do
        case Components.get_component(scope, story.component_id) do
          nil -> "(component #{story.component_id})"
          c -> c.module_name
        end
      else
        "(no component)"
      end

    IO.puts("  ##{story.id} #{story.title} → #{component_label} [#{satisfied}/#{total}]")

    Enum.each(reqs, fn req ->
      mark = if req.satisfied, do: "✓", else: "✗"
      IO.puts("    #{mark} #{req.name}")
    end)
  end)

  IO.puts("---")
end

show_project_requirements = fn ->
  project = scope.active_project |> Repo.preload(:requirements)
  reqs = project.requirements || []

  IO.puts("--- project requirements (#{length(reqs)}) ---")

  Enum.each(reqs, fn req ->
    mark = if req.satisfied, do: "✓", else: "✗"
    IO.puts("  #{mark} #{req.name}")
  end)

  IO.puts("---")
end

show_component_tree = fn component ->
  components = ProjectCoordinator.collect_components(scope, component)
  actionable = ProjectCoordinator.find_actionable(scope, components)

  IO.puts("--- component tree: #{component.module_name} (#{length(components)} total) ---")

  Enum.each(components, fn c ->
    reqs = c.requirements || []
    satisfied = Enum.count(reqs, & &1.satisfied)
    total = length(reqs)
    depth = if c.parent_component_id, do: "  ", else: ""
    IO.puts("  #{depth}#{c.module_name} (#{c.type}) [#{satisfied}/#{total}]")
  end)

  IO.puts("")
  IO.puts("  Actionable: #{length(actionable)}")

  Enum.each(actionable, fn %{component: c, task_module: tm, definitions: defs} ->
    suffix = ProjectCoordinator.task_module_suffix(tm)
    def_names = Enum.map_join(defs, ", ", & &1.name)
    IO.puts("    #{c.module_name} → #{suffix} [#{def_names}]")
  end)

  IO.puts("---")
end

# == Step 0: Sync & show initial state =========================================

IO.puts("============================================================")
IO.puts("  STEP 0: Sync project & show initial state")
IO.puts("============================================================")
IO.puts("")

IO.puts("  Syncing project...")

case Sync.sync_all(scope, base_dir: env.cwd) do
  {:ok, result} ->
    IO.puts("  Sync OK: #{inspect(Map.keys(result))}")

  {:error, reason} ->
    IO.puts("  Sync ERROR: #{inspect(reason)}")
    IO.puts("  Continuing anyway...")
end

IO.puts("")
show_project_requirements.()
IO.puts("")
show_stories.()

# Show component trees for contexts with dependencies
IO.puts("")
IO.puts("--- component dependency overview ---")

all_components = Components.list_components_with_dependencies(scope)
contexts = Enum.filter(all_components, &(&1.type in ["context", "coordination_context", "live_context"]))

Enum.each(contexts, fn ctx ->
  deps = case ctx.dependencies do
    %Ecto.Association.NotLoaded{} -> []
    deps -> deps
  end

  dep_names = Enum.map_join(deps, ", ", & &1.module_name)

  if dep_names != "" do
    IO.puts("  #{ctx.module_name} depends on: #{dep_names}")
  end
end)

IO.puts("---")

pause.()

# == Step 1+: Iterative graph walk =============================================

max_steps = 15
step = 1

walk_graph = fn walk_graph, step ->
  if step > max_steps do
    IO.puts("  Reached max steps (#{max_steps}), stopping.")
    :done
  else
    IO.puts("============================================================")
    IO.puts("  STEP #{step}: get_next_actions → Dispatch.command")
    IO.puts("============================================================")
    IO.puts("")

    case ProjectCoordinator.get_next_actions(scope) do
      {:ok, %Requirement{} = req} ->
        IO.puts("  Graph returned requirement:")
        print_requirement.(req)
        IO.puts("")

        # Show the component tree if this is a component/story requirement
        cond do
          req.component_id ->
            component = Components.get_component!(scope, req.component_id)
            show_component_tree.(component)

          req.story_id ->
            story = Stories.get_story!(scope, req.story_id)

            if story.component_id do
              component = Components.get_component!(scope, story.component_id)
              show_component_tree.(component)
            end

          true ->
            :ok
        end

        IO.puts("")
        IO.puts("  Calling Dispatch.command...")
        IO.puts("")

        result = Dispatch.command(req, scope, %{})
        print_dispatch_result.("  Dispatch.command", result)

        case result do
          {:ok, :skip} ->
            IO.puts("")
            IO.puts("  before_dispatch skipped this requirement!")
            IO.puts("  Re-walking graph (same as StartImplementation)...")
            IO.puts("")
            walk_graph.(walk_graph, step + 1)

          {:ok, _prompt} ->
            IO.puts("")
            IO.puts("  Task dispatched. In a real session, the agent would")
            IO.puts("  now execute the prompt and the hook would validate.")
            IO.puts("")
            IO.puts("  Options:")
            IO.puts("    [Enter]  — re-walk graph (see what's next without simulating work)")
            IO.puts("    s        — skip to re-sync + re-walk (refresh requirements)")
            IO.puts("    q        — quit")
            IO.puts("")
            IO.write(">>> Choice: ")

            case IO.read(:stdio, :line) |> String.trim() do
              "q" ->
                :done

              "s" ->
                IO.puts("")
                IO.puts("  Re-syncing requirements...")
                components = Components.list_components(scope)
                synced = RequirementsSync.sync_all_requirements(components, scope)
                satisfied_count = Enum.count(synced, fn c ->
                  Enum.all?(c.requirements || [], & &1.satisfied)
                end)
                IO.puts("  #{satisfied_count}/#{length(synced)} components fully satisfied")

                # Also re-sync stories and project
                stories = Stories.list_project_stories_by_priority(scope)
                RequirementsSync.sync_story_requirements(stories, scope)
                RequirementsSync.sync_project_requirements(scope)
                IO.puts("  Story + project requirements re-synced")
                IO.puts("")

                walk_graph.(walk_graph, step + 1)

              _ ->
                walk_graph.(walk_graph, step + 1)
            end

          {:error, _reason} ->
            IO.puts("")
            IO.puts("  Dispatch failed. Press Enter to re-walk or 'q' to quit.")
            IO.write(">>> ")

            case IO.read(:stdio, :line) |> String.trim() do
              "q" -> :done
              _ -> walk_graph.(walk_graph, step + 1)
            end
        end

      :complete ->
        IO.puts("  Graph returned: :complete")
        IO.puts("  All requirements are satisfied!")
        IO.puts("")
        show_project_requirements.()
        IO.puts("")
        show_stories.()
        :done

      {:error, reason} ->
        IO.puts("  Graph returned: {:error, #{inspect(reason)}}")
        IO.puts("")
        IO.puts("  This usually means a requirement is unsatisfied but")
        IO.puts("  its descendants are all complete (stuck state).")
        IO.puts("")
        IO.puts("  Press Enter to try re-syncing, or 'q' to quit.")
        IO.write(">>> ")

        case IO.read(:stdio, :line) |> String.trim() do
          "q" ->
            :done

          _ ->
            IO.puts("  Re-syncing all requirements...")
            components = Components.list_components(scope)
            RequirementsSync.sync_all_requirements(components, scope)
            stories = Stories.list_project_stories_by_priority(scope)
            RequirementsSync.sync_story_requirements(stories, scope)
            RequirementsSync.sync_project_requirements(scope)
            IO.puts("  Done.")
            IO.puts("")
            walk_graph.(walk_graph, step + 1)
        end
    end
  end
end

walk_graph.(walk_graph, step)

# -- Done ----------------------------------------------------------------------

IO.puts("")
IO.puts("============================================================")
IO.puts("  DONE")
IO.puts("============================================================")
IO.puts("")
IO.puts("Final state:")
IO.puts("")
show_project_requirements.()
IO.puts("")
show_stories.()
