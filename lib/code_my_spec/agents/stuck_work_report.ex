defmodule CodeMySpec.Agents.StuckWorkReport do
  @moduledoc "Delivers one Main notification per stuck item and reporting interval."

  import Ecto.Query

  alias CodeMySpec.Agents
  alias CodeMySpec.Analysis.StuckWork.Alert
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @spec deliver(map()) :: :ok
  def deliver(%{scope: scope, kind: kind, item: item, now: now, interval: interval})
      when kind in [:run, :entry] and is_integer(interval) and interval > 0 do
    case Agents.main_agent(scope) do
      nil -> :ok
      main -> maybe_report(scope, main.id, kind, item, now, interval)
    end
  end

  defp maybe_report(scope, main_id, kind, item, now, interval) do
    id = to_string(item[:run_id] || item[:entry_id])

    attrs = %{
      project_id: scope.active_project_id,
      kind: Atom.to_string(kind),
      item_id: id,
      reported_at: now
    }

    due = DateTime.add(now, -interval, :second)

    update =
      from alert in Alert, where: alert.reported_at <= ^due, update: [set: [reported_at: ^now]]

    case Repo.insert_all(Alert, [attrs],
           on_conflict: update,
           conflict_target: [:project_id, :kind, :item_id]
         ) do
      {1, _} -> send_report(scope, main_id, kind, id, item)
      {0, _} -> :ok
    end
  end

  defp send_report(scope, main_id, kind, id, item) do
    source = Map.get(item, :source, "promotion")

    copy = Repo.get(WorkingCopy, item.working_copy_id)
    copy_name = if copy, do: copy.label || copy.id, else: item.working_copy_id
    silent_minutes = div(item.seconds_since_event, 60)

    message =
      "Stuck #{kind} #{id} (#{source}) on working copy #{copy_name}: " <>
        "#{item.age_minutes} minutes old; last heard from #{silent_minutes} minutes ago " <>
        "at #{DateTime.to_iso8601(item.last_event_at)}."

    case Agents.message_agent(scope, main_id, message) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "could not report stuck #{kind} #{id}: #{inspect(reason)}"
    end
  end
end
