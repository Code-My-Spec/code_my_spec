defmodule CodeMySpec.Requirements.SpexBoundaryChecker do
  @moduledoc """
  Delegate checker for the `spex_boundary_ready` requirement on
  `project_graph`.

  Verifies that the BDD-spec boundary protections are physically present
  in the project. Existence is the only assertion — content quality
  (project-specific denies in `local/`, fixture function selection)
  lives in the agent prompt, not in this checker.

  Required artifacts:

    * `.code_my_spec/credo_checks/framework/spex_denied_calls.ex` — the
      framework's function-level denies (System.cmd / Code.eval /
      Kernel.apply / :os.cmd) inside `_spex.exs` files. Whole-module
      denies live in the project-local check.
    * `.code_my_spec/credo_checks/framework/no_direct_send_in_spex.ex` —
      denies direct `send/2` from a spec, forcing PubSub interactions to
      go through the real Phoenix surface.
    * At least one `.ex` file under `.code_my_spec/credo_checks/local/` —
      the project-local check filling in whole-module denies (stdlib
      bypasses + internal app contexts).
    * `test/support/fixtures/<app>_spex_fixtures.ex` — the curated bridge
      module that's the only legal door from a spec into in-app state.

  Returns `{boolean(), map()}` per the checker contract.
  """

  alias CodeMySpec.AgentTasks.Setup.Helpers
  alias CodeMySpec.{Files, Paths}
  alias CodeMySpec.Users.Scope

  @framework_check_files ["spex_denied_calls.ex", "no_direct_send_in_spex.ex"]

  @spec complete?(Scope.t(), term()) :: {boolean(), map()}
  def complete?(%Scope{active_project_id: project_id} = scope, _entity)
      when not is_nil(project_id) do
    # One query; every gap below is a question about which files exist, and
    # each used to be its own stat or directory listing against a disk this
    # server may not have.
    paths = scope |> Files.list_files() |> MapSet.new(& &1.path)

    gaps =
      []
      |> add_credo_check_gaps(paths)
      |> add_local_credo_check_gap(paths)
      |> add_fixtures_bridge_gap(paths, scope)
      |> add_project_bdd_plan_gap(paths)

    case gaps do
      [] -> {true, %{status: "Spex boundary protections installed"}}
      gaps -> {false, %{reason: format_gaps(gaps)}}
    end
  end

  def complete?(_scope, _entity) do
    {false, %{reason: "No active project in scope — cannot verify spex boundary files."}}
  end

  defp add_credo_check_gaps(gaps, paths) do
    framework_dir = Paths.credo_checks_framework_dir()

    missing =
      Enum.reject(@framework_check_files, fn file ->
        MapSet.member?(paths, Path.join(framework_dir, file))
      end)

    Enum.map(missing, fn file ->
      "`#{Path.join(framework_dir, file)}` is missing — call `install_credo_checks` to copy framework checks into the project."
    end) ++ gaps
  end

  # Looks for at least one .ex file under `.code_my_spec/credo_checks/local/`.
  # The local check carries the project's whole-module deny list (stdlib
  # bypasses + internal app contexts); without it the framework template
  # alone has no whole-module denies wired up.
  defp add_local_credo_check_gap(gaps, paths) do
    local_dir = Paths.credo_checks_local_dir()
    prefix = local_dir <> "/"

    # "Directory missing" and "directory present but empty" used to be two
    # different messages. Directories are not tracked as files, so from here they
    # are one state: nothing under the prefix synced. The surviving message names
    # the file to write, which was the actionable half of both.
    if Enum.any?(paths, &(String.starts_with?(&1, prefix) and String.ends_with?(&1, ".ex"))) do
      gaps
    else
      [
        "`#{local_dir}/` has no project-local Credo check (`*.ex`) — write `<app>_spex_denies.ex` filling in @denied_whole_modules with stdlib bypasses (File, Port, :file) plus internal app contexts from the architecture proposal."
        | gaps
      ]
    end
  end

  defp add_fixtures_bridge_gap(gaps, paths, scope) do
    # The synced answer only. `Helpers.app_name/1` falls back to reading
    # `mix.exs` through the environment, which for a harness-served project is a
    # `GenServer.call` with a 35-second limit — and this runs inside the graph
    # computation, which the stop decision waits on. An unsynced `mix.exs` made
    # every agent turn pay that to avoid printing the gap below.
    #
    # Nothing is lost: not knowing the app name was already an outcome here, and
    # `mix.exs` is synced on any project far enough along to have spex at all.
    case Helpers.synced_app_name(scope) do
      nil ->
        ["Could not determine app name from `mix.exs` — cannot verify fixtures bridge." | gaps]

      app ->
        path = Path.join(["test", "support", "fixtures", "#{app}_spex_fixtures.ex"])

        if MapSet.member?(paths, path) do
          gaps
        else
          [
            "`#{path}` is missing — write the curated fixtures bridge module that re-exports state setup helpers from `<App>Test` for use in BDD specs."
            | gaps
          ]
        end
    end
  end

  defp add_project_bdd_plan_gap(gaps, paths) do
    plan_dir = Path.join([Paths.knowledge_dir(), "bdd", "spex"])
    prefix = plan_dir <> "/"

    if Enum.any?(paths, &(String.starts_with?(&1, prefix) and String.ends_with?(&1, ".md"))) do
      gaps
    else
      [
        "`#{plan_dir}/` has no project BDD spec plan (`*.md`) — write a project-tailored doc covering this project's public surfaces, fixture inventory, and observable patterns."
        | gaps
      ]
    end
  end

  defp format_gaps(gaps) do
    bullets = Enum.map_join(gaps, "\n", &"- #{&1}")
    "Spex boundary not ready:\n\n#{bullets}"
  end
end
