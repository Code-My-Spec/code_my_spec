defmodule CodeMySpec.WorkingCopies.Tools.SyncWorkingCopy do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Analysis
  alias CodeMySpec.AppInstances
  alias CodeMySpec.WorkingCopies

  @timeout :timer.minutes(2)

  @impl true
  def name, do: "sync_working_copy"

  @impl true
  def description do
    """
    Bring a working copy's checkout up to date with its remote's main.

    On a main copy with pending or failed publication synchronization, retries
    that exact published revision and its app lifecycle on the destination's
    harness. It does not promote or publish the candidate again. Offline work
    remains pending until the harness reconnects; list_working_copies shows its status.

    8f5ebfb2: asked to staff a working copy reported days behind main, there
    was no reachable way to catch it up first -- `list_working_copies`,
    `create_working_copy`, `offboard_working_copy`, `set_working_copy_loop` and
    `assign_epic_to_working_copy` all leave the checkout on disk untouched, and
    `sync_project` reconciles the CALLING copy's own files against its
    database row rather than fetching or merging anything. This reaches the
    named copy's own harness over the same channel `offboard_working_copy`
    already addresses it through.

    Fast-forward only, and refused on a dirty tree -- never a merge commit or a
    merge into someone's uncommitted work made on this call's own say-so. Both
    failure shapes are reported with the git output that explains them, so the
    decision of what to do next stays with whoever is staffing the copy.
    """
  end

  @impl true
  def params do
    %{
      working_copy_id:
        {:required,
         {:meta, :string,
          [description: "Id of the working copy to sync. `list_working_copies` names them."]}}
    }
  end

  @impl true
  def call(%{working_copy_id: id}, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} -> sync(scope, id)
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp sync(scope, id) do
    case WorkingCopies.fetch(id) do
      {:ok, copy} -> sync_copy(scope, copy)
      _ -> {:error, "No working copy has the id #{id}."}
    end
  end

  defp sync_copy(
         %{active_project_id: project_id} = scope,
         %{project_id: project_id, main: true} = copy
       )
       when is_binary(project_id) do
    case AppInstances.for_working_copy(scope, copy.id) do
      %{promotion_sync: %{"status" => status}} when status in ["pending", "failed"] ->
        case CodeMySpec.Promotion.DeviceSync.retry(scope, copy.id) do
          {:ok, state} ->
            {:ok,
             "Device synchronization retry requested for published revision #{state["head"]}. " <>
               "Status: #{state["status"]}. Offline work resumes on reconnect. " <>
               "Use list_working_copies to check completion; do not promote again."}

          {:error, reason} ->
            {:error, failure(copy, reason)}
        end

      _ ->
        sync_checkout(copy)
    end
  end

  defp sync_copy(%{active_project_id: project_id}, %{project_id: project_id} = copy)
       when is_binary(project_id),
       do: sync_checkout(copy)

  defp sync_copy(%{}, %{}) do
    {:error,
     "That working copy belongs to a different project, so this call cannot sync it. " <>
       "Nothing was changed."}
  end

  defp sync_checkout(copy) do
    case Analysis.harness_fs_request(copy.id, "sync_to_main", %{}, @timeout) do
      {:ok, result} -> {:ok, report(copy, result)}
      {:error, reason} -> {:error, failure(copy, reason)}
    end
  end

  defp report(copy, %{"updated" => false, "from" => sha}) do
    "#{copy.root || copy.id} was already at main's HEAD (#{sha}). Nothing to merge."
  end

  defp report(copy, %{"from" => from, "to" => to}) do
    "#{copy.root || copy.id} is now at #{to} (was #{from}), fast-forwarded onto its remote's main."
  end

  defp report(copy, _result), do: "#{copy.root || copy.id} was synced."

  defp failure(copy, %{"tag" => "dirty_tree"} = reason) do
    "#{copy.root || copy.id} was not synced: #{detail(reason)}. Commit or discard what is " <>
      "there, then ask again."
  end

  defp failure(copy, %{"tag" => "not_fast_forward"} = reason) do
    "#{copy.root || copy.id} was not synced: its history has diverged from main's, and a " <>
      "merge here would not be a fast-forward (#{detail(reason)}). This call refuses to make " <>
      "a merge commit on anyone's behalf -- resolve it from the working copy directly."
  end

  defp failure(copy, %{"tag" => _} = reason) do
    "#{copy.root || copy.id} was not synced: #{detail(reason)}"
  end

  defp failure(copy, {:harness_not_registered, _}) do
    "#{copy.root || copy.id}'s harness is not connected, so there is nothing to ask. " <>
      "Nothing was changed."
  end

  defp failure(copy, reason), do: "#{copy.root || copy.id} was not synced: #{inspect(reason)}"

  defp detail(%{"detail" => detail}) when is_binary(detail), do: detail
  defp detail(_), do: "no further detail was given"

  defp refusal(:missing_active_project) do
    "This call names no project, so there is nothing to sync a working copy for. " <>
      "The project is resolved from the working directory the call came from."
  end

  defp refusal(reason), do: "This call has no usable project scope (#{inspect(reason)})."
end
