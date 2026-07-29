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

  @impl true
  def destroy(%Environment{ref: %{agent: agent}}) do
    if Process.alive?(agent), do: Agent.stop(agent)
    :ok
  end

  @doc """
  Run a command for real.

  This environment fakes the *filesystem*, not the shell — those are separate
  seams and both already exist. Specs that must not shell out wrap the call in
  `use_cmd_cassette`, which meck-patches `System.cmd/3` itself, so replay works
  underneath this delegation exactly as it did when callers invoked System.cmd
  directly.

  Returning an error here instead would break every cassette-driven spec, and
  would do it by making the memory environment claim authority over something
  it does not model.
  """
  # Execution is delegated to Local, so the execution filesystem is Local's
  # — the memfs fakes reads, not the shell.
  @impl true
  defdelegate exec_file_exists?(env, path), to: CodeMySpec.Environments.Local

  @impl true
  defdelegate cmd(env, command, args, opts), to: CodeMySpec.Environments.Local

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
          prefix == "" -> [k |> String.split("/") |> hd()]
          String.starts_with?(k, prefix) -> [String.replace_prefix(k, prefix, "") |> String.split("/") |> hd()]
          true -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    {:ok, children}
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
    pattern
    |> Regex.escape()
    |> String.replace("\\*\\*", "\x00")
    |> String.replace("\\*", "[^/]*")
    |> String.replace("\x00", ".*")
    |> then(&"^#{&1}$")
    |> Regex.compile!()
  end
end
