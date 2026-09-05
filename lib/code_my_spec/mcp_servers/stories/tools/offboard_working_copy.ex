defmodule CodeMySpec.McpServers.Stories.Tools.OffboardWorkingCopy do
  @moduledoc """
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
  story 892's premise — so failing to reach an agent cannot block the offboard.
  It is said instead: the process may still be running, and ending it is the
  operator's, because the server could not reach it to try.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.WorkingCopies

  schema do
    field :working_copy_id, :string,
      required: true,
      description: "Id of the working copy to discard. `list_working_copies` names them."
  end

  @impl true
  def execute(%{working_copy_id: id}, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} -> {:reply, offboard(scope, id), frame}
      {:error, reason} -> {:reply, Response.tool() |> Response.error(refusal(reason)), frame}
    end
  end

  defp offboard(scope, id) do
    case WorkingCopies.fetch(id) do
      {:ok, copy} -> discard(scope, copy)
      _ -> Response.tool() |> Response.error("No working copy has the id #{id}.")
    end
  end

  defp discard(scope, copy) do
    case WorkingCopies.offboard(scope, copy) do
      {:ok, counts} ->
        Response.tool() |> Response.text(report(copy, counts))

      {:error, :not_yours} ->
        Response.tool()
        |> Response.error(
          "That working copy belongs to a different project, so this call cannot " <>
            "discard it. Nothing was changed."
        )

      {:error, reason} ->
        Response.tool()
        |> Response.error("The working copy could not be discarded: #{inspect(reason)}")
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

  defp refusal(:no_working_dir) do
    "This call names no project, so there is nothing to discard a working copy " <>
      "from. The project is resolved from the working directory the call came from."
  end

  defp refusal(reason), do: "This call has no usable project scope (#{inspect(reason)})."
end
