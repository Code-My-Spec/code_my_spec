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

  require Logger

  alias CodeMySpec.Environments
  alias CodeMySpec.Provisioning.Deploy.UptimeRobot

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

    with {:ok, migrate_out, result} <- migrate(env, environment, script, now),
         {:ok, result} <- health(result, opts, now),
         {:ok, result} <- swap(env, environment, script, result, now) do
      %{result | output: migrate_out, live_version: :new}
    else
      {:error, %Result{} = refused} -> refused
    end
  end

  defp migrate(env, environment, script, now) do
    case Environments.cmd(env, script, ["migrate", environment]) do
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

  defp health(result, opts, now) do
    probe = Keyword.get(opts, :probe, &probe/2)
    host = Keyword.get(opts, :host)

    case probe.(host, opts) do
      :ok ->
        {:ok, %{result | health_ok_at: now.()}}

      {:error, reason} ->
        # 8009: the reason must name health, or the report is unactionable.
        {:error,
         %{
           result
           | live_version: :previous,
             failed_phase: :health,
             reason: "Health check failed for #{host}: #{reason}. The previous version is still serving."
         }}
    end
  end

  defp swap(env, environment, script, result, now) do
    case Environments.cmd(env, script, ["swap", environment]) do
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

  @doc """
  Probe a host over HTTPS.

  Redirects are NOT followed. A 301 to HTTPS is the redirect answering, not
  the app — following it would let a misconfigured `force_ssl` pass a health
  check that the proxy's own plain-HTTP probe fails.
  """
  @spec probe(String.t() | nil, keyword()) :: :ok | {:error, String.t()}
  def probe(nil, _opts), do: {:error, "no hostname given"}

  def probe(host, opts) do
    path = Keyword.get(opts, :health_path, "/health")

    req_opts =
      [
        method: :get,
        url: "https://#{host}#{path}",
        redirect: false,
        retry: false,
        receive_timeout: Keyword.get(opts, :timeout_ms, 10_000)
      ] ++ plug_opt()

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, "responded #{status}"}
      {:error, reason} -> {:error, inspect(reason)}
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
