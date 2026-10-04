defmodule CodeMySpec.Provisioning.TelemetryStep do
  @moduledoc """
  The `:telemetry` provisioning step: set up an environment's ClickHouse
  collector.

  A Provisioning step rather than part of `Telemetry` (John, 2026-10-04):
  Telemetry reads and checks what this sets up, and sits below Provisioning.
  """

  alias CodeMySpec.Provisioning.EnvironmentRepository
  alias CodeMySpec.Telemetry
  alias CodeMySpec.Users.Scope

  @doc """
  Set up telemetry collection for one environment.

  Idempotent, like every other provisioning step's `run/3` -- re-running
  on a working stack proves the collector again rather than resetting it.
  """
  @spec run(Scope.t(), String.t(), keyword()) ::
          {:ok, [Telemetry.resource()]} | {:error, String.t()}
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
        identifier: to_string(Telemetry.retention_days())
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
end
