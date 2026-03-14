defmodule CodeMySpec.StepThrough.ProjectPrep do
  @moduledoc """
  Prepares a working copy of a project for step-through testing.

  Copies the golden source to a temp directory, optionally strips artifacts,
  builds scope, syncs the project, and ensures stories are linked to components.
  """

  alias CodeMySpec.Components
  alias CodeMySpec.ProjectSync.Sync
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Sync, as: RequirementsSync
  alias CodeMySpec.StepThrough.FileStager
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @doc """
  Full project preparation for step-through.

  Options:
    - `:strip` - Strip to skeleton before walking (default: false)
    - `:link_stories` - Auto-link stories to components (default: true)

  Returns `{:ok, %{scope: scope, golden_dir: golden_dir, working_dir: working_dir}}`
  """
  def prepare(golden_dir, opts \\ []) do
    strip? = Keyword.get(opts, :strip, false)
    link_stories? = Keyword.get(opts, :link_stories, true)

    # 1. Copy to temp working directory
    working_dir = create_working_copy(golden_dir)
    IO.puts("  Working copy: #{working_dir}")

    # 2. Optionally strip
    if strip? do
      IO.puts("  Stripping to skeleton...")
      FileStager.strip_to_skeleton(working_dir)
    end

    # 3. Build scope
    {:ok, scope} = Scope.from_local_config(working_dir)
    IO.puts("  Project: #{scope.active_project.name}")
    IO.puts("  Project ID: #{scope.active_project.id}")

    # 4. Sync to discover components and calculate requirements
    IO.puts("  Syncing project...")

    case Sync.sync_all(scope, base_dir: working_dir) do
      {:ok, result} ->
        timings = result[:timings] || %{}
        IO.puts("  Sync OK (#{timings[:total_ms] || "?"}ms)")

      {:error, reason} ->
        IO.puts("  Sync ERROR: #{inspect(reason)}")
        IO.puts("  Continuing anyway...")
    end

    # 5. Link stories to components
    if link_stories? do
      link_all_stories(scope)
    end

    # 7. Re-sync story requirements after linking
    stories = Stories.list_project_stories_by_priority(scope) |> Repo.preload(:requirements)
    RequirementsSync.sync_story_requirements(stories, scope)
    RequirementsSync.sync_project_requirements(scope)

    {:ok, %{scope: scope, golden_dir: golden_dir, working_dir: working_dir}}
  end

  @doc """
  Links unlinked stories to their matching surface components.
  Uses title-based matching (works for math_test_project).
  """
  def link_all_stories(scope) do
    stories = Stories.list_stories(scope)
    components = Components.list_components(scope)

    surface_types = ~w(controller live_context liveview liveview_component)
    surface_components = Enum.filter(components, &(&1.type in surface_types))

    linked_count =
      stories
      |> Enum.filter(&is_nil(&1.component_id))
      |> Enum.count(fn story ->
        case find_matching_component(story, surface_components) do
          nil ->
            false

          component ->
            {:ok, _} = Stories.set_story_component(scope, story, component.id)
            IO.puts("  Linked: '#{story.title}' → #{component.module_name}")
            true
        end
      end)

    if linked_count > 0 do
      IO.puts("  Linked #{linked_count} stories to components")
    else
      IO.puts("  All stories already linked (or no matches found)")
    end
  end

  # Match story titles to component module names
  # Tries exact suffix match first, then keyword containment
  defp find_matching_component(story, surface_components) do
    # Build search terms from the story title
    # "Addition" → "addition", "Calculation History" → "history"
    search_terms =
      story.title
      |> String.split()
      |> Enum.map(&String.downcase/1)
      |> Enum.reject(&(&1 in ~w(as a user i can and see the my of)))

    Enum.find(surface_components, fn comp ->
      module_lower = String.downcase(comp.module_name)

      # Check if the last meaningful word matches the module name suffix
      Enum.any?(search_terms, fn term ->
        String.ends_with?(module_lower, term)
      end)
    end)
  end

  defp create_working_copy(golden_dir) do
    timestamp = System.os_time(:second)
    project_name = Path.basename(golden_dir)
    working_dir = Path.join(System.tmp_dir!(), "step_through_#{project_name}_#{timestamp}")

    File.mkdir_p!(working_dir)
    {_, 0} = System.cmd("cp", ["-R", "#{golden_dir}/.", working_dir])

    working_dir
  end
end
