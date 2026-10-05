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

  @doc "The ids of the project's agents whose processes are alive now."
  @spec ids(Ecto.UUID.t() | nil) :: MapSet.t(Ecto.UUID.t())
  def ids(nil), do: MapSet.new()
  def ids(project_id), do: project_id |> topic() |> list() |> Map.keys() |> MapSet.new()

  @doc "Whether the agent `agent_id` of `project_id` has a live process now."
  @spec present?(Ecto.UUID.t() | nil, Ecto.UUID.t()) :: boolean()
  def present?(nil, _agent_id), do: false
  def present?(project_id, agent_id), do: project_id |> topic() |> get_by_key(agent_id) != []
end
