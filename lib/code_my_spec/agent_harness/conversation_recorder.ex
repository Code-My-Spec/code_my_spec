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

  @upstream "https://api.anthropic.com"

  @doc """
  Forward one turn upstream and record both halves.

  The proxy half of story 984: a sprite points ANTHROPIC_BASE_URL here, so this
  is a pass-through that happens to observe. The upstream response is returned
  unchanged — an agent must not be able to tell it is being watched, or the
  watching has altered the thing it set out to measure.
  """
  @spec forward(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def forward(request, opts \\ []) do
    [
      url: Keyword.get(opts, :base_url, @upstream) <> "/v1/messages",
      json: request,
      headers: passthrough_headers(opts),
      decode_json: [keys: :strings],
      # The agent already has its own retry and backoff; a second layer here
      # would turn one slow turn into several and hide the latency from both.
      retry: false,
      receive_timeout: Keyword.get(opts, :receive_timeout, 600_000)
    ]
    |> Req.new()
    |> attach_test_plug()
    |> Req.post()
    |> handle_response()
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}), do: {:ok, body}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:upstream_status, status, body}}

  defp handle_response({:error, reason}), do: {:error, reason}

  defp passthrough_headers(opts) do
    Keyword.get(opts, :headers, [])
  end

  defp attach_test_plug(req) do
    case Application.get_env(:code_my_spec, __MODULE__, [])[:plug] do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end

  @doc """
  Record one completed turn.

  `request` and `response` are the decoded Anthropic payloads. Returns `:ok`,
  or `{:error, reason}` if the conversation or a message could not be written.
  The caller is expected to ignore the error — see the moduledoc.
  """
  @spec record_turn(String.t(), String.t(), String.t(), map(), map()) ::
          :ok | {:error, term()}
  def record_turn(account_id, project_id, session_external_id, request, response) do
    agent_role = agent_role(request)

    with {:ok, conversation} <-
           Conversations.find_or_create_agent_conversation(
             account_id,
             project_id,
             session_external_id
           ),
         :ok <- write_request(conversation, agent_role, request_text(request)),
         :ok <- write_response(conversation, agent_role, response_text(response)) do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("[ConversationRecorder] recording failed: #{inspect(reason)}")
        error
    end
  end

  # Not add_agent_message/4: its kind mapping sends everything but "tool" to
  # :assistant, so the request would be filed as the model's own words. 8171
  # wants the operator to see what the agent was *asked*.
  defp write_request(_conversation, _agent_role, nil), do: :ok

  defp write_request(conversation, agent_role, text) do
    conversation
    |> Conversations.add_message(:user, text, "agent:#{agent_role}")
    |> normalize()
  end

  defp write_response(_conversation, _agent_role, nil), do: :ok

  defp write_response(conversation, agent_role, text) do
    conversation
    |> Conversations.add_agent_message(agent_role, :assistant, text)
    |> normalize()
  end

  defp normalize({:ok, _record}), do: :ok
  defp normalize({:error, reason}), do: {:error, reason}

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
end
