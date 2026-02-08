defmodule CodeMySpec.ProjectSync.Sync do
  @moduledoc """
  Implementation module that performs the actual synchronization logic.

  This is a pure functional module with no state - all functions perform
  synchronization operations (DB operations, file system operations).
  """

  alias CodeMySpec.Architecture
  alias CodeMySpec.Components
  alias CodeMySpec.ProjectSync.StatusWriter
  alias CodeMySpec.Requirements.Sync, as: RequirementsSync
  alias CodeMySpec.Tests.TestRun
  alias CodeMySpec.Users.Scope

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
      - `:architecture_output_dir` - Directory for architecture views (defaults to "docs/architecture/")

  ## Returns
    - `{:ok, sync_result}` on success
    - `{:error, reason}` on failure
  """
  @spec sync_all(Scope.t(), keyword()) :: {:ok, sync_result()} | {:error, term()}
  def sync_all(%Scope{} = scope, opts \\ []) do
    total_start = System.monotonic_time(:millisecond)
    base_dir = Keyword.get(opts, :base_dir, File.cwd!())

    # Phase 1: Sync components (identify what changed)
    contexts_start = System.monotonic_time(:millisecond)

    with {:ok, all_components, changed_component_ids} <-
           Components.Sync.sync_changed(scope, base_dir: base_dir),
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
      refreshed_components = Components.list_components(scope)

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

      requirements_sync_ms = System.monotonic_time(:millisecond) - requirements_start

      # Phase 4: Generate architecture views
      architecture_start = System.monotonic_time(:millisecond)
      architecture_output_dir = Keyword.get(opts, :architecture_output_dir, "docs/architecture/")

      architecture_views =
        case Architecture.generate_views(scope, output_dir: Path.join(base_dir, architecture_output_dir)) do
          {:ok, paths} -> paths
          {:error, _reason} -> []
        end

      architecture_ms = System.monotonic_time(:millisecond) - architecture_start

      # Phase 5: Write context status files (roots only — children are inline via child_components)
      root_components = Enum.filter(components_with_requirements, &is_nil(&1.parent_component_id))
      status_files = StatusWriter.write_status_files(root_components, scope.environment)

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
end
