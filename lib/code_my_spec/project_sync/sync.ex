defmodule CodeMySpec.ProjectSync.Sync do
  @moduledoc """
  Implementation module that performs the actual synchronization logic.

  Two entry points:
  - `incremental_sync/2` — lightweight: sync mtimes, fix parents, clear stale
    problems, recalculate requirements, cascade. Used by FileWatcher, StartAgentTask,
    StartImplementation, WriteBddSpecs, and Validation.
  - `sync_all/2` — heavyweight: full project sync including architecture views
    and status files. Used for initial project setup.
  """

  require Logger

  alias CodeMySpec.Architecture
  alias CodeMySpec.Components
  alias CodeMySpec.Components.Sync, as: ComponentSync
  alias CodeMySpec.Problems
  alias CodeMySpec.ProjectSync.StatusWriter
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Sync, as: RequirementsSync
  alias CodeMySpec.Stories
  alias CodeMySpec.Tests.TestRun
  alias CodeMySpec.Users.Scope

  @type incremental_result :: %{
          all_components: [Components.Component.t()],
          changed_ids: [String.t()],
          expanded_ids: [String.t()]
        }

  @type sync_result :: %{
          contexts: [Components.Component.t()],
          requirements_updated: integer(),
          architecture_views: [String.t()],
          status_files: [String.t()],
          errors: [term()],
          timings: %{
            contexts_sync_ms: integer(),
            requirements_sync_ms: integer(),
            architecture_ms: integer(),
            total_ms: integer()
          }
        }

  @doc """
  Lightweight incremental sync: sync mtimes, fix parent relationships, clear
  stale problems, recalculate requirements for changed components, and cascade.

  This is the single entry point for the sync → recalculate → cascade pipeline.
  All callers that previously duplicated this logic should use this function.

  ## Options
  - `:base_dir` — project root directory (required)
  - `:write_status` — write status markdown files after sync (default false)

  ## Returns
  - `{:ok, incremental_result}` on success
  - `{:error, reason}` on failure
  """
  @spec incremental_sync(Scope.t(), keyword()) :: {:ok, incremental_result()} | {:error, term()}
  def incremental_sync(%Scope{} = scope, opts \\ []) do
    start = System.monotonic_time(:millisecond)

    with {:ok, all_components, changed_ids} <- ComponentSync.sync_changed(scope, opts),
         {:ok, expanded_ids} <-
           ComponentSync.update_parent_relationships(scope, all_components, changed_ids, opts) do
      # Clear stale problems for changed components.
      # The validation pipeline (mix test --stale) will repopulate during
      # the next Stop/SubagentStop hook.
      if expanded_ids != [] do
        Problems.delete_problems_for_components(scope, expanded_ids)
      end

      # Refresh from DB (parent relationships may have changed) and recalculate
      # ALL requirements using sync_all_requirements which handles dependency
      # ordering via topological sort.
      refreshed = Components.list_components_with_dependencies(scope)
      RequirementsSync.sync_all_requirements(refreshed, scope)

      # Cascade to story and project requirements
      stories = load_stories(scope)
      RequirementsSync.sync_story_requirements(stories, scope)
      RequirementsSync.sync_project_requirements(scope)

      if Keyword.get(opts, :write_status, false) do
        write_status_files(scope)
      end

      ms = System.monotonic_time(:millisecond) - start
      Logger.info("[ProjectSync] Incremental sync completed in #{ms}ms: #{length(expanded_ids)} component(s) changed")

      {:ok, %{all_components: all_components, changed_ids: changed_ids, expanded_ids: expanded_ids}}
    end
  end

  @doc """
  Performs a complete project synchronization.

  ## Process
  1. Syncs all contexts and their components
  2. Gets current file list from filesystem
  3. Gets latest test results (or empty test run if none exist)
  4. Analyzes and updates all component requirements
  5. Generates architecture view files (overview, dependency graph, namespace hierarchy)
  6. Returns consolidated sync statistics

  ## Parameters
    - `scope` - The user scope
    - `opts` - Options (optional)
      - `:base_dir` - Base directory to sync from (defaults to current working directory)
      - `:architecture_output_dir` - Directory for architecture views (defaults to ".code_my_spec/architecture/")

  ## Returns
    - `{:ok, sync_result}` on success
    - `{:error, reason}` on failure
  """
  @spec sync_all(Scope.t(), keyword()) :: {:ok, sync_result()} | {:error, term()}
  def sync_all(%Scope{} = scope, opts \\ []) do
    total_start = System.monotonic_time(:millisecond)
    base_dir = Keyword.get(opts, :base_dir, File.cwd!())

    # Read ignored components once, pass upstream to Components.Sync
    ignored_components = get_ignored_components(scope)

    # Phase 1: Sync components (identify what changed)
    contexts_start = System.monotonic_time(:millisecond)

    with {:ok, all_components, changed_component_ids} <-
           Components.Sync.sync_changed(scope,
             base_dir: base_dir,
             force: true,
             ignored_components: ignored_components
           ),
         # Phase 2: Update parent relationships (expand changed set)
         {:ok, expanded_changed_ids} <-
           Components.Sync.update_parent_relationships(
             scope,
             all_components,
             changed_component_ids,
             opts
           ) do
      contexts_sync_ms = System.monotonic_time(:millisecond) - contexts_start

      # Refresh components from DB — update_parent_relationships may have changed
      # parent_component_id values that the in-memory all_components doesn't reflect
      refreshed_components = Components.list_components_with_dependencies(scope)

      # Phase 3: Sync requirements for changed components
      requirements_start = System.monotonic_time(:millisecond)
      file_list = get_file_list(base_dir)
      test_run = get_latest_test_run(base_dir)

      # Pass changed component IDs to requirements sync for selective updates
      components_with_requirements =
        RequirementsSync.sync_requirements(
          scope,
          refreshed_components,
          MapSet.new(expanded_changed_ids),
          file_list,
          test_run.failures,
          opts
        )

      # Phase 3b: Sync story requirements
      stories = load_stories_with_requirements(scope)

      stories_with_requirements =
        RequirementsSync.sync_story_requirements(stories, scope, opts)

      # Phase 3c: Sync project requirements
      project_with_requirements = RequirementsSync.sync_project_requirements(scope, opts)

      requirements_sync_ms = System.monotonic_time(:millisecond) - requirements_start

      # Phase 4: Generate architecture views
      architecture_start = System.monotonic_time(:millisecond)
      architecture_output_dir =
        Keyword.get(opts, :architecture_output_dir, CodeMySpec.Paths.architecture_dir())

      architecture_views =
        case Architecture.generate_views(scope,
               output_dir: Path.join(base_dir, architecture_output_dir)
             ) do
          {:ok, paths} -> paths
          {:error, _reason} -> []
        end

      architecture_ms = System.monotonic_time(:millisecond) - architecture_start

      # Phase 5: Write context status files (roots only — children are inline via child_components)
      root_components = Enum.filter(components_with_requirements, &is_nil(&1.parent_component_id))

      status_files =
        StatusWriter.write_status_files(
          root_components,
          stories_with_requirements,
          project_with_requirements,
          scope.environment
        )

      total_ms = System.monotonic_time(:millisecond) - total_start

      {:ok,
       %{
         contexts: components_with_requirements,
         requirements_updated: length(expanded_changed_ids),
         architecture_views: architecture_views,
         status_files: status_files,
         errors: [],
         timings: %{
           contexts_sync_ms: contexts_sync_ms,
           requirements_sync_ms: requirements_sync_ms,
           architecture_ms: architecture_ms,
           total_ms: total_ms
         }
       }}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private Functions

  # Gets the list of all files in the project
  defp get_file_list(base_dir) do
    project_root = base_dir

    # Recursively list all files, excluding common directories
    # Return paths relative to project root
    Path.wildcard("#{project_root}/**/*")
    |> Enum.reject(fn path ->
      String.contains?(path, ["deps/", "_build/", ".git/", "node_modules/"])
    end)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, project_root))
  end

  # Gets ignored components from local config. Returns [] when unavailable.
  defp get_ignored_components(%Scope{cwd: nil}), do: []

  defp get_ignored_components(%Scope{cwd: cwd}) do
    case Scope.read_local_config(cwd) do
      {:ok, config} ->
        case config["ignored_components"] do
          list when is_list(list) -> list
          _ -> []
        end

      {:error, _} ->
        []
    end
  end

  defp load_stories_with_requirements(scope) do
    case Stories.list_project_stories(scope) do
      {:ok, stories} -> Repo.preload(stories, [:requirements, :component])
      _other -> []
    end
  end

  # Gets the latest test run, or creates an empty one if none exists
  defp get_latest_test_run(base_dir) do
    project_root = base_dir

    # For now, return an empty test run
    # In the future, this could query from a TestRuns context/repository
    %TestRun{
      failures: [],
      file_path: project_root,
      command: "",
      execution_status: :success,
      raw_output: "",
      ran_at: DateTime.utc_now()
    }
  end

  defp load_stories(scope) do
    case Stories.list_project_stories(scope) do
      {:ok, stories} -> Repo.preload(stories, [:requirements, :component])
      _ -> []
    end
  end

  defp write_status_files(scope) do
    components =
      Components.list_components_with_dependencies(scope)
      |> Components.HierarchicalTree.enrich()

    root_components = Enum.filter(components, &is_nil(&1.parent_component_id))

    stories =
      case Stories.list_project_stories(scope) do
        {:ok, s} -> Repo.preload(s, [:requirements, :component])
        _ -> []
      end

    project = Repo.preload(scope.active_project, :requirements)

    StatusWriter.write_status_files(root_components, stories, project, scope.environment)
  rescue
    e -> Logger.warning("[ProjectSync] Failed to write status files: #{Exception.message(e)}")
  end
end
