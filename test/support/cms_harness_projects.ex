defmodule CmsHarnessTest.Projects do
  @moduledoc """
  Throwaway working copies on disk.

  Real directories rather than an in-memory environment, because what these
  tests are about is a process that owns a disk.
  """

  @doc """
  A directory that looks enough like a CodeMySpec project to be served: a
  `config.yml` naming an id, a `lib/` and a `test/`.
  """
  def project_dir(opts \\ []) do
    id = Keyword.get(opts, :project_id, unique_id())

    root =
      Path.join(System.tmp_dir!(), "cms_harness_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, ".code_my_spec"))
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))

    if id do
      File.write!(
        Path.join(root, ".code_my_spec/config.yml"),
        "project_id: #{id}\naccount_id: 1\n"
      )
    end

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)

    %{root: root, id: id && to_string(id)}
  end

  @doc "A directory with no project identity at all."
  def anonymous_dir do
    root = Path.join(System.tmp_dir!(), "cms_harness_anon_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)
    root
  end

  def write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  @doc "Stop whatever subtree a test started, so the next one starts clean."
  def stop_project(root) do
    case Registry.lookup(CmsHarness.Registry, {:project, root}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(CmsHarness.ProjectSupervisor, pid)
      [] -> :ok
    end
  end

  defp unique_id, do: System.unique_integer([:positive])
end
