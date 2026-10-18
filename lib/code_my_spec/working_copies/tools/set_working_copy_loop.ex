defmodule CodeMySpec.WorkingCopies.Tools.SetWorkingCopyLoop do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.WorkingCopies

  @impl true
  def name, do: "set_working_copy_loop"

  @impl true
  def description do
    """
    Put a working copy's agents to work, or let them stop.

    Story 538's R13. Continuous mode governs whether an agent keeps working when
    its turn ends, and until this it had no front door: the only way in was an
    agent happening to work the `start_implementation` task, and the only way out
    was `tap_out`, which asks a human. Every agent in the database sat at `false`
    because nothing had ever put one anywhere else.

    ## What "working" means here

    Not that anything is assigned. The loop hands back the menu — a class of
    available work and the tool call that opens it — and the agent chooses. John,
    2026-09-05: *"I'm dubious our orchestrator will make better decisions than the
    model with the upcoming requirements and some reasoning."* So this switches on
    the thing that keeps an agent going, not a thing that tells it what to do.

    ## Per copy, because that is the unit somebody decides about

    A checkout is working or it is not. The roles staffed on it each carry their
    own mode, so a later change can let the coding agent go home when coding work
    runs out while QA carries on (R6) — but nobody wants to switch agents on one
    at a time.

    ## Stopping is not killing

    Turning it off lets the agents stop at the end of their current turn. It does
    not end them: they stay on the copy, keep their conversations, and can be put
    back to work. `offboard_working_copy` is the one that ends things.
    """
  end

  @impl true
  def params do
    %{
      working:
        {:required,
         {:meta, :boolean,
          [
            description:
              "true puts its agents in the loop — each keeps working, choosing from the menu, until nothing of its kind is left. false lets them stop after the turn they are on."
          ]}},
      working_copy_id:
        {:required,
         {:meta, :string,
          [description: "Id of the working copy. `list_working_copies` names them."]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, copy} <- fetch_copy(scope, params.working_copy_id),
         {:ok, count} <- Agents.set_copy_continuous(scope, copy.id, params.working) do
      {:ok, said(count, params.working, copy)}
    else
      {:error, :not_found} ->
        {:error, "No working copy of this project has that id. `list_working_copies` names them."}

      {:error, reason} ->
        {:error, "Could not change it: #{inspect(reason)}"}
    end
  end

  # Zero is its own answer. A copy with no live agents reports success and
  # changes nothing, which reads as "it is working now" — and nothing is.
  defp said(0, _working, copy) do
    "#{label(copy)} has no agents running, so there is nothing to put to work. " <>
      "Staff it first — approving an epic onto a copy does that."
  end

  defp said(count, true, copy) do
    "#{count} #{agents(count)} on #{label(copy)} #{are(count)} working. Each keeps going " <>
      "after its turn, choosing from the menu it is handed, until there is nothing of its " <>
      "kind left. Nothing has been assigned to anyone."
  end

  defp said(count, false, copy) do
    "#{count} #{agents(count)} on #{label(copy)} will stop after the turn #{they(count)} " <>
      "on. #{pronoun(count)} stay on the copy and can be put back to work."
  end

  defp agents(1), do: "agent"
  defp agents(_), do: "agents"
  defp are(1), do: "is"
  defp are(_), do: "are"
  defp they(1), do: "it is"
  defp they(_), do: "they are"
  defp pronoun(1), do: "It"
  defp pronoun(_), do: "They"

  defp label(%{label: label}) when is_binary(label) and label != "", do: label
  defp label(%{root: root}) when is_binary(root) and root != "", do: root
  defp label(%{id: id}), do: id

  # Same project as well as same id: `WorkingCopies.fetch/1` answers for any
  # checkout anywhere, and switching another project's copy on would be a
  # cross-project write nothing downstream would question.
  defp fetch_copy(scope, id) do
    with {:ok, copy} <- WorkingCopies.fetch(id),
         true <- copy.project_id == scope.active_project_id do
      {:ok, copy}
    else
      _ -> {:error, :not_found}
    end
  end
end
