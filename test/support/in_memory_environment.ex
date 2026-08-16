defmodule CodeMySpec.Support.InMemoryEnvironment do
  @moduledoc """
  Environment implementation backed by an in-memory file store.

  Intended for BDD specs that need the real code path (file sync, component
  sync, compile diagnostics) to run without touching the real filesystem.

  Each `create/1` call spawns an isolated Agent keyed by the returned env's
  `ref`. State is `%{path => {content, mtime}}` where `path` is always canonical
  and relative to `env.cwd`. `mtime` is set to the current time on every write
  so that `stat/2` returns a monotonically-advancing timestamp — enough for
  `FileSync.sync_changed/2` to detect updates within a spec run.

  Not a substitute for `RecordingEnvironment` — that records real CLI
  commands, this isolates tests from the filesystem.
  """

  @behaviour CodeMySpec.Environments.EnvironmentsBehaviour

  alias CodeMySpec.Environments.Environment

  @impl true
  def create(opts \\ []) do
    {:ok, agent} = Agent.start_link(fn -> %{} end)
    working_dir = Keyword.get(opts, :working_dir, "/memfs")

    {:ok,
     %Environment{
       type: :memory,
       cwd: working_dir,
       ref: %{agent: agent},
       metadata: Keyword.get(opts, :metadata, %{})
     }}
  end

  # Stop it, and be satisfied if it was already stopping.
  #
  # `if Process.alive?(agent), do: Agent.stop(agent)` is check-then-act, and the
  # gap is reachable here by construction: the agent is `start_link`ed from the
  # test process, while `destroy/1` runs from `on_exit` in a *different* process
  # after that one has exited — so the link is killing the agent exactly when
  # destroy looks at it. Winning the check and losing the stop produced
  #
  #     ** (exit) exited in: GenServer.stop(#PID<0.11022.0>, :normal, :infinity)
  #
  # reported against whichever test was running. Forty isolated runs of that
  # file stay clean; it takes a loaded box, which is where the analyzer lives.
  #
  # Two shapes that look simpler and are wrong, both tried:
  #
  #   * `Process.exit(agent, :shutdown)` — an abnormal signal travels back along
  #     the link and takes the *caller* with it. `** (EXIT from #PID<...>)
  #     shutdown`, which is a louder version of the bug being fixed.
  #   * `Process.unlink/1` then `Process.exit(agent, :kill)` — unlink only
  #     touches the caller's own link. Called from `on_exit`, or from any
  #     process that did not create the agent, the owner's link survives and the
  #     kill propagates to it instead.
  #
  # So: `Agent.stop/1`, which exits with `:normal` and therefore propagates to
  # nobody. It raises on a process that is already gone, and that is not an
  # error to report — it is the outcome this function exists to produce. There
  # is no error-tuple form of `GenServer.stop/3` to prefer; an exit *is* the
  # contract. The monitor afterwards is what makes the promise good: this
  # returns only once the agent is actually down, whichever way it got there.
  @impl true
  def destroy(%Environment{ref: %{agent: agent}}) do
    ref = Process.monitor(agent)

    try do
      Agent.stop(agent)
    catch
      :exit, _reason -> :ok
    end

    receive do
      {:DOWN, ^ref, :process, ^agent, _reason} -> :ok
    after
      5_000 ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  @doc """
  Run a command for real, unless a spex has asked for a modelled shell.

  This environment fakes the *filesystem*, not the shell — those are separate
  seams and both already exist. Specs that must not shell out wrap the call in
  `use_cmd_cassette`, which meck-patches `System.cmd/3` itself, so replay works
  underneath this delegation exactly as it did when callers invoked System.cmd
  directly.

  Returning an error here instead would break every cassette-driven spec, and
  would do it by making the memory environment claim authority over something
  it does not model.

  The `:memory_shell` escape exists because a cassette cannot model a command's
  *effect*. `ssh-keygen -f path` writes a key, and on replay the recorded
  stdout comes back while no file appears — so a later step reading that path
  diverges from the run that was recorded, which is why 963/7965 records green
  and replays red. A modelled shell writes into this environment's own
  filesystem, so the effect is there for the next command to find.

  Off by default: nothing changes for anything that has not opted in.
  """
  @impl true
  def cmd(env, command, args, opts) do
    case Application.get_env(:code_my_spec, :memory_shell) do
      nil -> CodeMySpec.Environments.Local.cmd(env, command, args, opts)
      module -> module.cmd(env, command, args, opts)
    end
  end

  # Execution is delegated to Local, so the execution filesystem is Local's
  # — the memfs fakes reads, not the shell.
  @impl true
  defdelegate exec_file_exists?(env, path), to: CodeMySpec.Environments.Local

  @impl true
  def read_file(%Environment{} = env, path) do
    key = normalize(path, env.cwd)

    case Agent.get(agent(env), &Map.get(&1, key)) do
      nil -> {:error, :enoent}
      {content, _mtime} -> {:ok, content}
    end
  end

  @impl true
  def write_file(%Environment{} = env, path, content) do
    key = normalize(path, env.cwd)
    mtime = DateTime.utc_now()
    Agent.update(agent(env), &Map.put(&1, key, {content, mtime}))
    :ok
  end

  @impl true
  def stat(%Environment{} = env, path) do
    key = normalize(path, env.cwd)

    case Agent.get(agent(env), &Map.get(&1, key)) do
      nil -> {:error, :enoent}
      {content, mtime} -> {:ok, %{mtime: mtime, size: byte_size(content)}}
    end
  end

  @impl true
  def delete_file(%Environment{} = env, path) do
    key = normalize(path, env.cwd)
    Agent.update(agent(env), &Map.delete(&1, key))
    :ok
  end

  @impl true
  def file_exists?(%Environment{} = env, path) do
    key = normalize(path, env.cwd)
    dir_prefix = if key == "", do: "", else: key <> "/"

    Agent.get(agent(env), fn state ->
      Map.has_key?(state, key) or
        Enum.any?(state, fn {k, _} -> String.starts_with?(k, dir_prefix) end)
    end)
  end

  @impl true
  def list_directory(%Environment{} = env, path) do
    # Strip trailing slash so callers using either `"test/journeys"` or
    # `"test/journeys/"` (e.g. the requirement-calculator path_prefix)
    # both resolve to the same key. Production File.ls handles either
    # form natively; this matches.
    key = path |> String.trim_trailing("/") |> normalize(env.cwd)
    prefix = if key == "", do: "", else: key <> "/"

    children =
      agent(env)
      |> Agent.get(& &1)
      |> Map.keys()
      |> Enum.flat_map(fn k ->
        cond do
          prefix == "" ->
            [k |> String.split("/") |> hd()]

          String.starts_with?(k, prefix) ->
            [String.replace_prefix(k, prefix, "") |> String.split("/") |> hd()]

          true ->
            []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    # `{:error, :enoent}` for a path with nothing under it, because that is what
    # `File.ls` answers and callers branch on it. Returning `{:ok, []}` made
    # every directory exist: `HexDocProjector.dir?/2` is
    # `match?({:ok, _}, list_directory(...))`, so an uninstalled package still
    # looked installed, nothing was ever an orphan, and five deletion tests
    # failed while the projector reported success.
    #
    # A directory with no files cannot be told from one that was never created
    # in a map keyed by file path, and that is the right trade: the analyzers
    # this stands in for ask "is there anything here", never "does an empty
    # directory exist".
    case children do
      [] -> {:error, :enoent}
      _ -> {:ok, children}
    end
  end

  @impl true
  def glob(%Environment{} = env, pattern) do
    normalized = normalize(pattern, env.cwd)
    regex = compile_glob(normalized)

    agent(env)
    |> Agent.get(& &1)
    |> Map.keys()
    |> Enum.filter(&Regex.match?(regex, &1))
    |> Enum.sort()
  end

  @impl true
  def ensure_dir(_env, _path), do: :ok

  @impl true
  def stream_files(%Environment{} = env, roots, _opts \\ []) do
    normalized_roots = Enum.map(roots, &normalize(&1, env.cwd))

    agent(env)
    |> Agent.get(& &1)
    |> Map.keys()
    |> Enum.filter(fn path ->
      Enum.any?(normalized_roots, fn root ->
        path == root or String.starts_with?(path, root <> "/")
      end)
    end)
    |> Enum.sort()
    |> Stream.map(& &1)
  end

  @impl true
  def environment_setup_command(_env, _attrs), do: ""

  @impl true
  def docs_environment_teardown_command(_env, _attrs), do: ""

  @impl true
  def test_environment_teardown_command(_env, _attrs), do: ""

  @impl true
  def code_environment_teardown_command(_env, _attrs), do: ""

  # -- Helpers --

  defp agent(%Environment{ref: %{agent: pid}}), do: pid

  defp normalize(path, nil), do: strip_dot_slash(path)

  defp normalize(path, cwd) do
    cond do
      path == cwd -> ""
      String.starts_with?(path, cwd <> "/") -> String.replace_prefix(path, cwd <> "/", "")
      true -> strip_dot_slash(path)
    end
  end

  # Only strip `./` prefixes. Leading `/` is preserved — callers should pass
  # either a path relative to `cwd` or a path rooted at `cwd`. Stripping
  # arbitrary absolute paths would silently alias `/other/foo.ex` into
  # `other/foo.ex` in the store.
  defp strip_dot_slash("./" <> rest), do: rest
  defp strip_dot_slash(path), do: path

  defp compile_glob(pattern) do
    # Escape regex specials, then swap ** → .* and * → [^/]*.
    # ** must be translated before * so we don't double-substitute.
    #
    # `**/` is its own case, and getting it wrong is silent. `Path.wildcard`
    # matches *zero* or more segments there, so `lib/**/*.ex` finds
    # `lib/foo.ex` as well as `lib/a/b.ex`. Translating it as `.*/` requires a
    # subdirectory, so a package whose sources sit directly in `lib/` globs to
    # nothing — the caller sees an empty list, which is indistinguishable from
    # a directory that really is empty. `HexDocProjector` projected zero
    # modules that way, and reported `:ok` doing it.
    pattern
    |> Regex.escape()
    |> String.replace("\\*\\*/", "\x01")
    |> String.replace("\\*\\*", "\x00")
    |> String.replace("\\*", "[^/]*")
    |> String.replace("\x01", "(?:.*/)?")
    |> String.replace("\x00", ".*")
    |> then(&"^#{&1}$")
    |> Regex.compile!()
  end
end
