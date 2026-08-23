defmodule CmsHarnessTest.Projects do
  @moduledoc """
  Throwaway working copies on disk.

  Real directories rather than an in-memory environment, because what these
  tests are about is a process that owns a disk.
  """

  @doc """
  Run a command in `root`, failing with its output rather than a `MatchError`.

  `{_, 0} = System.cmd("mix", ["deps.get"], …)` raises

      ** (MatchError) no match of right hand side value: {"…", 1}

  with the reason truncated inside a value nobody reads, in a `setup` whose
  failure is then reported against whichever test ran first. These shell out
  while three worktrees' suites and the harness's analyzers share the box, so
  they do fail — `0bc611c9` is four such tests, each of which "presents as a
  specific failure in a named file and reads as a real defect in code nobody
  touched", costing an investigation apiece.

  This does not make them pass. It makes the failure say what happened, which
  is the cost that issue is actually about.
  """
  def cmd!(root, command, args) do
    case System.cmd(command, args, cd: root, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        raise """
        #{command} #{Enum.join(args, " ")} exited #{status} in #{root}.

        This is the test's setup, not its subject. These commands share a
        machine with other suites and the harness's analyzers, so a failure
        here is often contention (a dependency cache, a build lock) rather
        than a defect — check whether it reproduces on an idle box before
        treating it as one.

        #{output}
        """
    end
  end

  @doc """
  A directory that looks enough like a CodeMySpec project to be served: a
  `config.yml` naming an id, a `lib/` and a `test/`.
  """
  def project_dir(opts \\ []) do
    id = Keyword.get(opts, :project_id, unique_id())

    root =
      CodeMySpec.TempFile.dir("cms_harness")

    File.mkdir_p!(Path.join(root, ".code_my_spec"))
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))

    # A working copy is onboarded; the analyzer only runs against one that is.
    # `TestDatabase.partition_for/1` reads the recorded partition and refuses a
    # copy with none — there is no derive-on-miss path, deliberately — so a
    # fixture standing in for a checkout records one too.
    File.mkdir_p!(Path.join(root, ".claude"))

    File.write!(
      Path.join([root, ".claude", "settings.local.json"]),
      Jason.encode!(%{
        "env" => %{"MIX_TEST_PARTITION" => "fixture#{System.unique_integer([:positive])}"}
      })
    )

    if id do
      File.write!(
        Path.join(root, ".code_my_spec/config.yml"),
        "project_id: #{id}\naccount_id: 1\n"
      )
    end

    # Every working copy carries the id the server issued it. Hooks are
    # addressed to that id, so a fixture without one is not a checkout the
    # harness can be asked about.
    working_copy_id = Keyword.get(opts, :working_copy_id, Ecto.UUID.generate())

    if working_copy_id do
      :ok =
        CmsHarness.HarnessConfig.write(root, %{
          working_copy_id: working_copy_id,
          project_id: id && to_string(id),
          root: root
        })
    end

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)

    %{root: root, id: id && to_string(id), working_copy_id: working_copy_id}
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
    root = CodeMySpec.TempFile.dir("cms_harness_anon")
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
