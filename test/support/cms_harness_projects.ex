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
    if harness_id, do: File.write!(Path.join(root, ".cms_harness_id"), harness_id <> "\n")

    # The copies a harness serves are its configuration. Without this the id
    # resolves to nothing, which is exactly what an unonboarded checkout does.
    serve(root)

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)

    %{root: root, id: id && to_string(id), harness_id: harness_id}
  end

  @doc """
  Add a root to the copies this harness serves, for the duration of the test.

  Mirrors `CMS_PROJECT_DIRS` without touching the environment, which is global
  to the VM and would leak between tests.
  """
  def serve(root) do
    previous = Application.get_env(:code_my_spec, :harness_project_dirs, [])
    Application.put_env(:code_my_spec, :harness_project_dirs, [root | List.wrap(previous)])

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :harness_project_dirs, previous)
    end)
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
