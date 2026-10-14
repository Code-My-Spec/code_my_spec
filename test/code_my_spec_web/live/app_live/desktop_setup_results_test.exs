defmodule CodeMySpecWeb.AppLive.DesktopSetupResultsTest do
  use ExUnit.Case, async: false

  alias CmsHarness.Setup.Store
  alias CodeMySpecWeb.AppLive.DesktopSetupResults

  setup do
    root = Path.join(System.tmp_dir!(), "setup-results-#{System.unique_integer([:positive])}")
    previous_root = System.get_env("CMS_PROJECT_DIR")
    previous_env = Application.get_env(:code_my_spec, :env)
    System.put_env("CMS_PROJECT_DIR", root)
    Application.put_env(:code_my_spec, :env, :desktop)

    on_exit(fn ->
      if previous_root,
        do: System.put_env("CMS_PROJECT_DIR", previous_root),
        else: System.delete_env("CMS_PROJECT_DIR")

      if previous_env,
        do: Application.put_env(:code_my_spec, :env, previous_env),
        else: Application.delete_env(:code_my_spec, :env)

      File.rm_rf!(root)
    end)

    project_id = Ecto.UUID.generate()
    run_id = String.duplicate("a", 32)
    directory = Store.directory()

    snapshot = %{
      "version" => 1,
      "run_id" => run_id,
      "steps" => [],
      "results_path" => Store.results_path(directory, run_id),
      "operations" => %{"connect" => %{"state" => "done", "result" => %{"id" => project_id}}}
    }

    :ok = Store.save(directory, snapshot)
    %{project_id: project_id, snapshot: snapshot, directory: directory}
  end

  test "only the recorded project receives the snapshot and reads preserve it", context do
    before_bytes = File.read!(context.snapshot["results_path"])
    assert DesktopSetupResults.load(context.project_id) == context.snapshot
    assert DesktopSetupResults.load(Ecto.UUID.generate()) == nil
    assert File.read!(context.snapshot["results_path"]) == before_bytes
  end

  test "web mode never exposes machine-local setup results", context do
    Application.put_env(:code_my_spec, :env, :test)
    assert DesktopSetupResults.load(context.project_id) == nil
  end

  test "an incomplete connection does not supply cockpit results", context do
    snapshot = put_in(context.snapshot, ["operations", "connect", "state"], "errored")
    :ok = Store.save(context.directory, snapshot)
    assert DesktopSetupResults.load(context.project_id) == nil
  end
end
