defmodule CodeMySpec.MainAgent.RestartRepository do
  @moduledoc """
  What has already been tried on an agent, and whether it worked.

  ## Worked means the agent spoke afterwards

  A restart is resolved when the agent said something on its own thread later
  than the restart. That is what "works again" means for an agent, and it is the
  only signal that is about the agent rather than about something near it.

  The first attempt at this asked the *machine* — whether the working copy had
  reported a usable tool list since — and it was wrong in a way worth recording,
  because it looked right. On a healthy machine that stamp moves on every join,
  so every restart resolved within seconds and the refusal criterion 3292 exists
  for could never fire. It only appeared to work because the scenario that
  exercised it happened to use a machine-level fault.

  ## Settled lazily, against an interval

  The interval is the point and a current reading cannot supply it: an agent
  that recovered and went quiet again looks exactly like one that never
  recovered, and those are the two cases criteria 3302 and 3292 pull apart.

  Settled on read rather than written by whatever ends the silence, because the
  thing that ends it is a turn arriving on a channel — which knows nothing about
  restarts and should not have to.
  """

  import Ecto.Query

  alias CodeMySpec.Conversations.Conversation
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.MainAgent.Restart
  alias CodeMySpec.Repo

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
  Restarts of this agent for this reason that it has not spoken since, oldest
  first.
  """
  @spec unresolved(map(), String.t()) :: [Restart.t()]
  def unresolved(agent, reason) do
    agent
    |> outstanding()
    |> Enum.filter(&(&1.reason == reason))
  end

  @doc """
  The distinct reasons this agent was restarted for and has not spoken since.

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

  @doc """
  Close every outstanding restart the agent has spoken since.

  Written down rather than left to the lazy filter, because criterion 3302 asks
  for the reason to be *recorded* as resolved and a row merely filtered out of a
  count has not been.
  """
  @spec settle(map()) :: :ok
  def settle(agent) do
    settle_before(id_of(agent), spoke_at(agent))
  end

  defp outstanding(agent) do
    agent_id = id_of(agent)
    spoke_at = spoke_at(agent)

    from(r in Restart,
      where: r.agent_id == type(^agent_id, :binary_id),
      where: is_nil(r.resolved_at),
      order_by: [asc: r.inserted_at]
    )
    |> Repo.all()
    |> Enum.reject(&worked?(&1, spoke_at))
  end

  defp settle_before(_agent_id, nil), do: :ok

  defp settle_before(agent_id, spoke_at) do
    from(r in Restart,
      where: r.agent_id == type(^agent_id, :binary_id),
      where: is_nil(r.resolved_at) and r.inserted_at < ^spoke_at
    )
    |> Repo.update_all(set: [resolved_at: spoke_at])

    :ok
  end

  defp worked?(_restart, nil), do: false
  defp worked?(restart, spoke_at), do: DateTime.compare(spoke_at, restart.inserted_at) == :gt

  # When the agent last said anything on its own thread.
  #
  # The messages rather than `agents.updated_at`: the row moves for reasons that
  # have nothing to do with the agent working — a status change, a task claimed,
  # and the restart itself, which would resolve every restart the moment it was
  # performed.
  defp spoke_at(agent) do
    agent_id = id_of(agent)

    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where: c.agent_id == type(^agent_id, :binary_id),
      # What the *agent* said. A message sent to it is not it speaking, and
      # counting one would make an agent that has gone quiet look alive every
      # time the orchestrator wrote to it.
      where: m.role == :assistant,
      select: max(m.inserted_at)
    )
    |> Repo.one()
  end

  # An `Agent` row and a `MainAgent.AgentWork` entry both arrive here and name
  # the agent differently. Answered once rather than at each call site, because
  # a caller that reaches for the wrong key gets an empty history and reads it
  # as "nothing has been tried" — the most expensive way for this to be wrong.
  defp id_of(%{agent_id: agent_id}) when is_binary(agent_id), do: agent_id
  defp id_of(%{id: id}), do: id
end
