defmodule CodeMySpec.Provisioning.ClickHouse do
  @moduledoc """
  Installs the customer's shared ClickHouse, OTel collector and Docker log
  forwarder. Project readers are isolated by database-enforced row policies;
  the owner's separate read-only credential can query the whole box.
  """

  alias CodeMySpec.Generators.DeployArtifacts
  alias CodeMySpec.Provisioning.{Cloudflare, EnvironmentRepository, Steps, Transport}
  alias CodeMySpec.Provisioning.ClickHouse.{Credentials, Exposure, Stack}
  alias CodeMySpec.Users.Scope

  def host, do: "cms-clickhouse"
  def http_port, do: 8123
  def retention_days, do: 14

  def run(%Scope{} = scope, environment, opts \\ []) do
    with {:ok, target} <- target(scope, environment),
         {:ok, telemetry_host} <- telemetry_host(target, opts),
         {:ok, credentials} <-
           Credentials.prepare(scope, environment, target.server_id || target.ip),
         {:ok, zone} <- Cloudflare.find_zone(scope, telemetry_host),
         {:ok, _record} <-
           Cloudflare.ensure_dns_record(scope, zone["id"], telemetry_host, target.ip,
             proxied: false
           ),
         :ok <- install(scope, target, environment, telemetry_host, credentials, opts),
         :ok <- Credentials.publish(scope, environment, telemetry_host, credentials) do
      {:ok, %{host: telemetry_host, database: "otel", retention_days: retention_days()}}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "telemetry setup failed: " <> Transport.describe(reason)}
    end
  end

  defp install(scope, target, environment, telemetry_host, credentials, opts) do
    services = service_names(scope, environment)

    Steps.with_ssh_runner(scope, target.ip, opts, fn run ->
      with :ok <- CodeMySpec.Provisioning.HostBaseline.ensure(run),
           :ok <- Stack.install(run, credentials, services),
           :ok <- Exposure.publish(run, telemetry_host) do
        :ok
      end
    end)
  end

  defp target(scope, environment) do
    case EnvironmentRepository.get(scope, environment) do
      %{ip: ip} = target when is_binary(ip) and ip != "" -> {:ok, target}
      _ -> {:error, "no server is provisioned for #{environment} -- set one up first"}
    end
  end

  defp telemetry_host(target, opts) do
    host = Keyword.get(opts, :telemetry_host) || default_host(target.host)

    if is_binary(host) and byte_size(host) <= 253 and
         Regex.match?(
           ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+\z/,
           host
         ) do
      {:ok, host}
    else
      {:error, "configure a telemetry hostname on the customer's domain before setup"}
    end
  end

  defp default_host(host) when is_binary(host) and host != "", do: "telemetry.#{host}"
  defp default_host(_), do: nil

  defp service_names(scope, environment) do
    app = DeployArtifacts.otp_app_name(scope.active_project)
    service = if environment == "prod", do: app, else: "#{app}-#{environment}"
    ["#{service}-web"]
  end
end
