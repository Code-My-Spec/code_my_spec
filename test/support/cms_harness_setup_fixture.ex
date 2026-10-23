defmodule CmsHarnessTest.SetupFixture do
  @moduledoc "Explicit provisioning actions for acceptance specs, independent of desktop startup."
  defdelegate check_prerequisites(opts), to: CmsHarness.Setup
  defdelegate status(opts), to: CmsHarness.Setup
  defdelegate connect_project(path, identity, opts), to: CmsHarness.Setup
  defdelegate agent_installations(root), to: CmsHarness.Setup.Prerequisites

  def isolated_history do
    root = Path.join(System.tmp_dir!(), "setup-history-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = System.get_env("PATH")
    System.put_env("PATH", root)

    ExUnit.Callbacks.on_exit(fn ->
      System.put_env("PATH", previous)
      File.rm_rf!(root)
    end)

    [directory: Path.join(root, "results")]
  end

  def persisted_result(snapshot), do: snapshot["results_path"] |> File.read!() |> Jason.decode!()
end
