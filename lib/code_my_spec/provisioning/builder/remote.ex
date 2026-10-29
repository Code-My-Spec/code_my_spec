defmodule CodeMySpec.Provisioning.Builder.Remote do
  @moduledoc """
  Run the build on the builder box.

  `Builder` owns the box; this owns what happens on it: reach it, deliver the
  commit, build, push, and read back what was actually built.

  The architecture is read off the built image, never echoed from the
  request, so `Builder`'s architecture check can catch a wrong build.
  """

  require Logger

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.Provisioning.Truncate
  alias CodeMySpec.Provisioning.Wait

  # A fresh box answers the API long before SSH; polled, up to three minutes
  # (a cold Hetzner box can take over a minute to reach sshd).
  @ssh_attempts 90
  @ssh_interval_ms 2_000

  # Label on a trivial long-running container `build/4` starts before and
  # removes after each build — the only `docker ps`-visible sign of a build in
  # progress, since BuildKit steps never appear as containers. Read by
  # `BurstBox.build_in_progress?/3`.
  @build_marker_label "cms-build-in-progress"

  @doc "Label `build/4`'s in-flight marker carries, shared with `BurstBox.build_in_progress?/3`."
  @spec build_marker_label() :: String.t()
  def build_marker_label, do: @build_marker_label

  @doc """
  Build `ref` on `server` and push it to `reference`.

  `:run` takes the whole command as a list and returns `{output, status}`,
  which is what makes this testable without a box: the commands are the
  interesting part, and running them is not.
  """
  @spec build(map(), String.t(), String.t(), keyword()) ::
          {:ok, %{reference: String.t(), architecture: :arm | :x86}} | {:error, term()}
  def build(server, ref, reference, opts \\ []) do
    run = Keyword.get(opts, :run) || ssh_runner(server, opts)
    deliver = Keyword.get(opts, :deliver) || ssh_deliver(server, opts)

    dir = Keyword.get(opts, :build_dir, "/build")

    # One log line per phase, so a long build and a hung one are
    # distinguishable from outside.
    with :ok <- await_ssh(run, Keyword.get(opts, :ssh_attempts, @ssh_attempts), opts),
         _ = Logger.info("[Builder] ssh reachable, delivering #{ref}"),
         :ok <- deliver_source(deliver, ref, dir, opts) do
      Logger.info("[Builder] source delivered, running docker build")
      build_marked(run, ref, reference, dir, opts)
    end
  end

  # The box is shared, so the marker brackets every phase of this build's
  # work, and is removed either way.
  defp build_marked(run, ref, reference, dir, opts) do
    marker = start_build_marker(run, ref)

    result =
      with :ok <- docker_build(run, reference, ref, dir, opts),
           _ = Logger.info("[Builder] docker build finished, pushing #{reference}"),
           :ok <- maybe_push(run, reference, opts),
           _ = Logger.info("[Builder] pushed #{reference}, reading back its architecture"),
           {:ok, architecture} <- built_architecture(run, reference) do
        {:ok, %{reference: reference, architecture: architecture}}
      end

    stop_build_marker(run, marker)
    result
  end

  # `alpine:3 sleep infinity`, ended only by the `rm -f` below. `nil` when it
  # cannot start: the marker is an observability aid, never load-bearing.
  defp start_build_marker(run, ref) do
    name = "cms-build-marker-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    command =
      "docker run -d --label #{@build_marker_label}=#{ref} --name #{name} alpine:3 sleep infinity"

    case run.([command]) do
      {_, 0} ->
        name

      {output, status} ->
        Logger.warning(
          "[Builder] could not start the in-progress build marker: exit #{status}: " <>
            "#{trim(output)} — a busy-check against this box will not see this build"
        )

        nil
    end
  end

  defp stop_build_marker(_run, nil), do: :ok

  defp stop_build_marker(run, name) do
    case run.(["docker rm -f #{name}"]) do
      {_, 0} ->
        :ok

      {output, status} ->
        Logger.warning(
          "[Builder] could not remove the build marker #{name}: exit #{status}: " <>
            "#{trim(output)} — it may linger and read as a build still in flight"
        )

        :ok
    end
  end

  # Answering once is not staying up: cloud-init restarts sshd after the first
  # connection. Exit 255 is ssh's own failure and is retried; any other status
  # is the remote `tar`/`rm` and stays an immediate error.
  defp deliver_source(deliver, ref, dir, opts, attempts \\ 10) do
    case deliver.(ref, dir) do
      :ok ->
        :ok

      {:error, {:source_delivery_failed, 255, _}} when attempts > 1 ->
        Wait.sleep(Keyword.get(opts, :ssh_interval_ms, @ssh_interval_ms))
        deliver_source(deliver, ref, dir, opts, attempts - 1)

      other ->
        other
    end
  end

  @doc """
  Block until the box answers SSH, or give up saying how long it waited.

  Reachability, not readiness of anything in particular: if `true` runs, the
  box is up and the key works, which is the whole precondition.

  The give-up carries how long it waited and what SSH last said: a broken box
  and an impatient caller need opposite responses.

  Public because any step reaching a just-created server needs it — a new
  Hetzner server is `initializing` for a minute or so.
  """
  @spec await_ssh((list() -> {String.t(), non_neg_integer()}), non_neg_integer(), keyword()) ::
          :ok | {:error, {:builder_unreachable, non_neg_integer(), String.t()}}
  def await_ssh(run, attempts, opts, waited \\ 0, last \\ "")

  def await_ssh(_run, 0, _opts, waited, last) do
    {:error, {:builder_unreachable, div(waited, 1000), last}}
  end

  def await_ssh(run, attempts, opts, waited, _last) do
    case run.(["true"]) do
      {_, 0} ->
        :ok

      {output, _status} ->
        interval = Keyword.get(opts, :ssh_interval_ms, @ssh_interval_ms)
        Wait.sleep(interval)
        await_ssh(run, attempts - 1, opts, waited + interval, trim(output))
    end
  end

  @doc """
  Install kamal on the builder before it orchestrates a deploy over it,
  unless it is already there.

  Checked rather than trusted: the burst box snapshot bakes kamal in, but its
  native gems can be stale or broken. The check is `command -v kamal` plus an
  actual `require 'ed25519'; require 'bcrypt_pbkdf'`; install uses `--force`
  and retries up to 3 times.

  See knowledge/provisioning, "Kamal on the builder".
  """
  @ed25519_usable_check "ruby -e \"require 'ed25519'; require 'bcrypt_pbkdf'\" >/dev/null 2>&1"

  @spec ensure_kamal((list() -> {String.t(), non_neg_integer()})) ::
          :ok | {:error, {non_neg_integer(), String.t()}}
  def ensure_kamal(run) do
    case run.(["command -v kamal && #{@ed25519_usable_check}"]) do
      {_, 0} -> :ok
      _ -> install_kamal(run, 3)
    end
  end

  defp install_kamal(run, attempts_left) do
    command =
      "apt-get update -qq && " <>
        "DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a " <>
        "apt-get install -y -qq ruby-full build-essential >/dev/null && " <>
        "gem install kamal ed25519 bcrypt_pbkdf --force --no-document --backtrace && " <>
        @ed25519_usable_check

    case run.([command]) do
      {_, 0} ->
        :ok

      {_output, _status} when attempts_left > 1 ->
        install_kamal(run, attempts_left - 1)

      # Head and tail: apt buries its cause at the end, a gem crash prints its
      # error before the backtrace. `--backtrace` makes RubyGems attach the
      # message consistently.
      {output, status} ->
        {:error, {status, output |> trim() |> Truncate.head_and_tail()}}
    end
  end

  @doc """
  Send one commit's tree to the builder, over the SSH we already have.

  Leaves no GitHub credential on the builder: we already hold SSH to it.
  An archive of the commit lands exactly its tree — no history, remotes or
  `.git`.
  """
  @spec ssh_deliver(map(), keyword()) :: (String.t(), String.t() -> :ok | {:error, term()})
  def ssh_deliver(server, opts) do
    env = Keyword.fetch!(opts, :env)

    fn ref, dir ->
      remote = "rm -rf #{dir} && mkdir -p #{dir} && tar -x -C #{dir}"

      command =
        "git archive --format=tar #{ref} | " <>
          Enum.join(["ssh" | ssh_args(server, opts)], " ") <>
          " " <> shell_quote(remote)

      # Through the project's own environment, so the archive comes from the
      # deploy's checkout, not the server's cwd.
      case ExecutionContexts.cmd(env, "sh", ["-c", command], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {output, status} -> {:error, {:source_delivery_failed, status, trim(output)}}
      end
    end
  end

  @doc """
  Deliver `ref`'s tree straight from GitHub, for a project whose real
  checkout `ssh_deliver/2` cannot reach.

  Used when there is no local environment to archive from; setup already
  pushed the project to GitHub. The token travels with this one request, not
  as a file or remote on the builder. `--location-trusted` because the
  tarball endpoint redirects to `codeload.github.com` and `-u` is otherwise
  stripped (a private repo then 404s). `--strip-components=1` drops the API's
  `owner-repo-sha/` wrapper to match the archive layout.
  """
  @spec github_deliver(map(), keyword()) :: (String.t(), String.t() -> :ok | {:error, term()})
  def github_deliver(server, opts) do
    run = Keyword.get(opts, :run) || ssh_runner(server, opts)
    repo = Keyword.fetch!(opts, :github_repo)
    token = Keyword.fetch!(opts, :github_token)

    fn ref, dir ->
      command =
        "rm -rf #{dir} && mkdir -p #{dir} && " <>
          "curl -sSfL --location-trusted -u #{shell_quote("x-access-token:#{token}")} " <>
          "https://api.github.com/repos/#{repo}/tarball/#{ref} | " <>
          "tar -xz -C #{dir} --strip-components=1"

      case run.([command]) do
        {_, 0} -> :ok
        {output, status} -> {:error, {:source_delivery_failed, status, trim(output)}}
      end
    end
  end

  @doc """
  Deliver into a directory on this machine, for the local build path.

  `:cd` is the checkout to archive from. Pairs with `local_runner/1` the way
  `ssh_deliver/2` pairs with `ssh_runner/2`.
  """
  @spec local_deliver(keyword()) :: (String.t(), String.t() -> :ok | {:error, term()})
  def local_deliver(opts) do
    cd = Keyword.fetch!(opts, :cd)

    fn ref, dir ->
      command =
        "rm -rf #{dir} && mkdir -p #{dir} && git archive --format=tar #{ref} | tar -x -C #{dir}"

      case System.cmd("sh", ["-c", command], cd: cd, stderr_to_stdout: true) do
        {_, 0} -> :ok
        {output, status} -> {:error, {:source_delivery_failed, status, trim(output)}}
      end
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  # `service` is the label kamal requires on an image it deploys; kamal stamps
  # it itself, but setup builds elsewhere and deploys with `--skip-push`.
  #
  # `--force-rm`: the legacy builder keeps a failed step's intermediate
  # container; BuildKit leaves none and ignores the flag. Correct either way.
  defp docker_build(run, reference, ref, dir, opts) do
    labels = "--label commit=#{ref}" <> service_label(Keyword.get(opts, :service))
    flags = "--force-rm " <> labels <> platform_flag(Keyword.get(opts, :platform))

    case run.(["cd #{dir} && docker build #{flags} -t #{reference} ."]) do
      {_, 0} -> :ok
      {output, status} -> {:error, {:build_failed, status, trim(output)}}
    end
  end

  # NEVER set this in production: forcing the platform makes Docker emulate
  # the right architecture and `Builder`'s mismatch check could never fire.
  # It exists for the local fleet, where one box stands in for both.
  defp platform_flag(nil), do: ""
  defp platform_flag(platform), do: " --platform #{platform}"

  defp service_label(service) when is_binary(service) and service != "",
    do: " --label service=#{shell_quote(service)}"

  defp service_label(_service), do: ""

  # Skippable for local builds (a push would make a build test a network
  # test). Never skipped in production: the deploy pulls what was pushed.
  defp maybe_push(run, reference, opts) do
    case Keyword.get(opts, :push, true) do
      false ->
        :ok

      _ ->
        # The private-network registry speaks plain HTTP and Docker assumes
        # HTTPS for anything but localhost; without trust the push times out.
        host = reference |> String.split("/") |> hd()

        with :ok <- trust(run, host),
             :ok <- login(run, reference, opts) do
          docker_push(run, reference)
        end
    end
  end

  # A failed trust is named here, rather than surfacing later as a push error
  # that blames the registry. `trust_command/1` is a no-op when already
  # trusted.
  defp trust(run, host) do
    if loopback?(host), do: :ok, else: attempt_trust(run, host)
  end

  defp attempt_trust(run, host) do
    case run.([CodeMySpec.Provisioning.Registry.trust_command(host)]) do
      {_, 0} -> :ok
      {output, status} -> {:error, {:registry_trust_failed, host, status, trim(output)}}
    end
  end

  # Docker already treats loopback registries as insecure; writing
  # `/etc/docker` on a developer's machine would be wrong.
  defp loopback?(host) do
    address = host |> String.split(":") |> hd()
    address == "localhost" or String.starts_with?(address, "127.")
  end

  # A public registry must not accept anonymous writes. The credential is the
  # shared registry's, from config (not `ProjectSecrets`); absent credentials
  # are a no-op for local registries. `--password-stdin` keeps the password
  # out of shell history and the process list.
  defp login(run, reference, opts) do
    case Keyword.get(opts, :registry_credentials) || configured_credentials() do
      %{username: username, password: password}
      when is_binary(username) and is_binary(password) ->
        host = reference |> String.split("/") |> hd()

        command =
          "printf %s #{shell_escape(password)} | " <>
            "docker login #{shell_escape(host)} " <>
            "--username #{shell_escape(username)} --password-stdin"

        case run.([command]) do
          {_, 0} -> :ok
          {output, status} -> {:error, {:login_failed, status, trim(output)}}
        end

      _ ->
        :ok
    end
  end

  defp configured_credentials do
    config = Application.get_env(:code_my_spec, CodeMySpec.Provisioning.Registry, [])

    case {config[:username], config[:password]} do
      {username, password} when is_binary(username) and is_binary(password) ->
        %{username: username, password: password}

      _ ->
        nil
    end
  end

  # Single quotes, with any embedded quote closed and reopened.
  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp docker_push(run, reference) do
    case run.(["docker push #{reference}"]) do
      {_, 0} ->
        :ok

      {output, status} ->
        {:error, {:push_failed, status, trim(output) <> where_am_i(run, reference)}}
    end
  end

  # A push failure gets network diagnostics attached: the registry answers on
  # the project's private network, so the first question is whether this box
  # is on it.
  defp where_am_i(run, reference) do
    host = reference |> String.split("/") |> hd()
    address = host |> String.split(":") |> hd()

    {addresses, _} = run.(["ip -4 -o addr show | awk '{print $2, $4}'"])

    # Narrowest first: does the host answer, is the port open, what does HTTP
    # do.
    {ping, _} = run.(["ping -c2 -W2 #{address} 2>&1 | tail -3"])

    {port, _} =
      run.(["timeout 5 bash -c '</dev/tcp/#{address}/5000' && echo OPEN || echo CLOSED"])

    {http, _} = run.(["curl -sv --max-time 5 http://#{host}/v2/ 2>&1 | tail -8"])

    "\n\nbuilder interfaces:\n" <>
      trim(addresses) <>
      "\n\nping #{address}:\n" <>
      trim(ping) <>
      "\n\ntcp #{address}:5000: " <>
      trim(port) <>
      "\n\nhttp #{host}/v2/:\n" <> trim(http)
  end

  # Read, not assumed — `Builder`'s architecture check depends on it.
  defp built_architecture(run, reference) do
    case run.(["docker image inspect --format '{{.Architecture}}' #{reference}"]) do
      {output, 0} -> output |> last_line() |> architecture()
      {output, status} -> {:error, {:inspect_failed, status, trim(output)}}
    end
  end

  # The last line: ssh output has stderr folded in, and any ssh warning would
  # otherwise be glued to the front of the answer.
  defp last_line(output) do
    output
    |> to_string()
    |> String.split("\n", trim: true)
    |> List.last("")
    |> String.trim()
  end

  defp architecture("arm64"), do: {:ok, :arm}
  defp architecture("aarch64"), do: {:ok, :arm}
  defp architecture("amd64"), do: {:ok, :x86}
  defp architecture("x86_64"), do: {:ok, :x86}
  defp architecture(other), do: {:error, {:unknown_architecture, other}}

  # Bounds the slowest single step (docker build); a full real pipeline takes
  # under 7 minutes.
  @default_remote_timeout_s 600

  # One SSH invocation per command: each is independently visible in a log and
  # replaceable in a test.
  @doc """
  Run commands on a box over SSH.

  Public because other steps reach servers they just provisioned with the
  same flag set (`IdentitiesOnly` is the kind of thing one copy learns and
  another does not).

  Every command is wrapped in a remote `timeout` (`wrap_with_timeout/2`):
  nothing else bounds a remote command that blocks silently. Exit 124 on
  expiry. `:remote_command_timeout_s` overrides the default. See
  knowledge/provisioning, "SSH to provisioned boxes".
  """
  @spec ssh_runner(map(), keyword()) :: (list() -> {String.t(), non_neg_integer()})
  def ssh_runner(server, opts) do
    env = Keyword.get(opts, :ssh_env) || Keyword.fetch!(opts, :env)
    args = ssh_args(server, opts)
    timeout = Keyword.get(opts, :remote_command_timeout_s, @default_remote_timeout_s)

    fn [command] ->
      ExecutionContexts.cmd(env, "ssh", args ++ [wrap_with_timeout(command, timeout)],
        stderr_to_stdout: true
      )
    end
  end

  # `sh -c` so the timeout bounds the whole `&&`/`|` chain, not its first word.
  # `-k 10` escalates to SIGKILL if `docker build`'s children ignore SIGTERM.
  # Public so the exact wrapping is assertable without ssh.
  @doc false
  @spec wrap_with_timeout(String.t(), pos_integer()) :: String.t()
  def wrap_with_timeout(command, timeout_s) do
    "timeout -k 10 #{timeout_s} sh -c #{shell_quote(command)}"
  end

  # Shared by the runner and `ssh_deliver/2`, which reach the same box on the
  # same terms; drift would be an auth failure on one path only.
  defp ssh_args(server, opts) do
    key = Keyword.fetch!(opts, :ssh_key_path)

    ssh_port(Keyword.get(opts, :ssh_port)) ++
      [
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        # Silences ssh's "Permanently added" banner, which (with
        # `UserKnownHostsFile=/dev/null`) prints on every call and would be read
        # as command output.
        "-o",
        "LogLevel=ERROR",
        # Without these, ssh offers every agent key first and `MaxAuthTries`
        # disconnects before reaching ours ("Too many authentication failures").
        "-o",
        "BatchMode=yes",
        "-o",
        "IdentitiesOnly=yes",
        # A just-created box either answers quickly or is not ready; callers
        # poll, so a 75s OS-default attempt only delays the retry.
        "-o",
        "ConnectTimeout=10",
        # Detects a silently dead connection in ~60s; neither `ConnectTimeout`
        # nor the remote `timeout` can.
        "-o",
        "ServerAliveInterval=15",
        "-o",
        "ServerAliveCountMax=4",
        "-i",
        key,
        "root@#{ip(server)}"
      ]
  end

  # Absent in production (port 22). The local fleet reaches container boxes
  # on published loopback ports through this same function.
  defp ssh_port(nil), do: []
  defp ssh_port(port), do: ["-p", to_string(port)]

  @doc """
  A runner that uses the local machine instead of a box.

  The same command sequence, the same real `docker build`, no cloud and no
  SSH — which makes the interesting half of this module exercisable without
  provisioning anything. Reachability and the burst box itself still need the
  real thing.
  """
  @spec local_runner(keyword()) :: (list() -> {String.t(), non_neg_integer()})
  def local_runner(opts) do
    # Required: the sequence starts with `rm -rf`.
    cd = Keyword.fetch!(opts, :cd)

    fn [command] -> System.cmd("sh", ["-c", command], cd: cd, stderr_to_stdout: true) end
  end

  defp ip(%{"public_net" => %{"ipv4" => %{"ip" => ip}}}), do: ip
  defp ip(%{"server" => server}), do: ip(server)
  defp ip(%{"ip" => ip}), do: ip

  defp trim(output), do: output |> to_string() |> String.trim()
end
