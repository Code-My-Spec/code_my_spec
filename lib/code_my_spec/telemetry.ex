defmodule CodeMySpec.Telemetry do
  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Observability,
      CodeMySpec.Provisioning,
      CodeMySpec.Repo,
      CodeMySpec.Users.Scope
    ],
    exports: :all

  @moduledoc """
  Collects a deployed project's logs and traces into the owner's own
  ClickHouse, and lets owners and agents query them.

  Setup, health checks and queries each go through one injectable probe
  (`opts[:run_probe]`, `opts[:check_probe]`, `opts[:query_probe]`) -- the
  same seam `CodeMySpec.Provisioning.Deploy.probe/2` uses for TLS: the
  default probe makes the real call, and a caller that already knows the
  answer (a spec, a resumed run) can supply its own instead.

  Setup refuses to run ahead of the environment's own server -- there is
  nowhere to run a collector otherwise, the same `EnvironmentRepository`
  address check `Steps.on_the_environments_box/3` makes before backups.
  """

  alias CodeMySpec.Provisioning.EnvironmentRepository
  alias CodeMySpec.Users.Scope

  @retention_days 14

  @type resource :: %{kind: String.t(), location: String.t(), identifier: String.t() | nil}
  @type health :: %{
          reachable: boolean(),
          reads: :ok | :error,
          writes: :ok | :refused | :error,
          checked_at: DateTime.t()
        }

  @doc "How long telemetry data is kept, in days."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @doc """
  Set up telemetry collection for one environment.

  Idempotent, like every other provisioning step's `run/3` -- re-running
  on a working stack proves the collector again rather than resetting it.
  """
  @spec run(Scope.t(), String.t(), keyword()) :: {:ok, [resource()]} | {:error, String.t()}
  def run(%Scope{} = scope, environment, opts \\ []) when is_binary(environment) do
    with :ok <- require_server(scope, environment) do
      probe = Keyword.get(opts, :run_probe, &default_run_probe/1)

      probe_opts = opts |> Keyword.put(:scope, scope) |> Keyword.put(:environment, environment)

      case probe.(probe_opts) do
        {:ok, _proof} -> {:ok, resources(environment)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Check telemetry health: reachability over HTTPS, that the read-only
  login can read, and that it cannot write.

  Manual only -- nothing calls this on its own, the same design
  `CodeMySpec.Provisioning.Step` documents for every other step's checks.
  """
  @spec check(Scope.t(), String.t(), keyword()) :: health()
  def check(%Scope{} = scope, environment, opts \\ []) when is_binary(environment) do
    probe = Keyword.get(opts, :check_probe, &default_check_probe/1)
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)

    result =
      opts
      |> Keyword.put(:scope, scope)
      |> Keyword.put(:environment, environment)
      |> probe.()
      |> Map.put(:checked_at, now.())

    attrs = Map.merge(result, %{project_id: scope.active_project_id, environment: environment})

    %CodeMySpec.Telemetry.HealthCheck{}
    |> CodeMySpec.Telemetry.HealthCheck.changeset(attrs)
    |> CodeMySpec.Repo.insert!(
      on_conflict: {:replace, [:reachable, :reads, :writes, :checked_at]},
      conflict_target: [:project_id, :environment]
    )

    result
  end

  @doc "The latest completed check for this project and environment, without running a probe."
  @spec last_check(Scope.t(), String.t() | nil) :: health() | nil
  def last_check(%Scope{active_project_id: project_id}, environment)
      when is_binary(project_id) and is_binary(environment) do
    case CodeMySpec.Repo.get_by(CodeMySpec.Telemetry.HealthCheck,
           project_id: project_id,
           environment: environment
         ) do
      nil -> nil
      check -> Map.take(check, [:reachable, :reads, :writes, :checked_at])
    end
  end

  def last_check(%Scope{}, _environment), do: nil

  @doc """
  Query collected logs and traces for one environment, scoped to the
  calling project -- never another project's, even when they share a
  server.

  Defaults to this module's own retention window: nothing older could
  have survived it anyway.
  """
  @spec query(Scope.t(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def query(%Scope{active_project_id: project_id} = scope, environment, opts \\ [])
      when is_binary(project_id) and is_binary(environment) do
    probe = Keyword.get(opts, :query_probe, &default_query_probe/1)

    opts
    |> Keyword.put(:scope, scope)
    |> Keyword.put(:environment, environment)
    |> Keyword.put(:project_id, project_id)
    |> Keyword.put_new(:since_days, retention_days())
    |> probe.()
  end

  ## -- Private --

  defp require_server(scope, environment) do
    case EnvironmentRepository.get(scope, environment) do
      %{ip: ip} when is_binary(ip) and ip != "" ->
        :ok

      _ ->
        {:error, "no server is provisioned for #{environment} -- set one up first"}
    end
  end

  defp resources(environment) do
    [
      %{kind: "telemetry_collector", location: "clickhouse/#{environment}", identifier: nil},
      %{kind: "telemetry_dns", location: "telemetry.#{environment}", identifier: nil},
      %{
        kind: "telemetry_retention",
        location: "clickhouse/#{environment}",
        identifier: to_string(retention_days())
      },
      %{
        kind: "telemetry_credential",
        location: "clickhouse/#{environment}",
        identifier: "read-only"
      }
    ]
  end

  defp default_run_probe(opts) do
    CodeMySpec.Provisioning.ClickHouse.run(Keyword.fetch!(opts, :scope), opts[:environment], opts)
  end

  defp default_check_probe(opts) do
    CodeMySpec.Telemetry.Reader.check(Keyword.fetch!(opts, :scope), opts[:environment])
  end

  defp default_query_probe(opts) do
    CodeMySpec.Telemetry.Reader.query(Keyword.fetch!(opts, :scope), opts[:environment], opts)
  end
end
