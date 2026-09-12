defmodule CodeMySpec.MainAgent.RestartRepository do
  @moduledoc """
  What has already been tried on an agent, and whether it worked.

  ## Resolution is settled lazily, against an interval

  A restart is resolved when the agent's machine was seen able to run something
  *after* it — `working_copies.tools_seen_at` later than the restart. The
  interval is the whole point and a current reading cannot supply it: a fault
  that cleared and came back looks exactly like one that never cleared, and
  those are the two cases criteria 3302 and 3292 pull apart.

  Settled on read rather than written by whatever clears the fault, because the
  thing that clears it is a machine reporting its tools on a channel — which
  knows nothing about restarts and should not have to.

  ## `tools_seen_at` is one signal, not the general one

  "The agent works again" would be better answered by a turn completing, and an
  agent broken badly enough to be restarted usually never gets that far. The
  tool list is what a machine reports on every join, so it is available for
  exactly the faults this story is about — and its limits are worth knowing:
  a fault that is not about tools resolves here the first time the machine says
  anything, which is optimistic. That direction is the safe one. It errs toward
  letting the main agent try again rather than toward refusing an agent that
  could have been fixed.
  """

  import Ecto.Query

  alias CodeMySpec.MainAgent.Restart
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @doc """
  Record that this agent was restarted, and why.
  """
  @spec record(map(), String.t()) :: {:ok, Restart.t()} | {:error, Ecto.Changeset.t()}
  def record(%{id: agent_id, project_id: project_id}, reason) do
    %Restart{}
    |> Restart.changeset(%{agent_id: agent_id, project_id: project_id, reason: reason})
    |> Repo.insert()
  end

  @doc """
  Restarts of this agent for this reason that the agent has not been seen
  working after, oldest first.
  """
  @spec unresolved(map(), String.t()) :: [Restart.t()]
  def unresolved(agent, reason) do
    agent
    |> outstanding()
    |> Enum.filter(&(&1.reason == reason))
  end

  @doc """
  The distinct reasons this agent has been restarted for and not been seen
  working after.

  What the main agent is told about when it looks: a remedy applied and a fault
  still here. Distinct, because three failed attempts at one fault is one thing
  to report rather than three.
  """
  @spec unresolved_reasons(map()) :: [String.t()]
  def unresolved_reasons(agent) do
    agent
    |> outstanding()
    |> Enum.map(& &1.reason)
    |> Enum.uniq()
  end

  defp outstanding(agent) do
    agent_id = id_of(agent)
    seen_at = tools_seen_at(agent)

    from(r in Restart,
      where: r.agent_id == type(^agent_id, :binary_id),
      where: is_nil(r.resolved_at),
      order_by: [asc: r.inserted_at]
    )
    |> Repo.all()
    |> Enum.reject(&worked?(&1, seen_at))
  end

  @doc """
  Close every outstanding restart the agent has since been seen working after.

  Written down rather than left to the lazy filter so the record says what
  happened: criterion 3302 asks for the reason to be *recorded* as resolved, and
  a row that is merely filtered out of a count has not been.
  """
  @spec settle(map()) :: :ok
  def settle(agent) do
    settle_before(id_of(agent), tools_seen_at(agent))
  end

  # An `Agent` row and a `MainAgent.AgentWork` entry both arrive here and name
  # the agent differently. Answered once rather than at each call site, because
  # a caller that reaches for the wrong key gets an empty history and reads it
  # as "nothing has been tried" — the most expensive way for this to be wrong.
  defp id_of(%{agent_id: agent_id}) when is_binary(agent_id), do: agent_id
  defp id_of(%{id: id}), do: id

  defp settle_before(_agent_id, nil), do: :ok

  defp settle_before(agent_id, seen_at) do
    from(r in Restart,
      where: r.agent_id == type(^agent_id, :binary_id),
      where: is_nil(r.resolved_at) and r.inserted_at < ^seen_at
    )
    |> Repo.update_all(set: [resolved_at: seen_at])

    :ok
  end

  defp worked?(_restart, nil), do: false
  defp worked?(restart, seen_at), do: DateTime.compare(seen_at, restart.inserted_at) == :gt

  defp tools_seen_at(%{working_copy_id: nil}), do: nil

  defp tools_seen_at(%{working_copy_id: working_copy_id}) do
    from(w in WorkingCopy, where: w.id == ^working_copy_id, select: w.tools_seen_at)
    |> Repo.one()
  end
end
