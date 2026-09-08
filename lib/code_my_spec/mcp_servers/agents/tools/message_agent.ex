defmodule CodeMySpec.McpServers.Agents.Tools.MessageAgent do
  @moduledoc """
  Give a running agent something to do, and wait for the turn.

  Without this an agent could be started, listed and stopped, and never asked
  to do anything — it came up idle and stayed idle until somebody stopped it.
  It cost nothing, which is why nothing complained, and it also did nothing.

  This is the capability the engine change was chosen for. Delivering a message
  to a detached `pi` process would have meant a named pipe with a writer inside
  the agent's own process group so it never saw EOF, plus a protocol nobody had
  written down. To a supervised process it is a call, and this is the surface
  on top of it.

  Blocking on purpose: an operator sending work wants to know it landed. A turn
  can take minutes, so the far side answers from a task rather than holding its
  channel, and this waits for that answer.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Agents.AgentsMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Utils.MapAccess

  schema do
    field :agent_id, :string, required: true, doc: "Id of the agent to send this to"

    field :message, :string,
      required: true,
      doc: "What to tell the agent — an instruction, a question, or the next piece of work"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, reply} <- Agents.message_agent(scope, agent_id(params), message(params)) do
      {:reply, AgentsMapper.replied(agent_id(params), reply), frame}
    else
      {:error, reason} -> {:reply, AgentsMapper.error(reason, nil), frame}
    end
  end

  defp agent_id(params), do: MapAccess.get(params, :agent_id)
  defp message(params), do: MapAccess.get(params, :message)
end
