defmodule CodeMySpec.WorkingCopies.Tools.OffboardWorkingCopy do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Staffing
  alias CodeMySpec.WorkingCopies

  @impl true
  def name, do: "offboard_working_copy"

  @impl true
  def description do
    """
    Discard a working copy, ending the agents on it.

    The other end of `create_working_copy`. Story 964's rule: *a working copy is
    the boundary of the work, and discarding it ends its agents and its
    conversation*. John, 2026-09-04: *"I can keep them through that whole epic and
    then I can discard the working copy and then come up with another one — that's
    how I need to control these boundaries."*

    A boundary is only usable if both ends are reachable by whoever is doing the
    work. Until this existed, `offboard` was a control on the working-copies page
    and nothing else, so an agent could be given a copy and never let go of one.

    ## What it does not do

    Remove the directory. The copy stops being this project's and its agents stop
    running; the checkout on disk is left for a person. Deleting a worktree
    somebody may have put uncommitted work in is not a thing to do on an agent's
    say-so, and the row going is what makes everything downstream stop pointing at
    it.

    ## An agent that would not stop is reported, not swallowed

    The copy this is most often used on is one whose machine has gone — that is
    story 892's premise. Unreachable agents are reported while the source can
    still be removed, but an unreachable running app instance is refused because
    its runtime cannot safely be disposed from here.

    ## Persistent app instances

    A source checkout with a persistent app instance cannot be discarded until
    that instance is explicitly disposed. Pass `instance_disposition: "discard"`
    to stop and dispose the instance first. An unreachable running instance is
    left in place with its checkout so its runtime is not abandoned silently.
    """
  end

  @impl true
  def params do
    %{
      working_copy_id:
        {:required,
         {:meta, :string,
          [description: "Id of the working copy to discard. `list_working_copies` names them."]}},
      instance_disposition:
        {:meta, :string,
         [
           description:
             "For a persistent app instance, pass `discard` to stop and dispose it before removing its source checkout."
         ]}
    }
  end

  @impl true
  def call(%{working_copy_id: id} = params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} -> offboard(scope, id, Map.get(params, :instance_disposition))
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp offboard(scope, id, disposition) do
    case WorkingCopies.fetch(id) do
      {:ok, copy} -> discard(scope, copy, disposition)
      _ -> {:error, "No working copy has the id #{id}."}
    end
  end

  defp discard(scope, copy, disposition) do
    opts = if disposition == "discard", do: [instance_disposition: :discard], else: []

    case Staffing.offboard(scope, copy, opts) do
      {:ok, counts} ->
        {:ok, report(copy, counts)}

      {:error, :not_yours} ->
        {:error,
         "That working copy belongs to a different project, so this call cannot " <>
           "discard it. Nothing was changed."}

      {:error, :persistent_instances_require_explicit_discard} ->
        {:error,
         "This working copy owns a persistent app instance. Pass `instance_disposition: \"discard\"` to stop and dispose that instance before removing its source checkout."}

      {:error, reason} ->
        {:error, "The working copy could not be discarded: #{inspect(reason)}"}
    end
  end

  defp report(copy, %{agents_left_running: [_ | _] = left} = counts) do
    """
    Discarded #{copy.root || copy.id}.

    #{removed(counts)}
    agents stopped: #{counts.agents_stopped}

    #{length(left)} agent(s) could not be reached and may still be running on that
    machine: #{Enum.join(left, ", ")}. The checkout itself was left on disk.
    """
  end

  defp report(copy, counts) do
    """
    Discarded #{copy.root || copy.id}.

    #{removed(counts)}
    agents stopped: #{counts[:agents_stopped] || 0}

    The checkout itself was left on disk.
    """
  end

  defp removed(counts) do
    "removed: #{counts.files} file(s), #{counts.problems} problem(s), " <>
      "#{counts.components} orphaned component(s)"
  end

  defp refusal(:missing_active_project) do
    "This call names no project, so there is nothing to discard a working copy " <>
      "from. The project is resolved from the working directory the call came from."
  end

  defp refusal(reason), do: "This call has no usable project scope (#{inspect(reason)})."
end
