defmodule CodeMySpec.MainAgent.MachineryRepository do
  @moduledoc """
  Reads the state of everything this project's agents depend on.

  ## The one place a main agent sees past its project

  Criterion 3325. Every other view here is project-scoped and right to be; the
  harness and the box are shared, and a fault in them is a fault in this
  project's agents whatever else is on them. Without that reach the main agent
  can see its agents stuck, see nothing wrong with anything it owns, and have no
  way to learn the machine is carrying two other projects as well — every fact
  true and the available conclusion wrong.

  The exception is bounded and the boundary is here: what crosses the project
  line is a *count* of other checkouts on the same device and the device's own
  load. Not their agents, not their work, not their names. Criterion 3326 is the
  other half — seeing is not acting.
  """

  import Ecto.Query

  alias CodeMySpec.Agents
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Fingerprint
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Devices.Device
  alias CodeMySpec.MainAgent.Machinery
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @sources ~w(compiler credo exunit spex)

  @doc "Everything under this project's agents, as it stands."
  @spec check(Scope.t()) :: Machinery.t()
  def check(%Scope{} = scope) do
    agents = Agents.list_running(scope)
    copies = copies(scope, agents)

    %Machinery{
      copies: copies,
      analyzers: analyzers(scope),
      machines: machines(scope, copies),
      tool_fault: Machinery.tool_fault(copies)
    }
  end

  defp copies(%Scope{active_project_id: project_id}, agents) do
    by_copy = Enum.group_by(agents, & &1.working_copy_id)

    from(w in WorkingCopy, where: w.project_id == ^project_id)
    |> Repo.all()
    |> Enum.map(fn copy ->
      %{
        working_copy_id: copy.id,
        root: copy.root,
        device_id: copy.device_id,
        # Live, never off the row. `status` is written on a clean start and a
        # clean stop; a shared harness restart or a crashed machine leaves it
        # claiming life indefinitely with nothing behind it.
        connected?: connected?(copy.id),
        machine_tools: copy.machine_tools,
        preview_status: copy.preview_status,
        preview_url: copy.preview_url,
        agent_ids: by_copy |> Map.get(copy.id, []) |> Enum.map(& &1.id)
      }
    end)
  end

  defp connected?(working_copy_id) do
    match?({:ok, _pid, _instance}, Analysis.executor_holder(working_copy_id))
  end

  # Whether each analyzer ran, and whether what it said is about the code that
  # is here now.
  #
  # `:stale` is the state worth the trouble. A completed run whose fingerprint
  # no longer matches is well-formed, green and about code that is gone — and it
  # fails safe, which is why a broken analyzer that errors gets fixed within the
  # hour and one answering from last week is trusted indefinitely.
  defp analyzers(%Scope{} = scope) do
    Enum.map(@sources, fn source ->
      %{
        source: source,
        state: analyzer_state(scope, source),
        finished_at: finished_at(scope, source)
      }
    end)
  end

  defp analyzer_state(scope, source) do
    scope
    |> latest_run(source)
    |> state_of(Fingerprint.current(scope, source))
  end

  defp state_of(nil, _current), do: :never_run
  defp state_of(%Run{status: :failed}, _current), do: :failed
  defp state_of(%Run{completed_fingerprint: current}, current) when is_binary(current), do: :fresh
  defp state_of(%Run{}, _current), do: :stale

  defp finished_at(scope, source) do
    case latest_run(scope, source) do
      nil -> nil
      run -> run.finished_at
    end
  end

  defp latest_run(%Scope{active_project_id: project_id} = scope, source) do
    from(r in Run,
      where: r.project_id == ^project_id and r.source == ^source and r.kind == :full,
      where: r.status in [:completed, :failed],
      where: r.working_copy_id == ^scope.active_working_copy_id,
      order_by: [desc: r.started_at],
      limit: 1
    )
    |> Repo.one()
  end

  # The boxes this project's checkouts sit on, and what else is on them.
  #
  # A count of other projects' checkouts rather than anything about them. It is
  # the smallest fact that answers "am I alone on this machine", which is the
  # question that makes a shared fault legible — and it names nobody.
  defp machines(%Scope{active_project_id: project_id}, copies) do
    device_ids = copies |> Enum.map(& &1.device_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    tenants = other_project_counts(device_ids, project_id)

    from(d in Device, where: d.id in ^device_ids)
    |> Repo.all()
    |> Enum.map(fn device ->
      %{
        hostname: device.hostname,
        load: device.load,
        load_reported_at: device.load_reported_at,
        saturated?: Machinery.saturated?(device.load, cpu_count(device.load)),
        other_projects: Map.get(tenants, device.id, 0),
        agent_ids: agents_on(copies, device.id)
      }
    end)
  end

  defp agents_on(copies, device_id) do
    copies
    |> Enum.filter(&(&1.device_id == device_id))
    |> Enum.flat_map(& &1.agent_ids)
  end

  defp cpu_count(nil), do: nil
  defp cpu_count(load), do: load["cpu_count"]

  defp other_project_counts(device_ids, project_id) do
    from(w in WorkingCopy,
      where: w.device_id in ^device_ids and w.project_id != ^project_id,
      group_by: w.device_id,
      select: {w.device_id, count(w.project_id, :distinct)}
    )
    |> Repo.all()
    |> Map.new()
  end
end
