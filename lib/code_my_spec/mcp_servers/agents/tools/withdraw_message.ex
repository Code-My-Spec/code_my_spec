defmodule CodeMySpec.McpServers.Agents.Tools.WithdrawMessage do
  @moduledoc """
  Take back a message sent with `message_agent` that the agent has not picked
  up yet (story 1051).

  The cockpit's Withdraw, for main and the operator: the same mailbox claim
  decides it, so a withdrawal and the agent taking the message have one
  winner. Only agents on the caller's own project are reachable.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Utils.MapAccess

  schema do
    field :agent_id, :string, required: true, description: "Id of the agent the message was sent to"

    field :message_id, :string,
      required: true,
      description: "The message id `message_agent` replied with"
  end

  @impl true
  def execute(params, frame) do
    agent_id = MapAccess.get(params, :agent_id)

    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, _agent} <- on_project(scope, agent_id),
         {:ok, _message} <-
           Agents.withdraw_message(scope, agent_id, MapAccess.get(params, :message_id)) do
      {:reply, Response.text(Response.tool(), "Withdrawn. Agent #{agent_id} will not see it."),
       frame}
    else
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error(refusal(reason)), frame}
    end
  end

  defp on_project(scope, agent_id) do
    case Agents.fetch_agent(scope, agent_id) do
      {:ok, agent} -> {:ok, agent}
      _ -> {:error, :not_found}
    end
  end

  defp refusal(:already_delivered),
    do: "The agent already has this message, so it cannot be withdrawn."

  defp refusal(:not_pending), do: "No message with that id is waiting for this agent."
  defp refusal(:not_found), do: "No agent with that id is on this project."
  defp refusal(reason) when is_binary(reason), do: reason
  defp refusal(reason), do: "Could not withdraw the message: #{inspect(reason)}"
end
