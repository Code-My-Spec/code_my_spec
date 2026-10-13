defmodule CodeMySpec.Agents.Presence do
  @moduledoc """
  Which agents' processes are alive, per project
  (`.code_my_spec/plans/agent-liveness-from-presence.md`).

  The copy's harness channel tracks an agent here while the harness says its
  process is up, and every key a channel tracked leaves the moment the channel
  dies. So this is current, not a record of the last report: an agent is
  present or it is not.

  Under the context rather than the web app so `Agents` can read it; the
  channel that tracks into it is web.
  """

  use Phoenix.Presence,
    otp_app: :code_my_spec,
    pubsub_server: CodeMySpec.PubSub

  @doc "The topic a project's agents are tracked on: one key per live agent."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(project_id), do: "agents_presence:#{project_id}"

  @doc """
  The ids of the project's agents whose processes are alive now — not those
  their harness gave up on (`gave_up/2`), which are tracked but not running.
  """
  @spec ids(Ecto.UUID.t() | nil) :: MapSet.t(Ecto.UUID.t())
  def ids(nil), do: MapSet.new()

  def ids(project_id) do
    for {id, %{metas: metas}} <- project_id |> topic() |> list(),
        Enum.any?(metas, &running?/1),
        into: MapSet.new(),
        do: id
  end

  @doc "Whether the agent `agent_id` of `project_id` has a live process now."
  @spec present?(Ecto.UUID.t() | nil, Ecto.UUID.t()) :: boolean()
  def present?(nil, _agent_id), do: false

  def present?(project_id, agent_id),
    do: project_id |> metas(agent_id) |> Enum.any?(&running?/1)

  @doc """
  What its harness said when it gave up on the agent — `%{reason:, at:}` — or
  nil. A Keeper that gives up on a crash loop leaves its agent tracked with that
  state rather than untracked: the agent is stuck, not merely absent, and that
  is the thing an operator has to see.
  """
  @spec gave_up(Ecto.UUID.t() | nil, Ecto.UUID.t()) :: map() | nil
  def gave_up(nil, _agent_id), do: nil

  def gave_up(project_id, agent_id) do
    metas = metas(project_id, agent_id)

    if metas != [] and not Enum.any?(metas, &running?/1),
      do: metas |> hd() |> Map.take([:reason, :at])
  end

  defp metas(project_id, agent_id) do
    case project_id |> topic() |> get_by_key(agent_id) do
      %{metas: metas} -> metas
      _ -> []
    end
  end

  defp running?(meta), do: Map.get(meta, :state) != :gave_up
end
