defmodule CodeMySpec.Provisioning.Deploy do
  @moduledoc """
  Image, migrate, swap — in that order, and only when each step earns the next.

  Shell steps run through `CodeMySpec.ExecutionContexts.cmd/4` rather than
  `System.cmd/3`, so they execute on whichever device the environment names
  (the harness channel for a remote box) and are recordable in tests.

  - `run/3` migrates against the new image *before* any traffic moves, and
    records a timestamp per phase, so `migrated_at <= swapped_at` is
    observable rather than assumed.
  - A failed migration, health check or swap never moves traffic and leaves
    `live_version: :previous`; the `reason` names the phase. `swapped_at` is
    the only evidence of a completed deploy.
  - `probe/2` checks HTTPS on the environment's hostname and follows no
    redirects: a 301 is not the app answering.

  See knowledge/provisioning, "Deploy".
  """

  require Logger

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.Provisioning.Transport
  alias CodeMySpec.Provisioning.Wait

  @type phase :: :build | :bootstrap | :migrate | :health | :swap

  defmodule Result do
    @moduledoc """
    What a deploy actually did, with timestamps.

    Deliberately has no `:done` or `:success` field. The only evidence a
    deploy completed is `swapped_at` being set, so a caller cannot report
    success for a run that refused to swap.
    """

    @type t :: %__MODULE__{
            bootstrapped_at: DateTime.t() | nil,
            migrated_at: DateTime.t() | nil,
            health_ok_at: DateTime.t() | nil,
            swapped_at: DateTime.t() | nil,
            live_version: :previous | :new,
            failed_phase: CodeMySpec.Provisioning.Deploy.phase() | nil,
            reason: String.t() | nil,
            output: String.t() | nil
          }

    defstruct bootstrapped_at: nil,
              migrated_at: nil,
              health_ok_at: nil,
              swapped_at: nil,
              live_version: :previous,
              failed_phase: nil,
              reason: nil,
              output: nil

    @doc "Whether traffic actually moved to the new version."
    @spec swapped?(t()) :: boolean()
    def swapped?(%__MODULE__{swapped_at: nil}), do: false
    def swapped?(%__MODULE__{}), do: true
  end

  @doc """
  Deploy an environment: migrate, health-check, then swap.

  Returns a `Result`. A refusal is an ordinary return value carrying the phase
  that failed and why — not an exception — because the status page renders the
  reason and the setup agent needs it to act.

  `opts`:
    * `:host` — hostname to probe (required for the health phase)
    * `:deploy_script` — defaults to `bin/deploy`
    * `:now` — clock injection for tests
    * `:probe` — health probe injection for tests
  """
  @spec run(CodeMySpec.ExecutionContexts.ExecutionContext.t(), String.t(), keyword()) ::
          Result.t()
  def run(env, environment, opts \\ []) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)
    script = deploy_script(env, opts)

    started = System.monotonic_time(:millisecond)

    Logger.info("[Deploy] migrating #{environment}")

    # One log line per phase, with its duration, so a slow phase and a stuck
    # one are distinguishable and the remote timeout can be set from evidence.
    with {:ok, migrate_out, result} <- migrate_with_bootstrap(env, environment, script, now, opts),
         migrated = System.monotonic_time(:millisecond),
         _ =
           Logger.info(
             "[Deploy] #{environment} migrated in #{took(started, migrated)}, checking health"
           ),
         {:ok, result} <- health(result, opts, now, skip_health?(migrate_out, result, opts)),
         healthy = System.monotonic_time(:millisecond),
         _ =
           Logger.info("[Deploy] #{environment} healthy in #{took(migrated, healthy)}, swapping"),
         {:ok, result} <- swap(env, environment, script, result, now, opts) do
      swapped = System.monotonic_time(:millisecond)

      Logger.info(
        "[Deploy] #{environment} swapped in #{took(healthy, swapped)} " <>
          "(total #{took(started, swapped)})"
      )

      %{result | output: migrate_out, live_version: :new}
    else
      {:error, %Result{} = refused} ->
        # Log an excerpt anchored on the last error marker: `bin/deploy`'s ssh
        # trace keeps logging keepalives after the real error, so a blind tail
        # is noise.
        Logger.warning(
          "[Deploy] #{environment} refused at #{refused.failed_phase} after " <>
            "#{took(started, System.monotonic_time(:millisecond))}: #{refused.reason} " <>
            "output=#{inspect(error_excerpt(refused.output))}"
        )

        refused
    end
  end

  # To a tenth of a second. A refusal at almost exactly the remote timeout is
  # a timeout (exit 124) wearing a command failure's clothes.
  defp took(from, to), do: "#{Float.round((to - from) / 1000, 1)}s"

  @error_markers ["ERROR (", "Error response from daemon", "error response from daemon"]

  # Anchors on the last known marker (earlier attempts' markers are not the
  # one that mattered) and reads forward from it.
  defp error_excerpt(output) when is_binary(output) do
    case last_marker_index(output) do
      nil -> String.slice(output, -1000, 1000)
      index -> String.slice(output, index, 2000)
    end
  end

  defp error_excerpt(_output), do: ""

  defp last_marker_index(output) do
    @error_markers
    |> Enum.flat_map(fn marker ->
      output
      |> :binary.matches(marker)
      |> Enum.map(fn {index, _length} -> index end)
    end)
    |> case do
      [] -> nil
      indexes -> Enum.max(indexes)
    end
  end

  # `kamal app exec` (migrate) needs `env/roles/<role>.env` on the host, which
  # kamal writes only when booting a container. On a never-deployed host,
  # migrate refuses for that reason, so swap runs once as a `:bootstrap`
  # phase and migrate is retried. Detected from the real error each time, not
  # a flag. See knowledge/provisioning, "Deploy".
  defp migrate_with_bootstrap(env, environment, script, now, opts) do
    case migrate(env, environment, script, now, opts) do
      {:ok, _migrate_out, _result} = success ->
        success

      {:error, %Result{output: output} = refused} ->
        if missing_env_file?(output) do
          bootstrap(env, environment, script, now, opts, refused)
        else
          {:error, refused}
        end
    end
  end

  defp missing_env_file?(output) when is_binary(output),
    do:
      String.contains?(output, "env/roles/") and
        String.contains?(output, "no such file or directory")

  defp missing_env_file?(_output), do: false

  defp bootstrap(env, environment, script, now, opts, refused) do
    Logger.info("[Deploy] #{environment} has never been deployed — bootstrapping before migrate")

    case swap(env, environment, script, %Result{}, now, opts) do
      {:ok, %Result{swapped_at: swapped_at}} ->
        Logger.info("[Deploy] #{environment} bootstrapped, retrying migrate")

        case migrate(env, environment, script, now, opts) do
          {:ok, migrate_out, result} ->
            {:ok, migrate_out, %{result | bootstrapped_at: swapped_at}}

          {:error, %Result{} = still_refused} ->
            # The bootstrap already moved traffic, so there is no previous
            # version to have stayed on; say so.
            {:error,
             %{
               still_refused
               | live_version: :new,
                 reason:
                   "Bootstrap deploy succeeded, but the migration that followed it failed — " <>
                     "#{environment} has never served anything before, so there is no previous " <>
                     "version to fall back to. #{still_refused.reason}"
             }}
        end

      {:error, %Result{} = bootstrap_failed} ->
        {:error,
         %{
           refused
           | failed_phase: :bootstrap,
             reason:
               "Bootstrap deploy failed (#{bootstrap_failed.reason}) — #{environment} has never " <>
                 "served anything before, so migrate has nothing to run against yet.",
             output: bootstrap_failed.output
         }}
    end
  end

  # `stderr_to_stdout`, because kamal writes its failures there.
  defp migrate(env, environment, script, now, opts) do
    case run_script(env, script, ["migrate", environment], opts) do
      {output, 0} ->
        {:ok, output, %Result{migrated_at: now.()}}

      {output, status} ->
        # The previous version keeps serving. Nothing swaps.
        {:error,
         %Result{
           live_version: :previous,
           failed_phase: :migrate,
           reason: "Migration failed (exit #{status}) — the previous version is still serving.",
           output: output
         }}
    end
  end

  # Skipped on a first deploy. Health runs before the swap and so probes the
  # version already serving; with nothing deployed, the probe could never
  # pass. kamal's own proxy health check still gates the swap.
  defp health(result, _opts, _now, true), do: {:ok, result}

  defp health(result, opts, now, _first_deploy) do
    probe = Keyword.get(opts, :probe, &probe/2)
    host = Keyword.get(opts, :host)
    attempts = Keyword.get(opts, :health_attempts, 30)

    case await_health(probe, host, opts, attempts) do
      :ok ->
        {:ok, %{result | health_ok_at: now.()}}

      {:error, reason} ->
        # The reason must name health, or the report is unactionable.
        {:error,
         %{
           result
           | live_version: :previous,
             failed_phase: :health,
             reason:
               "Health check failed for #{host}: #{reason}. The previous version is still serving."
         }}
    end
  end

  # The generated project prints `first_deploy=1` on a database with no
  # migrations applied.
  defp first_deploy?(migrate_output) when is_binary(migrate_output),
    do: String.contains?(migrate_output, "first_deploy=1")

  defp first_deploy?(_migrate_output), do: false

  # Three independent first-deploy signals; any one skips health. The first
  # two are side effects of this run's migrate, and a crashed first boot
  # leaves kamal's env file behind, so `opts[:environment_previously_deployed]`
  # (the environment's `first_deployed_at`, set only after a real swap) is the
  # authoritative one. Defaults to `true` (run the check) when absent.
  defp skip_health?(migrate_out, result, opts) do
    first_deploy?(migrate_out) || result.bootstrapped_at != nil ||
      not Keyword.get(opts, :environment_previously_deployed, true)
  end

  defp await_health(probe, host, opts, attempts) do
    case probe.(host, opts) do
      :ok ->
        :ok

      {:error, _reason} when attempts > 1 ->
        Wait.sleep(Keyword.get(opts, :health_interval_ms, 5_000))
        await_health(probe, host, opts, attempts - 1)

      # The last reason: what the host was doing on the final attempt is the
      # diagnosis.
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp swap(env, environment, script, result, now, opts) do
    case run_script(env, script, ["swap", environment], opts) do
      {_output, 0} ->
        {:ok, %{result | swapped_at: now.()}}

      {output, status} ->
        {:error,
         %{
           result
           | live_version: :previous,
             failed_phase: :swap,
             reason: "Traffic swap failed (exit #{status}).",
             output: output
         }}
    end
  end

  # What setup knows and the checkout cannot: the image setup already built
  # and pushed (so `bin/deploy` pulls with no GitHub credential), and the
  # host and IP of a server created at run time. Only set values are passed:
  # the script cannot tell an empty string from "not configured".
  defp script_env(opts) do
    for {name, value} <- [
          {"CMS_IMAGE", Keyword.get(opts, :image)},
          {"CMS_DEPLOY_HOST", Keyword.get(opts, :host)},
          {"CMS_DEPLOY_HOST_IP", Keyword.get(opts, :host_ip)},
          # The decryption key, straight from `ProjectSecrets`; setup never
          # writes the private half of an age key to the working tree.
          {"SOPS_AGE_KEY", Keyword.get(opts, :age_key)},
          # kamal will not render a config without a registry password, and
          # logs in with it before pulling.
          {"KAMAL_REGISTRY_USERNAME", Keyword.get(opts, :registry_username)},
          {"KAMAL_REGISTRY_PASSWORD", Keyword.get(opts, :registry_password)},
          # Without a pinned key, kamal's ssh offers every agent identity and
          # `MaxAuthTries` disconnects first.
          {"CMS_SSH_KEY_PATH", Keyword.get(opts, :ssh_key_path)},
          # Only for the local fleet (published loopback ports); real boxes
          # are on 22.
          {"CMS_SSH_PORT", port_option(Keyword.get(opts, :ssh_port))}
        ],
        is_binary(value) and value != "" do
      {name, value}
    end
  end

  # `script_env/1` keeps only binaries, so an integer port is stringified here.
  defp port_option(nil), do: nil
  defp port_option(port), do: to_string(port)

  @doc """
  Probe a host over HTTPS.

  Redirects are NOT followed. A 301 to HTTPS is the redirect answering, not
  the app — following it would let a misconfigured `force_ssl` pass a health
  check that the proxy's own plain-HTTP probe fails.

  `:scheme` probes plain HTTP instead, which is not a health check: it is how
  a caller tells "the proxy is up and issuance failed" apart from "nothing is
  listening", since those are the same timeout over TLS.
  """
  @spec probe(String.t() | nil, keyword()) :: :ok | {:error, String.t()}
  def probe(nil, _opts), do: {:error, "no hostname given"}

  def probe(host, opts) do
    path = Keyword.get(opts, :health_path, "/health")
    scheme = Keyword.get(opts, :scheme, :https)

    req_opts =
      [
        method: :get,
        url: "#{scheme}://#{host}#{path}",
        redirect: false,
        retry: false,
        receive_timeout: Keyword.get(opts, :timeout_ms, 10_000)
      ] ++ plug_opt()

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, "responded #{status}"}
      # Words, not `inspect/1`: callers interpolate this into a sentence.
      {:error, reason} -> {:error, Transport.describe(reason)}
    end
  end

  @doc """
  Whether every public host answers over HTTPS.

  Returns `{:ok, hosts}` or `{:error, {:unhealthy, failures}}` naming which
  host failed and how — an environment is not done until its own hostname
  answers, and "something is down" is not a report anyone can act on.
  """
  @spec verify_hosts([String.t()], keyword()) ::
          {:ok, [String.t()]} | {:error, {:unhealthy, [{String.t(), String.t()}]}}
  def verify_hosts(hosts, opts \\ []) do
    probe = Keyword.get(opts, :probe, &probe/2)

    failures =
      hosts
      |> Enum.map(fn host -> {host, probe.(host, opts)} end)
      |> Enum.filter(&match?({_, {:error, _}}, &1))
      |> Enum.map(fn {host, {:error, reason}} -> {host, reason} end)

    case failures do
      [] -> {:ok, hosts}
      failures -> {:error, {:unhealthy, failures}}
    end
  end

  defp plug_opt do
    case Application.get_env(:code_my_spec, __MODULE__, [])[:plug] do
      nil -> []
      plug -> [plug: plug]
    end
  end

  # Relative to the project checkout: `System.cmd/3` resolves a relative
  # command against the process's cwd.
  defp resolve_script(%{cwd: cwd}, script) when is_binary(cwd) and cwd != "" do
    if Path.type(script) == :absolute, do: script, else: Path.join(cwd, script)
  end

  defp resolve_script(_env, script), do: script

  # With `opts[:run]` the checkout is on the far end of SSH, so the relative
  # name travels and `remote_command/3`'s `cd` resolves it there.
  defp deploy_script(env, opts) do
    script = Keyword.get(opts, :deploy_script, "bin/deploy")

    if Keyword.has_key?(opts, :run), do: script, else: resolve_script(env, script)
  end

  # Where the script runs: `opts[:run]` (supplied by `Builder`, bound to the
  # builder box and its SSH session), from which kamal connects *to* the app
  # server. Never on the app box itself, and never the caller's machine (a
  # harness cannot shell out).
  defp run_script(env, script, args, opts) do
    case Keyword.get(opts, :run) do
      nil ->
        ExecutionContexts.cmd(env, script, args, env: script_env(opts), stderr_to_stdout: true)

      run ->
        run.([remote_command(script, args, opts)])
    end
  end

  # One shell line: diagnostics, seed host trust, deliver the key, cd to the
  # delivered tree, export what the script reads (quoted), run it.
  defp remote_command(script, args, opts) do
    exports =
      opts
      |> script_env()
      |> Enum.map_join(" ", fn {name, value} -> "#{name}=#{shell_quote(value)}" end)

    dir = Keyword.get(opts, :remote_dir, ".")

    diagnose_system_ssh_config(opts) <>
      trust_host(opts) <>
      restrict_host_key_algorithms(opts) <>
      deliver_ssh_key(opts) <>
      diagnose_key_on_builder(opts) <>
      diagnose_net_ssh_lookup(opts) <>
      diagnose_real_ssh_connection(opts) <>
      "cd #{shell_quote(dir)} && " <>
      diagnose_net_ssh_lookup_in_project_dir(opts) <>
      "#{exports} #{script} #{Enum.map_join(args, " ", &shell_quote/1)}"
  end

  # Diagnostic: prints the delivered key's ownership, the shell's user, and the
  # known_hosts key types — never key material.
  defp diagnose_key_on_builder(opts) do
    case Keyword.get(opts, :ssh_key_path) do
      path when is_binary(path) ->
        "ls -la #{shell_quote(path)}; whoami; " <>
          "awk '{print $2}' ~/.ssh/known_hosts 2>/dev/null; "

      _ ->
        ""
    end
  end

  # Diagnostic: shows `/etc/ssh/ssh_config`'s known-hosts and host-key lines,
  # which net-ssh reads alongside `~/.ssh/config`.
  defp diagnose_system_ssh_config(_opts) do
    "grep -iE 'UserKnownHostsFile|HostKeyAlgorithms' /etc/ssh/ssh_config /etc/ssh_config 2>/dev/null; "
  end

  # Diagnostic: runs `Net::SSH::KnownHosts.search_for/1` against the same
  # "host,ip" target net-ssh builds.
  # See knowledge/provisioning, "Kamal host keys".
  defp diagnose_net_ssh_lookup(opts) do
    case Keyword.get(opts, :host) do
      host when is_binary(host) and host != "" ->
        "ruby -e #{shell_quote(net_ssh_probe_script(host, "net_ssh_probe"))}; "

      _ ->
        ""
    end
  end

  # Diagnostic: a bare `Net::SSH.start` with the delivered key, bypassing
  # kamal and SSHKit.
  defp diagnose_real_ssh_connection(opts) do
    case {Keyword.get(opts, :host), Keyword.get(opts, :ssh_key_path)} do
      {host, path} when is_binary(host) and host != "" and is_binary(path) ->
        "ruby -e #{shell_quote(net_ssh_real_probe_script(host, path))}; "

      _ ->
        ""
    end
  end

  defp net_ssh_real_probe_script(host, key_path) do
    "require 'net/ssh'; " <>
      "begin; " <>
      "Net::SSH.start(#{inspect(host)}, 'root', keys: [#{inspect(key_path)}], keys_only: true, " <>
      "timeout: 10, non_interactive: true){|s| puts 'net_ssh_real_probe connected'}; " <>
      "rescue Net::SSH::HostKeyMismatch => e; " <>
      "puts \"net_ssh_real_probe HostKeyMismatch: \#{e.message}\"; " <>
      "rescue => e; " <>
      "puts \"net_ssh_real_probe \#{e.class}: \#{e.message}\"; " <>
      "end"
  end

  # Diagnostic: the lookup probe again from inside the project tree, with
  # `which kamal` and the lockfile's net-ssh — a project Gemfile or binstub
  # can change which net-ssh runs.
  defp diagnose_net_ssh_lookup_in_project_dir(opts) do
    case Keyword.get(opts, :host) do
      host when is_binary(host) and host != "" ->
        "which kamal; gem list net-ssh 2>&1; " <>
          "[ -f Gemfile.lock ] && grep -A1 '    net-ssh' Gemfile.lock; " <>
          "ruby -e #{shell_quote(net_ssh_probe_script(host, "net_ssh_probe_incd"))}; "

      _ ->
        ""
    end
  end

  defp net_ssh_probe_script(host, label) do
    "require 'net/ssh'; require 'socket'; " <>
      "puts \"#{label} net_ssh_version=\#{Net::SSH::Version::STRING}\"; " <>
      "host=#{inspect(host)}; " <>
      "ip=(TCPSocket.new(host,22).remote_address.ip_address rescue nil); " <>
      "target=ip ? \"\#{host},\#{ip}\" : host; " <>
      "keys=Net::SSH::KnownHosts.search_for(target); " <>
      "puts \"#{label} target=\#{target} found=\#{keys.to_a.size}\"; " <>
      "keys.each{|k| puts \"#{label} \#{k.ssh_type} " <>
      "\#{(Net::SSH::Authentication::PubKeyFingerprint.fingerprint(k.to_blob) rescue 'fp-error')}\"}"
  end

  # kamal on the builder opens its own ssh to the app host and reads
  # `CMS_SSH_KEY_PATH` there, so the key bytes have to exist at that path on
  # the builder. Base64 so the key's newlines need no quoting.
  defp deliver_ssh_key(opts) do
    case Keyword.get(opts, :ssh_key_path) do
      path when is_binary(path) ->
        encoded = path |> File.read!() |> Base.encode64()

        "mkdir -p #{shell_quote(Path.dirname(path))} && " <>
          "echo #{shell_quote(encoded)} | base64 -d > #{shell_quote(path)} && " <>
          "chmod 600 #{shell_quote(path)} && "

      _ ->
        ""
    end
  end

  # Seeds known_hosts for kamal's own outbound ssh with exactly one RSA key.
  # Wipes the user and global known_hosts files first (the box image can carry
  # stale entries), and retries the scan until the file is non-empty.
  # See knowledge/provisioning, "Kamal host keys".
  defp trust_host(opts) do
    case Keyword.get(opts, :host) do
      host when is_binary(host) and host != "" ->
        quoted = shell_quote(host)

        "rm -f ~/.ssh/known_hosts ~/.ssh/known_hosts2 " <>
          "/etc/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts2; " <>
          "for i in 1 2 3; do " <>
          "ssh-keyscan -t rsa -T 10 -H #{quoted} >> ~/.ssh/known_hosts 2>/dev/null " <>
          "&& [ -s ~/.ssh/known_hosts ] && break; sleep 2; done; "

      _ ->
        ""
    end
  end

  # The other half of `trust_host/1`: restricts negotiated host-key algorithms
  # to the RSA family that was scanned, via `~/.ssh/config` (kamal has no
  # option for it; net-ssh reads the config by default). An explicit list:
  # net-ssh's parser has no `+`/`-` modifiers. Client-key auth is unaffected.
  @safe_host_key_algorithms "ssh-rsa,rsa-sha2-512,rsa-sha2-256"

  defp restrict_host_key_algorithms(opts) do
    case Keyword.get(opts, :host) do
      host when is_binary(host) and host != "" ->
        "rm -f ~/.ssh/config; " <>
          "printf '%s\\n' #{shell_quote("Host " <> host)} " <>
          "#{shell_quote("  HostKeyAlgorithms " <> @safe_host_key_algorithms)} >> ~/.ssh/config; "

      _ ->
        ""
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
end
