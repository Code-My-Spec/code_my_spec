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

  def non_elixir_project do
    root = Path.join(System.tmp_dir!(), "invalid-project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "index.html"), "<h1>Site</h1>")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  def directory_contents(root),
    do: Map.new(File.ls!(root), &{&1, File.read!(Path.join(root, &1))})
end
