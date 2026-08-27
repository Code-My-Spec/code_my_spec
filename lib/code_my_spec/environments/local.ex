defmodule CodeMySpec.Environments.Local do
  @moduledoc "Local filesystem environment implementation."
  @behaviour CodeMySpec.Environments.EnvironmentsBehaviour

  alias CodeMySpec.Environments.Environment

  @impl true
  def create(opts) do
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    {:ok, %Environment{type: :local, cwd: working_dir}}
  end

  @impl true
  def destroy(_env), do: :ok

  @impl true
  def read_file(env, path) do
    resolved_path = resolve_path(path, env.cwd)
    File.read(resolved_path)
  end

  @impl true
  def list_directory(env, path) do
    resolved_path = resolve_path(path, env.cwd)
    File.ls(resolved_path)
  end

  @impl true
  def write_file(env, path, content) do
    resolved_path = resolve_path(path, env.cwd)

    with :ok <- File.mkdir_p(Path.dirname(resolved_path)) do
      File.write(resolved_path, content)
    end
  end

  @impl true
  def delete_file(env, path) do
    resolved_path = resolve_path(path, env.cwd)

    case File.rm(resolved_path) do
      :ok -> :ok
      # File doesn't exist, that's fine
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def file_exists?(env, path) do
    resolved_path = resolve_path(path, env.cwd)
    File.exists?(resolved_path)
  end

  @impl true
  def stat(env, path) do
    resolved_path = resolve_path(path, env.cwd)

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

  @impl true
  def ensure_dir(env, path) do
    resolved_path = resolve_path(path, env.cwd)
    File.mkdir_p(resolved_path)
  end

  @impl true
  def glob(env, pattern) do
    resolved_pattern = resolve_path(pattern, env.cwd)
    Path.wildcard(resolved_pattern)
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
  def cmd(%Environment{cwd: nil}, command, _args, _opts) when command != "ssh" do
    raise ArgumentError,
          "cannot run #{inspect(command)}: this environment has no working directory, " <>
            "and running it wherever the caller happens to be would analyse the wrong " <>
            "project. Build the environment with an explicit cwd."
  end

  def cmd(%Environment{cwd: cwd}, command, args, opts) do
    # The environment's cwd is the default working directory — that is what
    # makes this the environment's command rather than an ambient one. An
    # explicit :cd still wins, for callers operating on a path outside the
    # project root.
    opts = if cwd, do: Keyword.put_new(opts, :cd, cwd), else: opts

    # Append clean_otp_env LAST so it wins: clears the Burrito release's
    # ROOTDIR/BINDIR/RELEASE_* that would otherwise make a child mix/erl boot
    # from our extracted ERTS ("cannot get bootfile") instead of the user's OTP.
    opts = CodeMySpec.Environments.merge_clean_env(opts)

    case System.cmd(command, args, opts) do
      {output, 0} -> {clean_terminal_output(output), 0}
      {output, exit_code} -> {clean_terminal_output(output), exit_code}
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
    case String.valid?(text) do
      true ->
        text

      false ->
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
  # Unreachable now that `Scope.resolve_environment/2` returns nil rather than a
  # directoryless environment. Kept loud so that if some other path builds one,
  # it says so instead of writing into the server's repository.
  defp resolve_path(path, nil) do
    if Path.type(path) == :relative do
      raise ArgumentError,
            "cannot resolve the relative path #{inspect(path)}: this environment has " <>
              "no working directory, so the path would resolve against the current " <>
              "process's directory — on a server, its own checkout"
    else
      path
    end
  end

  defp resolve_path(path, working_dir) do
    if Path.type(path) == :relative do
      Path.join(working_dir, path) |> Path.absname()
    else
      path
    end
  end
end
