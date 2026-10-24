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
      restore_project_dir(previous_root)
      restore_app_env(previous_env)

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

  test "a failed connection remains visible in cockpit results", context do
    snapshot = put_in(context.snapshot, ["operations", "connect", "state"], "errored")
    :ok = Store.save(context.directory, snapshot)
    assert DesktopSetupResults.load(context.project_id) == snapshot
  end

  defp restore_project_dir(nil), do: System.delete_env("CMS_PROJECT_DIR")
  defp restore_project_dir(value), do: System.put_env("CMS_PROJECT_DIR", value)

  defp restore_app_env(nil), do: Application.delete_env(:code_my_spec, :env)
  defp restore_app_env(value), do: Application.put_env(:code_my_spec, :env, value)
end
