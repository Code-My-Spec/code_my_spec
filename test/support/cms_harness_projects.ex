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

    # Every working copy carries the id the server issued it. Hooks are
    # addressed to that id, so a fixture without one is not a checkout the
    # harness can be asked about.
    harness_id = Keyword.get(opts, :harness_id, Ecto.UUID.generate())

    if harness_id do
      :ok =
        CmsHarness.HarnessConfig.write(root, %{
          harness_id: harness_id,
          project_id: id && to_string(id),
          root: root
        })
    end

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)

    %{root: root, id: id && to_string(id), harness_id: harness_id}
  end

  @doc """
  Start serving a working copy, the way a hook addressed to its id does.

  Nothing is configured with directories any more — the harness asks the server
  where a harness is. A test that wants a copy served starts its subtree
  directly, which is what that lookup ends in.
  """
  def serve(root) do
    CmsHarness.Projects.ensure_started(root)
    :ok
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
