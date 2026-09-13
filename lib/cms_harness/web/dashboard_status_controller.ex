defmodule CmsHarness.Web.DashboardStatusController do
  @moduledoc """
  What this harness's own analyzer queues actually believe right now, for
  the dev dashboard.

  `AnalysisServer.status/1` is the one place that knows the difference
  between "one execution four requests are tied to" and "four things
  happening at once" — the `analysis_runs` ledger cannot draw that line,
  since every tied request is its own `:running` row there. This is that
  answer, plus the machine-wide facts (`AnalysisSlots`, load, swap) no
  single project's row could carry.

  Unaddressed, unlike the hook surface: this reports on every project the
  harness holds, not one working copy, so there is no id to resolve.
  """

  use Phoenix.Controller, formats: [:json]

  alias CmsHarness.AnalysisSlots
  alias CmsHarness.Project.AnalysisServer
  alias CmsHarness.Projects

  def index(conn, _params) do
    json(conn, %{
      instance: node_instance(),
      slots: %{
        in_use: AnalysisSlots.in_use(),
        waiting: AnalysisSlots.waiting(),
        limit: AnalysisSlots.limit()
      },
      machine: machine_stats(),
      projects: Enum.map(Projects.list(), &project_status/1)
    })
  end

  defp node_instance, do: "#{node_label()}:#{System.pid()}"

  defp node_label do
    :inet.gethostname()
    |> elem(1)
    |> to_string()
  rescue
    _ -> "unknown"
  end

  defp project_status(root) do
    %{root: root, queue: AnalysisServer.status(root) || %{running: nil, queued: []}}
  end

  # Best-effort and macOS-specific (`uptime`, `sysctl vm.swapusage`) — the
  # same two commands this session ran by hand all night to tell "the box is
  # loaded" from "the code is broken". `nil` fields rather than a crashed
  # request on a machine where either command is missing or shaped
  # differently; a dashboard with half its facts is still worth more than
  # one that 500s.
  defp machine_stats do
    %{
      schedulers: System.schedulers_online(),
      load_average: load_average(),
      swap: swap_usage()
    }
  end

  defp load_average do
    case System.cmd("uptime", []) do
      {output, 0} -> parse_load_average(output)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @load_average_pattern ~r/load averages?:\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)/

  defp parse_load_average(output) do
    case Regex.run(@load_average_pattern, output) do
      [_, one, five, fifteen] ->
        %{
          "1m" => String.to_float(one),
          "5m" => String.to_float(five),
          "15m" => String.to_float(fifteen)
        }

      nil ->
        nil
    end
  end

  defp swap_usage do
    case System.cmd("sysctl", ["-n", "vm.swapusage"]) do
      {output, 0} -> parse_swap_usage(output)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @swap_usage_pattern ~r/total = ([\d.]+)M\s+used = ([\d.]+)M\s+free = ([\d.]+)M/

  defp parse_swap_usage(output) do
    case Regex.run(@swap_usage_pattern, output) do
      [_, total, used, free] ->
        %{
          "total_mb" => String.to_float(total),
          "used_mb" => String.to_float(used),
          "free_mb" => String.to_float(free)
        }

      nil ->
        nil
    end
  end
end
