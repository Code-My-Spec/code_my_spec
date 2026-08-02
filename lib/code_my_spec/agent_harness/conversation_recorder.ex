defmodule CodeMySpec.AgentHarness.ConversationRecorder do
  @moduledoc """
  Records a sprite's model turns onto the project's agent conversation.

  A sprite's agent points `ANTHROPIC_BASE_URL` at the local harness, so every
  turn passes through here on its way upstream. That is the only place both
  halves of a turn are visible at once — the request the agent sent and the
  response it got back.

  Recording is a side effect and never a precondition. Story 984's criterion
  8175 is explicit: the run survives the recorder failing. A watcher that can
  break the run it is watching is worse than no watcher, so every write here is
  wrapped and its failure logged rather than raised. The agent's turn is the
  product; the recording is a convenience for whoever is watching.
  """

  require Logger

  alias CodeMySpec.Conversations

  @doc """
  Record one completed turn.

  `request` and `response` are the decoded Anthropic payloads. Returns `:ok`
  regardless — see the moduledoc.
  """
  @spec record_turn(String.t(), String.t(), String.t(), map(), map()) :: :ok
  def record_turn(account_id, project_id, session_external_id, request, response) do
    safely(fn ->
      {:ok, conversation} =
        Conversations.find_or_create_agent_conversation(
          account_id,
          project_id,
          session_external_id
        )

      agent_role = agent_role(request)

      # Not add_agent_message/4: its kind mapping sends everything but "tool"
      # to :assistant, so the request would be filed as the model's own words.
      # 8171 wants the operator to see what the agent was *asked*.
      case request_text(request) do
        nil -> :ok
        text -> Conversations.add_message(conversation, :user, text, "agent:#{agent_role}")
      end

      case response_text(response) do
        nil -> :ok
        text -> Conversations.add_agent_message(conversation, agent_role, :assistant, text)
      end

      :ok
    end)
  end

  # A turn that only calls tools is still legible afterwards (8173). The model
  # answers with `tool_use` blocks and no prose, so rendering only `text` would
  # leave the conversation blank for exactly the turns that did the work.
  @doc false
  @spec response_text(map()) :: String.t() | nil
  def response_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(&block_text/1)
    |> Enum.reject(&is_nil/1)
    |> join()
  end

  def response_text(_response), do: nil

  defp block_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text

  defp block_text(%{"type" => "tool_use", "name" => name} = block) do
    "→ #{name}(#{summarize(block["input"])})"
  end

  defp block_text(%{"type" => "thinking"}), do: nil
  defp block_text(_block), do: nil

  @doc false
  @spec request_text(map()) :: String.t() | nil
  def request_text(%{"messages" => messages}) when is_list(messages) do
    messages
    |> List.last()
    |> case do
      %{"content" => content} when is_binary(content) -> content
      %{"content" => content} when is_list(content) -> response_text(%{"content" => content})
      _ -> nil
    end
  end

  def request_text(_request), do: nil

  # A sub-agent's work is distinguishable from its parent's (8172). Claude Code
  # names the spawned agent in the system prompt rather than in a field, so the
  # role is read from there and falls back to the main agent.
  @doc false
  @spec agent_role(map()) :: String.t()
  def agent_role(%{"metadata" => %{"agent_role" => role}}) when is_binary(role) and role != "",
    do: role

  def agent_role(_request), do: "main"

  defp join([]), do: nil
  defp join(parts), do: Enum.join(parts, "\n")

  defp summarize(input) when is_map(input) do
    input
    |> Map.keys()
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp summarize(_input), do: ""

  defp safely(fun) do
    _ = fun.()
    :ok
  rescue
    e ->
      Logger.warning("[ConversationRecorder] recording failed: #{Exception.message(e)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("[ConversationRecorder] recording failed: #{inspect({kind, reason})}")
      :ok
  end
end
