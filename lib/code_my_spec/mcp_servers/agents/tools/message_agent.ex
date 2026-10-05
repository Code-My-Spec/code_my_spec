defmodule CodeMySpec.McpServers.Agents.Tools.MessageAgent do
  @moduledoc """
  Give a running agent a message and return its delivery disposition.

  Without this an agent could be started, listed and stopped, and never asked
  to do anything — it came up idle and stayed idle until somebody stopped it.
  It cost nothing, which is why nothing complained, and it also did nothing.

  This is the capability the engine change was chosen for. Delivering a message
  to a detached `pi` process would have meant a named pipe with a writer inside
  the agent's own process group so it never saw EOF, plus a protocol nobody had
  written down. To a supervised process it is a call, and this is the surface
  on top of it.

  Wait only for admission: an idle agent starts, and a busy agent queues the
  message for its next turn boundary. The response arrives in the agent's
  conversation. Queuing does not count as delivery when judging its Offer.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Main, as: MainAgent
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
      response =
        agent_id(params)
        |> AgentsMapper.replied(reply)
        |> with_pending_question(scope, frame.assigns[:agent_id], agent_id(params))

      {:reply, response, frame}
    else
      {:error, reason} -> {:reply, AgentsMapper.error(reason, nil), frame}
    end
  end

  # c99aad08: main answered a teammate's question by messaging it, so the
  # question stayed pending and the teammate rightly refused an answer nothing
  # recorded. The message still goes; main is told how to answer so it counts.
  defp with_pending_question(response, scope, caller_id, target_id)
       when is_binary(caller_id) and is_binary(target_id) do
    with {:ok, %{role: :main}} <- Agents.fetch_agent(scope, caller_id),
         [_ | _] = ids <- questions_to_main(scope, target_id) do
      Response.text(response, pending_hint(ids))
    else
      _ -> response
    end
  end

  defp with_pending_question(response, _scope, _caller_id, _target_id), do: response

  defp questions_to_main(scope, target_id) do
    for %{kind: :question, holder: "main_agent", agent_id: ^target_id, id: id} <-
          MainAgent.list_open_questions(scope),
        do: id
  end

  defp pending_hint(ids) do
    "This agent is waiting on question #{Enum.join(ids, ", ")}, addressed to you. " <>
      "A message does not answer it: answer it with `answer_notification` (through " <>
      "`run_script`) so it is recorded and reaches the agent."
  end

  defp agent_id(params), do: MapAccess.get(params, :agent_id)
  defp message(params), do: MapAccess.get(params, :message)
end
