defmodule CodeMySpec.Provisioning.Deploy do
  @moduledoc """
  Image, migrate, swap — in that order, and only when each step earns the next.

  Shell steps run through `CodeMySpec.Environments.cmd/4` rather than
  `System.cmd/3`, so they execute on whichever device the environment names
  (the harness channel for a remote box) and are recordable in tests.

  ## The ordering is the whole point

  `run/3` migrates against the new image *before* any traffic moves to it, and
  records a timestamp for each phase. Criterion 8007 asserts `migrate_at <=
  swap_at` from those recordings rather than trusting the code's shape, which
  is the right way round: the ordering is an observable property, not an
  implementation detail.

  ## Two refusals, and they are not the same

  - **A failed migration** leaves the previous version serving and never
    swaps (8008). The new image is broken against the schema; promoting it
    would take the site down.
  - **A failed health check** likewise never swaps (8009), and the reason
    names health so the report is actionable rather than "deploy failed".

  Both leave `live_version` as `previous`. `run/3` therefore returns a struct
  whose `swapped_at` is nil in both cases — a caller cannot mistake a refused
  deploy for a completed one by checking the wrong field, because there is no
  field that says "done" independently of the swap having happened.

  ## Health is checked over HTTPS on the environment's own hostname

  `probe/2` follows no redirects deliberately. A 301 to HTTPS is not the app
  answering — treating it as healthy is how a misconfigured `force_ssl` passes
  a health check while the proxy's own probe fails (the trap
  `CodeMySpec.Generators` guards on the other side).
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Provisioning.Deploy.UptimeRobot
  alias CodeMySpec.Provisioning.Transport
  alias CodeMySpec.Provisioning.Wait

  @type phase :: :build | :migrate | :health | :swap

  defmodule Result do
    @moduledoc """
    What a deploy actually did, with timestamps.

    Deliberately has no `:done` or `:success` field. The only evidence a
    deploy completed is `swapped_at` being set, so a caller cannot report
    success for a run that refused to swap.
    """

    @type t :: %__MODULE__{
            migrated_at: DateTime.t() | nil,
            health_ok_at: DateTime.t() | nil,
            swapped_at: DateTime.t() | nil,
            live_version: :previous | :new,
            failed_phase: CodeMySpec.Provisioning.Deploy.phase() | nil,
            reason: String.t() | nil,
            output: String.t() | nil
          }

    defstruct migrated_at: nil,
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
  @spec run(CodeMySpec.Environments.Environment.t(), String.t(), keyword()) :: Result.t()
  def run(env, environment, opts \\ []) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)
    script = resolve_script(env, Keyword.get(opts, :deploy_script, "bin/deploy"))

    with {:ok, migrate_out, result} <- migrate(env, environment, script, now, opts),
         {:ok, result} <- health(result, opts, now, first_deploy?(migrate_out)),
         {:ok, result} <- swap(env, environment, script, result, now, opts) do
      %{result | output: migrate_out, live_version: :new}
    else
      {:error, %Result{} = refused} -> refused
    end
  end

  # `stderr_to_stdout`, because kamal writes its failures there. Without it the
  # captured output was empty and a failed migration reported only
  # "Migration failed (exit 1)" — the exit code and nothing else. The reason
  # was never lost; it was never collected.
  defp migrate(env, environment, script, now, opts) do
    case Environments.cmd(env, script, ["migrate", environment],
           env: script_env(opts),
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, output, %Result{migrated_at: now.()}}

      {output, status} ->
        # 8008: the previous version keeps serving. Nothing swaps.
        {:error,
         %Result{
           live_version: :previous,
           failed_phase: :migrate,
           reason: "Migration failed (exit #{status}) — the previous version is still serving.",
           output: output
         }}
    end
  end

  # There is nothing to protect on a first deploy, so there is nothing to check.
  #
  # This runs *before* the swap, which is deliberate (8009: a failed check
  # never moves traffic). But the new version has not booted at this point —
  # `migrate` runs a one-off container and `swap` is what boots the service —
  # so what this probes is the version already serving. That is a real
  # protection for an existing site and an impossibility for a new one: with
  # nothing deployed, the host refuses the connection and the deploy that
  # would have created the site is refused for the site not existing.
  #
  # `bin/deploy` is the only thing that knows, and it says so in its migrate
  # output. Deploying past this is not skipping a safety check: kamal's own
  # proxy health check still gates the swap, and there is no previous version
  # for a bad one to displace.
  defp health(result, _opts, _now, true), do: {:ok, result}

  defp health(result, opts, now, _first_deploy) do
    probe = Keyword.get(opts, :probe, &probe/2)
    host = Keyword.get(opts, :host)
    attempts = Keyword.get(opts, :health_attempts, 30)

    case await_health(probe, host, opts, attempts) do
      :ok ->
        {:ok, %{result | health_ok_at: now.()}}

      {:error, reason} ->
        # 8009: the reason must name health, or the report is unactionable.
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

  # Two places print this, and it took a regression to learn why one is not
  # enough. `bin/deploy` prints it when it finds no env files on the host —
  # which stopped happening once migrate began decrypting secrets baked into
  # the image, so a first deploy started *succeeding* and saying nothing.
  # `Release.migrate/0` now prints it on a database with no migrations
  # applied: the positive form of the same fact, observable when migrate works.
  defp first_deploy?(migrate_output) when is_binary(migrate_output),
    do: String.contains?(migrate_output, "first_deploy=1")

  defp first_deploy?(_migrate_output), do: false

  defp await_health(probe, host, opts, attempts) do
    case probe.(host, opts) do
      :ok ->
        :ok

      {:error, _reason} when attempts > 1 ->
        Wait.sleep(Keyword.get(opts, :health_interval_ms, 5_000))
        await_health(probe, host, opts, attempts - 1)

      # The last reason, not a bare "gave up" — what the host was doing on the
      # final attempt is the whole diagnosis.
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp swap(env, environment, script, result, now, opts) do
    case Environments.cmd(env, script, ["swap", environment],
           env: script_env(opts),
           stderr_to_stdout: true
         ) do
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

  # What setup knows and the checkout cannot.
  #
  # The generated `bin/deploy` was written for a human: it pushes, waits for
  # GitHub Actions to build, and pulls from ghcr.io with `gh auth token`. Setup
  # has already built the image on its own builder and pushed it to the
  # project's own registry, so all of that is both redundant and wrong —
  # criterion 8240 is a deploy that pulls with no GitHub credential at all.
  #
  # The host and its IP are here for the same reason. A generated
  # `config/deploy.uat.yml` carries `<UAT_HOST>` and `<UAT_HOST_IP>`
  # placeholders, and the IP is not knowable when the file is written: it
  # belongs to a server that setup creates later, and a different one on every
  # provision. No committed config can hold it, so it has to arrive at run
  # time.
  #
  # Only values that are actually set are passed. An empty string is worse than
  # an absent variable — the script cannot tell "not configured" from
  # "configured to nothing", and would deploy an image called "".
  defp script_env(opts) do
    for {name, value} <- [
          {"CMS_IMAGE", Keyword.get(opts, :image)},
          {"CMS_DEPLOY_HOST", Keyword.get(opts, :host)},
          {"CMS_DEPLOY_HOST_IP", Keyword.get(opts, :host_ip)},
          # The decryption key, straight from `ProjectSecrets` to the script's
          # environment. `bin/deploy` reads it from `envs/<env>.age.key` when
          # a human runs it, and setup deliberately never writes that file —
          # the private half of an age key is the one thing kept out of the
          # repository. An environment variable carries it without ever
          # touching the working tree.
          {"SOPS_AGE_KEY", Keyword.get(opts, :age_key)},
          # kamal will not render a config without a registry password, and
          # logs in with it before pulling. The registry is the project's own,
          # on its own private network, and this is its credential.
          {"KAMAL_REGISTRY_USERNAME", Keyword.get(opts, :registry_username)},
          {"KAMAL_REGISTRY_PASSWORD", Keyword.get(opts, :registry_password)},
          # kamal's own SSH offers every identity the agent holds otherwise,
          # and a box with the default `MaxAuthTries 6` disconnects before
          # reaching the right one — the same failure the builder's SSH had,
          # and the same fix.
          {"CMS_SSH_KEY_PATH", Keyword.get(opts, :ssh_key_path)},
          # Unset everywhere a real box is involved, because a real box is on
          # 22. It exists so the local fleet can be deployed to over a
          # published loopback port, and the reason that matters is that the
          # fleet is only worth having if it runs this deploy rather than an
          # imitation of it — the moment it needs its own path, it stops
          # answering the question it was built to answer.
          {"CMS_SSH_PORT", port_option(Keyword.get(opts, :ssh_port))}
        ],
        is_binary(value) and value != "" do
      {name, value}
    end
  end

  # `script_env/1` keeps only binaries, which is what stops an unset value from
  # reaching the script as "" — a distinction it cannot otherwise make. A port
  # arrives as an integer, so it has to become one here or be silently dropped.
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
      # Words, not `inspect/1`. Every caller interpolates this into a sentence a
      # human reads, and a struct cannot survive that: four drills reported
      # `%Req.TransportError{reason: :timeout}` on the setup page while the
      # formatter that exists to prevent exactly this never saw it, because
      # what reached it was already a binary.
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

  @doc """
  Install an uptime monitor for every public host.

  Criterion 8010 wants a monitor per host AND somewhere for it to shout — a
  monitor with no notification target is a monitor nobody hears, so
  `:notify` is required rather than optional.
  """
  @spec ensure_monitors([String.t()], keyword()) ::
          {:ok, [map()]} | {:error, :no_notification_target} | {:error, term()}
  def ensure_monitors(hosts, opts \\ []) do
    case Keyword.get(opts, :notify) do
      target when is_binary(target) and target != "" ->
        UptimeRobot.ensure_monitors(hosts, target, opts)

      _ ->
        {:error, :no_notification_target}
    end
  end

  defp plug_opt do
    case Application.get_env(:code_my_spec, __MODULE__, [])[:plug] do
      nil -> []
      plug -> [plug: plug]
    end
  end

  # Relative to the *project*, not to whatever directory the caller happens to
  # be in. `System.cmd/3` resolves a relative command against the running
  # process's cwd, not the environment's, so `bin/backup` was looked for beside
  # the server rather than beside the project and failed with :enoent — an
  # error that names nothing and reads like the script was never generated.
  defp resolve_script(%{cwd: cwd}, script) when is_binary(cwd) and cwd != "" do
    if Path.type(script) == :absolute, do: script, else: Path.join(cwd, script)
  end

  defp resolve_script(_env, script), do: script
end
