defmodule CodeMySpec.Provisioning.ClickHouse.Capacity do
  @moduledoc false

  alias CodeMySpec.Provisioning.ClickHouse.Runtime

  @reserve_mib 256
  @limits %{
    full: %{"cms-clickhouse" => 1280, "cms-otel-collector" => 384, "cms-vector" => 256},
    capped: %{"cms-clickhouse" => 768, "cms-otel-collector" => 384, "cms-vector" => 256},
    collector_only: %{"cms-otel-collector" => 384}
  }

  @command ~S"""
  set -eu
  awk '/^MemAvailable:/ {print "FREE_KIB=" $2; found=1} END {if (!found) exit 1}' /proc/meminfo
  docker ps --format '{{.Names}}'
  """

  def check(run, mode) when mode in [:full, :capped, :collector_only] do
    with {:ok, output} <- Runtime.capture(run, @command, "host capacity check"),
         {:ok, free_mib, containers} <- parse(output) do
      limits = Map.fetch!(@limits, mode)
      missing = Enum.reject(limits, fn {name, _} -> name in containers end)

      needed_mib =
        if missing == [], do: 0, else: @reserve_mib + Enum.sum(Enum.map(missing, &elem(&1, 1)))

      if free_mib >= needed_mib do
        {:ok, %{mode: mode, free_mib: free_mib, needed_mib: needed_mib}}
      else
        other_apps = containers -- ["cms-clickhouse", "cms-otel-collector", "cms-vector"]
        names = if other_apps == [], do: "none reported", else: Enum.join(other_apps, ", ")

        {:error,
         "telemetry #{mode} needs #{needed_mib} MiB free; host has #{free_mib} MiB free. Other containers sharing the box: #{names}. Choose collector_only or capped mode, or add memory. Nothing was started."}
      end
    end
  end

  defp parse(output) do
    case String.split(output, "\n", trim: true) do
      ["FREE_KIB=" <> value | containers] ->
        case Integer.parse(value) do
          {kib, ""} when kib >= 0 -> {:ok, div(kib, 1024), containers}
          _ -> {:error, "could not read host available memory; telemetry was not started"}
        end

      _ ->
        {:error, "could not read host available memory; telemetry was not started"}
    end
  end
end
