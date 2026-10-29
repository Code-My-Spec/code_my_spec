defmodule CmsHarness.SopsKeySocket do
  @moduledoc """
  Serves this box's in-memory sops age key (`CmsHarness.SopsKeyring`) over a
  Unix domain socket, and nowhere else — never HTTP, never a file (story
  1132).

  The socket lives at `~/.codemyspec/run/key.sock`, in a `0700` directory
  with the socket itself `0600`: Unix enforces both at `connect()`, so no
  other user on the box can even reach the path. `cms sops-key`
  (`CmsHarness.Cli.SopsKey`) is the one client; `sops` runs it via
  `SOPS_AGE_KEY_CMD` and reads the key off its stdout.

  A connecting client reports its own pid and uid as the wire protocol's
  first line (`"<pid> <uid>\\n"`) — Erlang's `:socket` module exposes no
  `SO_PEERCRED`/`LOCAL_PEERCRED` equivalent on every platform this runs on
  (confirmed unsupported on this build's macOS target; `:socket.supports/2`
  reports `peercred: false` there), so there is no OS-level credential to
  read instead. The directory/socket permissions above are the real
  boundary against *another user*; this self-report only decides whether
  *this* user's request came through `sops` — advisory, not a security
  boundary, matching this story's own accepted caveat that no scheme hides
  a dev-only, rotatable secret from code already running as the box's user.
  """

  require Logger

  alias CmsHarness.SopsKeyring

  @doc "The directory the socket lives in."
  @spec dir() :: Path.t()
  def dir do
    state_dir = CmsHarness.Config.local_state_dir()
    long_dir = Path.join(state_dir, "run")

    if byte_size(Path.join(long_dir, "key.sock")) < 100 do
      long_dir
    else
      # Unix socket paths are limited by sockaddr_un even when HOME is valid.
      # Keep the private directory stable for both the harness and cms client.
      # /tmp is short even on macOS, where TMPDIR can live under a long HOME.
      digest =
        :crypto.hash(:sha256, state_dir) |> Base.encode16(case: :lower) |> binary_part(0, 32)

      Path.join("/tmp", "cms-sops-#{digest}")
    end
  end

  @doc """
  The socket path itself.

  `CMS_SOPS_KEY_SOCKET_PATH`, if set, wins over the real default. Nothing
  in production ever sets it (there is exactly one harness per machine,
  so the well-known default is the only path any client needs); a test
  suite running several independent harnesses at once in the same OS
  environment (`mix cms.spex`'s own shards, each a separate process on
  this machine) is the only caller that does, and only on itself, so its
  own later-spawned `sops`/`cms sops-key` subprocesses inherit the one
  this process's own harness actually bound -- never a sibling shard's.
  """
  @spec path() :: Path.t()
  def path do
    System.get_env("CMS_SOPS_KEY_SOCKET_PATH") || Path.join(dir(), "key.sock")
  end

  @doc "This module's own child spec — `start_link/1` does the real work, including the post-bind chmod."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Starts the listener and chmods the socket file to 0600 once it exists."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    # Erlang has no Unix domain sockets on Windows (`:eafnosupport`); without
    # this the whole harness failed to start there.
    if match?({:win32, _}, :os.type()) do
      Logger.warning(
        "[CmsHarness] no sops key socket on Windows: dev secrets are not served here"
      )

      :ignore
    else
      listen(opts)
    end
  end

  defp listen(opts) do
    socket_path = Keyword.get(opts, :path, path())
    prepare_path!(socket_path)

    thousand_island_opts = [
      port: 0,
      transport_module: ThousandIsland.Transports.TCP,
      transport_options: [ip: {:local, socket_path}],
      handler_module: CmsHarness.SopsKeySocket.Handler,
      handler_options: %{owner_uid: owner_uid(), socket_path: socket_path},
      num_acceptors: 1
    ]

    case ThousandIsland.start_link(thousand_island_opts) do
      {:ok, pid} ->
        await_socket_file!(socket_path)
        File.chmod!(socket_path, 0o600)
        {:ok, pid}

      other ->
        other
    end
  end

  defp prepare_path!(socket_path) do
    socket_dir = Path.dirname(socket_path)
    File.mkdir_p!(socket_dir)
    File.chmod!(socket_dir, 0o700)
    # A stale socket from a prior, uncleanly-stopped harness fails bind/2
    # with eaddrinuse if left in place.
    File.rm(socket_path)
    :ok
  end

  defp await_socket_file!(socket_path, attempts \\ 50) do
    cond do
      File.exists?(socket_path) ->
        :ok

      attempts <= 0 ->
        raise "the sops key socket never appeared at #{socket_path}"

      true ->
        Process.sleep(20)
        await_socket_file!(socket_path, attempts - 1)
    end
  end

  @doc """
  Decides the response for a request line and logs it. Called by
  `CmsHarness.SopsKeySocket.Handler`, kept out of it so the decision logic
  is testable without a real socket.

  `owner_uid` is this harness process's own uid — compared against the
  caller's self-reported uid, the same advisory check as the parent-process
  one (see the moduledoc).
  """
  @spec respond(String.t(), non_neg_integer() | nil) :: {:ok, [String.t()]} | {:error, String.t()}
  def respond(line, owner_uid) do
    case parse_request(line) do
      {:ok, pid, uid} -> decide(pid, uid, owner_uid)
      :error -> log_and_return(nil, {:error, "malformed request"})
    end
  end

  defp decide(pid, uid, owner_uid) do
    cond do
      is_integer(owner_uid) and uid != owner_uid ->
        log_and_return(pid, {:error, "wrong user"})

      not sops_parent?(pid) ->
        log_and_return(pid, {:error, "only sops may ask for this key"})

      true ->
        case SopsKeyring.keys() do
          [] -> log_and_return(pid, {:error, "no key held"})
          keys -> log_and_return(pid, {:ok, keys})
        end
    end
  end

  defp log_and_return(pid, {:ok, _keys} = result) do
    Logger.info("[CmsHarness] released the sops key to pid #{pid}")
    result
  end

  defp log_and_return(pid, {:error, reason} = result) do
    Logger.warning("[CmsHarness] refused a sops key request from pid #{inspect(pid)}: #{reason}")
    result
  end

  defp parse_request(line) do
    case line |> String.trim() |> String.split(" ", trim: true) do
      [pid_s, uid_s] ->
        with {pid, ""} <- Integer.parse(pid_s),
             {uid, ""} <- Integer.parse(uid_s) do
          {:ok, pid, uid}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @doc "This harness process's own uid, or `nil` on a platform `id -u` doesn't exist on (e.g. Windows)."
  @spec owner_uid() :: non_neg_integer() | nil
  def owner_uid do
    with path when is_binary(path) <- System.find_executable("id"),
         {out, 0} <- System.cmd("id", ["-u"], stderr_to_stdout: true),
         {uid, _} <- Integer.parse(String.trim(out)) do
      uid
    else
      _ -> nil
    end
  end

  # Whether `pid`'s real parent process, read fresh from the OS process table
  # (never the client's own say-so), is `sops`. There is no `/proc` on macOS,
  # so `ps` is what works identically on both of this feature's real targets
  # (a laptop, a Linux cloud box).
  defp sops_parent?(pid) when is_integer(pid) do
    with {:ok, ppid} <- parent_pid(pid),
         {:ok, comm} <- command_name(ppid) do
      Path.basename(comm) in ["sops", "sops.exe"]
    else
      _ -> false
    end
  end

  defp sops_parent?(_pid), do: false

  defp parent_pid(pid) do
    case System.cmd("ps", ["-o", "ppid=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {out, 0} ->
        case out |> String.trim() |> Integer.parse() do
          {ppid, _} -> {:ok, ppid}
          :error -> {:error, :no_such_pid}
        end

      _ ->
        {:error, :no_such_pid}
    end
  end

  defp command_name(pid) do
    case System.cmd("ps", ["-o", "comm=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {out, 0} ->
        case String.trim(out) do
          "" -> {:error, :no_such_pid}
          comm -> {:ok, comm}
        end

      _ ->
        {:error, :no_such_pid}
    end
  end
end
