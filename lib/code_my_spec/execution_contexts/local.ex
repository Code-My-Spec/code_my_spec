defmodule CodeMySpec.ExecutionContexts.Local do
  @moduledoc "Local filesystem environment implementation."
  @behaviour CodeMySpec.ExecutionContexts.ExecutionContextsBehaviour

  alias CodeMySpec.DurableRun
  alias CodeMySpec.ExecutionContexts.ExecutionContext

  @impl true
  def create(opts) do
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    {:ok, %ExecutionContext{type: :local, cwd: working_dir}}
  end

  @impl true
  def destroy(_env), do: :ok

  @impl true
  def read_file(env, path) do
    with {:ok, resolved_path} <- resolve_path(path, env.cwd) do
      File.read(resolved_path)
    end
  end

  @impl true
  def list_directory(env, path) do
    with {:ok, resolved_path} <- resolve_path(path, env.cwd) do
      File.ls(resolved_path)
    end
  end

  @impl true
  def write_file(env, path, content) do
    with {:ok, resolved_path} <- resolve_path(path, env.cwd),
         :ok <- File.mkdir_p(Path.dirname(resolved_path)) do
      File.write(resolved_path, content)
    end
  end

  @impl true
  def delete_file(env, path) do
    with {:ok, resolved_path} <- resolve_path(path, env.cwd) do
      case File.rm(resolved_path) do
        :ok -> :ok
        # File doesn't exist, that's fine
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def file_exists?(env, path) do
    # No working directory is not evidence either way — the same rule every
    # caller of this already applies to a provider it could not reach, or a
    # file it could not open: absent, not a crash. `resolve_path/2` used to
    # raise here instead of answering that, which meant a harness-scoped
    # caller with no working directory (a real, ordinary case, not a bug)
    # took down whatever step asked rather than getting an honest "no".
    case resolve_path(path, env.cwd) do
      {:ok, resolved_path} -> File.exists?(resolved_path)
      {:error, :no_working_directory} -> false
    end
  end

  @impl true
  def stat(env, path) do
    with {:ok, resolved_path} <- resolve_path(path, env.cwd) do
      case File.stat(resolved_path, time: :posix) do
        {:ok, %File.Stat{type: :regular, size: size, mtime: mtime_posix}} ->
          # POSIX file times are second-precision; mark microsecond as :usec-set
          # so the Files.File schema (:utc_datetime_usec) accepts it.
          mtime = mtime_posix |> DateTime.from_unix!() |> Map.put(:microsecond, {0, 6})
          {:ok, %{mtime: mtime, size: size}}

        {:ok, _} ->
          {:error, :not_regular}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def ensure_dir(env, path) do
    with {:ok, resolved_path} <- resolve_path(path, env.cwd) do
      File.mkdir_p(resolved_path)
    end
  end

  @impl true
  def glob(env, pattern) do
    # No working directory means nothing to glob, not an error a caller
    # building a plain list of matches has anywhere to put — the same
    # "cannot prove it's there" answer `file_exists?/2` gives.
    case resolve_path(pattern, env.cwd) do
      {:ok, resolved_pattern} -> Path.wildcard(resolved_pattern)
      {:error, :no_working_directory} -> []
    end
  end

  @impl true
  def stream_files(env, roots, _opts \\ []) do
    # Same rule as `cmd/4`, and never reached without a cwd in the suite either
    # — globbing the caller's tree would answer about a different project's
    # files, which is worse than answering nothing.
    base = env.cwd || raise(ArgumentError, "this environment has no working directory to scan")

    existing =
      roots
      |> Enum.map(&Path.join(base, &1))
      |> Enum.filter(&File.exists?/1)

    case existing do
      [] ->
        Stream.map([], & &1)

      paths ->
        paths
        |> DirWalker.stream()
        |> Stream.map(&Path.relative_to(&1, base))
    end
  end

  @impl true
  def environment_setup_command(_env, %{}) do
    ""
  end

  @impl true
  def docs_environment_teardown_command(_env, %{
        context_name: context_name,
        context_type: context_type,
        working_dir: working_dir,
        design_file_name: design_file_name,
        branch_name: branch_name
      }) do
    """
    git -C #{working_dir} add #{design_file_name} && \
    git -C #{working_dir} commit -m "created #{context_type} design for #{context_name}" && \
    git -C #{working_dir} switch main && \
    git -C #{working_dir} merge #{branch_name}
    """
  end

  @impl true
  def test_environment_teardown_command(_env, %{
        context_name: context_name,
        working_dir: working_dir,
        test_file_name: test_file_name,
        branch_name: branch_name
      }) do
    """
    git -C #{working_dir} add #{test_file_name} && \
    git -C #{working_dir} commit -m "generated tests for #{context_name}" && \
    git -C #{working_dir} push -u origin #{branch_name} && \
    gh pr create --title "Add tests for #{context_name}" --body "Automated test generation for #{context_name} component"
    """
  end

  @impl true
  def code_environment_teardown_command(_env, %{
        context_name: context_name,
        working_dir: working_dir,
        code_file_name: code_file_name,
        test_file_name: test_file_name,
        branch_name: branch_name
      }) do
    """
    git -C #{working_dir} add #{code_file_name} #{test_file_name} && \
    git -C #{working_dir} commit -m "implemented #{context_name}" && \
    git -C #{working_dir} push -u origin #{branch_name} && \
    gh pr create --title "Implement #{context_name}" --body "Automated implementation of #{context_name} component"
    """
  end

  # Local runs commands on the same filesystem it reads, so the execution view
  # and the domain view are one filesystem.
  @impl true
  def exec_file_exists?(env, path), do: file_exists?(env, path)

  @impl true
  # An environment that does not know its directory must not borrow the
  # caller's. Without a cwd this left `:cd` unset, so `mix compile` ran wherever
  # the OS process happened to be — the developer's own checkout — and its
  # warnings were reconciled into whichever project the scope named. That is the
  # unexplained half of c8264c1f: a fixture whose cwd was a temp directory saw
  # 28 problems carrying absolute paths under the worktree, which a correctly
  # isolated run cannot produce.
  #
  # Measured before changing it: across 4,156 tests exactly one call reaches
  # here without a cwd, and it is `echo` in a test of the recorder. Nothing
  # relies on the fallback; it only waits.
  #
  # A caller that genuinely wants the ambient directory says so by building the
  # environment with it, which is one word longer and cannot happen by accident.
  #
  # `ssh` is exempt: `Remote.ssh_runner/2` builds it entirely from absolute
  # arguments (an identity file path, `root@<ip>`) and a command string that
  # runs in the *remote* shell's own directory — nothing about it resolves
  # against this process's cwd, so the "would analyse the wrong project"
  # rationale above cannot apply to it. Blocking it here meant :server (and
  # every other step that reaches a box only to run a remote command, not to
  # read a local checkout) could never succeed for a caller with no local
  # working directory — e.g. a project reached through the light harness.
  def cmd(%ExecutionContext{cwd: nil}, command, _args, _opts) when command != "ssh" do
    raise ArgumentError,
          "cannot run #{inspect(command)}: this environment has no working directory, " <>
            "and running it wherever the caller happens to be would analyse the wrong " <>
            "project. Build the environment with an explicit cwd."
  end

  def cmd(%ExecutionContext{cwd: cwd, metadata: metadata}, command, args, opts) do
    # The environment's cwd is the default working directory — that is what
    # makes this the environment's command rather than an ambient one. An
    # explicit :cd still wins, for callers operating on a path outside the
    # project root.
    opts = if cwd, do: Keyword.put_new(opts, :cd, cwd), else: opts

    # Append clean_otp_env LAST so it wins: clears the Burrito release's
    # ROOTDIR/BINDIR/RELEASE_* that would otherwise make a child mix/erl boot
    # from our extracted ERTS ("cannot get bootfile") instead of the user's OTP.
    opts = CodeMySpec.ExecutionContexts.merge_clean_env(opts)

    {capture, opts} = Keyword.pop(opts, :output_capture, Map.get(metadata, :output_capture))

    opts =
      if capture do
        Keyword.put(opts, :into, %CodeMySpec.ExecutionContexts.CommandOutput{device: capture})
      else
        opts
      end

    {output, exit_code} =
      case {Map.get(metadata, :durable_run), Map.get(metadata, :run_id)} do
        {id, _} when is_integer(id) -> durable_cmd(id, command, args, opts)
        {nil, id} when is_integer(id) -> guarded_cmd(command, args, opts)
        _ -> System.cmd(command, args, opts)
      end

    {clean_terminal_output(output), exit_code}
  end

  # Until the child formatter can publish a durable stream, an analyzer must
  # not keep running after an abrupt harness exit. This watcher is an OS process
  # in the port's process group, so it survives a killed BEAM long enough to
  # terminate that group. The birth time prevents a reused owner PID from
  # keeping an orphan alive.
  defp guarded_cmd(command, args, opts) do
    executable = System.find_executable(command) || raise("command not found: #{command}")
    owner = System.pid()

    {birth, 0} =
      System.cmd("/bin/ps", ["-o", "lstart=", "-p", owner], stderr_to_stdout: true)

    birth = String.trim(birth)

    script = """
    "$@" &
    child=$!
    (
      trap '' TERM
      while [ "$(/bin/ps -o lstart= -p "$CMS_RUN_OWNER" 2>/dev/null | /usr/bin/xargs)" = "$CMS_RUN_OWNER_BIRTH" ]; do
        /bin/kill -0 "$child" 2>/dev/null || exit 0
        /bin/sleep 1
      done
      /bin/kill -TERM -- "-$$" 2>/dev/null
      /bin/sleep 2
      /bin/kill -KILL -- "-$$" 2>/dev/null
    ) >/dev/null 2>&1 &
    watcher=$!
    wait "$child"
    status=$?
    wait "$watcher" 2>/dev/null
    exit "$status"
    """

    env =
      [{"CMS_RUN_OWNER", owner}, {"CMS_RUN_OWNER_BIRTH", birth} | Keyword.get(opts, :env, [])]

    System.cmd(
      "/bin/sh",
      ["-c", script, "guarded-run", executable | args],
      Keyword.put(opts, :env, env)
    )
  end

  # A durable test must keep its output descriptor after this BEAM disappears.
  # The shell execs the real command after redirecting both streams to a file,
  # so the same OS pid can be verified and adopted by the next harness.
  defp durable_cmd(id, command, args, opts) do
    output_path = DurableRun.output_path(id)
    File.write!(output_path, "")
    executable = System.find_executable(command) || raise("command not found: #{command}")

    shell =
      "\"$@\" >\"$CMS_RUN_OUTPUT\" 2>&1; status=$?; printf '%s\\n' \"$status\" >\"$CMS_RUN_EXIT\"; exit \"$status\""

    env =
      [
        {"CMS_RUN_OUTPUT", output_path},
        {"CMS_RUN_EXIT", DurableRun.exit_path(id)} | Keyword.get(opts, :env, [])
      ]
      |> Enum.map(fn {key, value} ->
        {String.to_charlist(key), if(is_nil(value), do: false, else: String.to_charlist(value))}
      end)

    port =
      Port.open({:spawn_executable, ~c"/bin/sh"}, [
        :binary,
        :exit_status,
        args: Enum.map(["-c", shell, "durable-run", executable | args], &String.to_charlist/1),
        cd: opts[:cd] |> String.to_charlist(),
        env: env
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    DurableRun.attach_pid(id, pid)
    status = await_durable_exit(port)
    output = File.read!(output_path)

    case opts[:into] do
      %{device: capture} -> IO.binwrite(capture, output)
      _ -> :ok
    end

    {output, status}
  end

  defp await_durable_exit(port) do
    receive do
      {^port, {:exit_status, status}} -> status
      {^port, {:data, _data}} -> await_durable_exit(port)
    end
  end

  # ANSI and UTF-8, and not trimming. `2f6695dd`.
  #
  # The trim was there for the reason the behaviour doc gives — output "bound
  # for a database and a JSON response" — but that reason covers the other two
  # steps and not this one. Postgres and JSON both hold a trailing newline
  # perfectly well; invalid UTF-8 is what crashes an MCP session.
  #
  # And it made this implementation disagree with `Container.cmd/4`, which
  # returns `System.cmd`'s output verbatim, so the same parser was correct in
  # one environment and wrong in the other with nothing to say which.
  #
  # What it cost concretely: for `git status --porcelain` the leading space is
  # the staged-status column, blank for modified-but-not-staged. Trimming took
  # it off the first line only, so the same buffer parsed two different ways
  # depending on which file git listed first. Callers wanting a trimmed string
  # can trim, and several already did on top of this.
  defp clean_terminal_output(output) do
    output
    |> remove_ansi_codes()
    |> ensure_valid_utf8()
  end

  # Remove ANSI escape codes (colors, formatting, etc.)
  defp remove_ansi_codes(text) do
    String.replace(text, ~r/\x1b\[[0-9;]*m/, "")
  end

  # Ensure the string contains only valid UTF-8 characters
  defp ensure_valid_utf8(text) do
    text
    |> remove_null_bytes()
    |> remove_control_characters()
    |> ensure_printable_utf8()
  end

  # Remove null bytes that PostgreSQL can't handle
  defp remove_null_bytes(text) do
    String.replace(text, <<0>>, "")
  end

  # Remove other problematic control characters
  defp remove_control_characters(text) do
    # Remove control characters except for common ones like \n, \t, \r
    String.replace(text, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
  end

  # Ensure we have valid printable UTF-8
  defp ensure_printable_utf8(text) do
    if String.valid?(text) do
      text
    else
      # Force conversion to valid UTF-8, replacing invalid sequences
      text
      |> :unicode.characters_to_binary(:latin1, :utf8)
      |> case do
        binary when is_binary(binary) -> binary
        # If all else fails, return empty string
        _ -> ""
      end
    end
  end

  # Resolve path relative to working_dir if it's a relative path
  # A relative path against no working directory is not "relative to nothing" —
  # `File.read/1` and `File.write/2` resolve it against whatever directory this
  # OS process is in, which on a server is its own checkout. Returning the path
  # unchanged is what made that silent.
  #
  # `{:error, :no_working_directory}`, not a raise. This used to raise on the
  # theory that a directoryless environment reaching here was a coding
  # mistake nothing should actually trigger — `LocalScope.resolve_execution_context/2`
  # was supposed to return `nil` first. It is not a mistake: a harness-scoped
  # caller with no local checkout is an ordinary, expected case (a project
  # reached through the light harness, e.g.), and every caller of this
  # already has a well-defined, non-crashing answer for "cannot resolve" —
  # `false` for `file_exists?/2`, `[]` for `glob/2`, a clean `{:error, ...}`
  # everywhere else. Raising meant that answer never got the chance to run:
  # the exception unwound straight past whatever `with`, `case`, or `Enum`
  # was structured to handle a clean error, and was only ever caught by
  # whichever top-level rescue happened to sit above it — which, on the run
  # side, aborted an entire multi-environment step (every environment, not
  # just the one whose write this was) rather than just this one operation.
  # Found live against MarketMySpec, twice: once on the read side
  # (`database_url_present?/2`) and once on the write side (`put_secret/4`),
  # each needing its own rescue before this fix existed to make either
  # unnecessary.
  defp resolve_path(path, nil) do
    if Path.type(path) == :relative do
      {:error, :no_working_directory}
    else
      {:ok, path}
    end
  end

  defp resolve_path(path, working_dir) do
    if Path.type(path) == :relative do
      {:ok, Path.join(working_dir, path) |> Path.absname()}
    else
      {:ok, path}
    end
  end
end
