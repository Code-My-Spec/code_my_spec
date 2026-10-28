defmodule CodeMySpec.TempFile do
  @moduledoc """
  Paths under the shared temp directory that no other process will pick.

  `System.unique_integer/1` is unique **within one BEAM**. `System.tmp_dir!/0`
  is shared by every process on the machine. Combining them gives a name that
  looks unique and is not: two OS processes each start the counter fresh, so
  two suites — or a suite and the harness's analyzers — generate
  `compile_diagnostics_7.jsonl` at the same time and one reads the other's file.

  That is not hypothetical and it is not only a test problem. It presented as
  `analysis_test.exs:173` failing with "diagnostics came back for a project with
  no :diagnostics compiler", three times in one night, on a project that has no
  compiler capable of writing them. The diagnostics it read belonged to another
  process's project. In production the same collision means one project's
  analyzer reporting another project's problems.

  It is also the third instance of one bug class here. Issue `0bc611c9` records
  the other two: a repo pool naming directories from a per-GenServer counter so
  two suites both handed out `pool_code_repo_1`, and a fake upstream picking its
  port with `Enum.random/1`. Same mistake each time — a name unique in one
  process treated as unique on the machine.

  So the token carries the OS pid as well, which is unique across processes by
  definition, plus random bytes so a pid recycled after a crash cannot collide
  with its predecessor's leftovers.

  A leaf boundary of its own, like `ExecutionContexts` and `Repo`, because the
  callers that most need it are outside `CodeMySpec`: the spex suite and the
  harness's test support both build temp paths, and both are top-level
  boundaries that cannot reach in here. The alternative was each of them
  keeping its own copy of the token — which is how there came to be three
  instances of the bug in the first place.
  """

  use Boundary, top_level?: true, deps: []

  @doc """
  A temp file path: `<tmp>/<prefix>_<token><suffix>`.

      iex> path = CodeMySpec.TempFile.path("compile_diagnostics", ".jsonl")
      iex> String.ends_with?(path, ".jsonl")
      true

      iex> CodeMySpec.TempFile.path("x") == CodeMySpec.TempFile.path("x")
      false
  """
  @spec path(String.t(), String.t()) :: String.t()
  def path(prefix, suffix \\ "") do
    Path.join(System.tmp_dir!(), "#{prefix}_#{token()}#{suffix}")
  end

  @doc """
  A temp directory path, hyphenated to match the existing `cms-ssh-…` style.

  Does not create it — callers that need it on disk still `mkdir_p`, and callers
  handing the path to something that creates it should not.
  """
  @spec dir(String.t()) :: String.t()
  def dir(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{token()}")
  end

  @doc """
  A temp directory that is removed when the process that asked for it exits.

  The replacement for `Briefly.create(directory: true)`, whose single `Entry`
  GenServer every caller went through with a hardcoded 5-second
  `GenServer.call` — so on a loaded machine the most-used test fixture in the
  suite failed on a timeout that had nothing to do with the code under test.

  Cleanup is keyed on the *caller's* exit rather than on an `ExUnit` callback,
  which is the part that matters and the part I got wrong first. `on_exit/1`
  raises "callback can only be invoked from the test process", and several
  callers here are not it — `InProcessAgentTransport.host_repository/0` runs
  inside a LiveView channel, reached from application code under test. Briefly
  worked there because a process monitor does not care who is asking.

  A monitor per directory rather than one process for all of them, deliberately:
  a shared owner is a shared mailbox, and a shared mailbox is what this replaced.
  """
  @spec owned_dir(String.t()) :: String.t()
  def owned_dir(prefix) do
    dir = dir(prefix)
    File.mkdir_p!(dir)
    owner = self()

    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        {:DOWN, ^ref, :process, ^owner, _reason} -> File.rm_rf(dir)
      end
    end)

    dir
  end

  @doc """
  Remove a temp file, quietly, if it exists.

  Was two copies (`CodeMySpec.StaticAnalysis.Analyzers.Credo` and `.Sobelow`),
  one of them missing the tmp-dir boundary check the other had. One
  implementation now, with the check: only ever removes a path actually under
  `System.tmp_dir!/0`, so a caller that passes something else by mistake
  cannot turn this into an arbitrary `rm`.

  `rescue`s because deleting a file that raced another cleanup, or sits on a
  filesystem this process can't touch, is not this caller's problem — the
  temp file is scratch space, not state anything depends on existing.
  """
  @spec cleanup(String.t()) :: :ok
  def cleanup(path) when is_binary(path) do
    tmp_dir = System.tmp_dir!()

    if String.starts_with?(Path.expand(path), tmp_dir) and File.exists?(path) do
      File.rm(path)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Removes `prefix`-tagged directories under the system temp dir that are
  older than `max_age_ms`.

  The backstop for `dir/1` and `owned_dir/1`: both clean up by running code
  in the process that asked for the directory, which never gets a turn when
  that process -- or the host it runs on -- is killed outright rather than
  exited. `/tmp` is shared by every process on the machine, so this only
  removes what has clearly outlived any real run rather than anything not
  immediately recognizable as its own; a directory still legitimately in use
  is nowhere near `max_age_ms` old. Same shape as
  `CodeMySpec.Provisioning.BurstBox.Sweep`: list by name, judge each by age,
  act, needing no cooperation from whatever created it.
  """
  @spec sweep_stale(String.t(), non_neg_integer()) :: :ok
  def sweep_stale(prefix, max_age_ms) do
    tmp_dir = System.tmp_dir!()
    cutoff_s = System.os_time(:second) - div(max_age_ms, 1000)

    tmp_dir
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, prefix <> "-"))
    |> Enum.each(&sweep_entry(Path.join(tmp_dir, &1), cutoff_s))

    :ok
  end

  @doc """
  Removes temp entries whose creating OS process is gone and that are older
  than `max_age_ms`.

  `token/0` puts the creator's OS pid in every name this module hands out, so
  ownership is readable from the name: a test VM that halts with directories
  still owned (`owned_dir/1` cleans on its caller's `:DOWN`, which a halting VM
  never delivers) leaves entries no live process will remove. Run at the start
  of a suite, this clears them for every prefix at once. `live_pids` is the set
  of running OS pids; the age guard covers a pid recycled since.
  """
  @spec sweep_orphans(non_neg_integer(), MapSet.t(String.t())) :: non_neg_integer()
  def sweep_orphans(max_age_ms, live_pids \\ live_os_pids()) do
    tmp_dir = System.tmp_dir!()
    cutoff_s = System.os_time(:second) - div(max_age_ms, 1000)

    tmp_dir
    |> File.ls!()
    |> Enum.filter(&orphan_name?(&1, live_pids))
    |> Enum.count(&remove_if_stale(Path.join(tmp_dir, &1), cutoff_s))
  end

  defp orphan_name?(name, live_pids) do
    case Regex.run(~r/[-_](\d+)_\d+_[A-Za-z0-9_-]{12}/, name) do
      [_, pid] -> not MapSet.member?(live_pids, pid)
      _ -> false
    end
  end

  defp remove_if_stale(path, cutoff_s) do
    with {:ok, %File.Stat{mtime: mtime}} <- File.lstat(path, time: :posix),
         true <- mtime < cutoff_s,
         {:ok, _} <- File.rm_rf(path) do
      true
    else
      _ -> false
    end
  end

  defp live_os_pids do
    {out, 0} = System.cmd("ps", ["-Ao", "pid="])
    out |> String.split() |> MapSet.new()
  end

  defp sweep_entry(path, cutoff_s) do
    with {:ok, %File.Stat{type: :directory, mtime: mtime}} <- File.stat(path, time: :posix),
         true <- mtime < cutoff_s do
      File.rm_rf(path)
    end

    :ok
  end

  # The OS pid makes this unique across processes; `unique_integer` keeps it
  # unique within one; the random suffix covers a recycled pid meeting files an
  # earlier incarnation left behind. Any two of the three would nearly do — all
  # three cost nothing and this has now been got wrong three times.
  defp token do
    random = 9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    "#{System.pid()}_#{System.unique_integer([:positive])}_#{random}"
  end
end
