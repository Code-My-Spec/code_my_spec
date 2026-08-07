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

  # A sprite's agent authenticates as itself, and forwarding its credential is
  # the whole reason this proxy holds none. But a caller that sends no
  # credential at all cannot reach Anthropic, so the harness may be configured
  # with one as a fallback — never as an override, so an agent's own key always
  # wins and the proxy cannot silently spend someone else's quota.
  defp passthrough_headers(opts) do
    headers = Keyword.get(opts, :headers, [])

    # anthropic-version goes on every request regardless of credential. It is
    # required by the API, and keeping it unconditional keeps the header set
    # stable — a cassette recorded with a key has to replay without one, which
    # it cannot do if the presence of a key changes which headers are sent.
    headers = ensure_version(headers)

    if Enum.any?(headers, fn {name, _} -> name in ["authorization", "x-api-key"] end) do
      headers
    else
      case fallback_key() do
        nil -> headers
        key -> [{"x-api-key", key} | headers]
      end
    end
  end

  defp ensure_version(headers) do
    if Enum.any?(headers, fn {name, _} -> name == "anthropic-version" end) do
      headers
    else
      [{"anthropic-version", "2023-06-01"} | headers]
    end
  end

  defp fallback_key do
    Application.get_env(:code_my_spec, __MODULE__, [])[:api_key] ||
      System.get_env("ANTHROPIC_API_KEY")
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
  @spec record_turn(String.t(), String.t(), String.t(), map(), map(), String.t()) ::
          :ok | {:error, term()}
  def record_turn(
        account_id,
        project_id,
        session_external_id,
        request,
        response,
        agent_role \\ "main",
        opts \\ []
      ) do
    with {:ok, conversation} <-
           Conversations.find_or_create_agent_conversation(
             account_id,
             project_id,
             session_external_id
           ),
         :ok <- store_available(opts),
         :ok <- write_request(conversation, agent_role, request_text(request)),
         :ok <- write_response(conversation, agent_role, response_text(response)),
         :ok <- write_tool_calls(conversation, agent_role, tool_calls(response)) do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("[ConversationRecorder] recording failed: #{inspect(reason)}")
        error
    end
  end

  # "user" has to map to :user in Conversations, or the kind mapping files the
  # request as the model's own words. It carries the agent role for the same
  # reason the response does: a sub-agent's question showing unattributed while
  # its answer is tagged is half an attribution.
  # The conversation is found or created before this check on purpose: a turn
  # that happened must leave a trace even when nothing about it can be written,
  # and an empty conversation is what the operator's gap notice reads.
  defp store_available(opts) do
    if Keyword.get(opts, :store) == :unwritable, do: {:error, :store_unwritable}, else: :ok
  end

  defp write_request(_conversation, _agent_role, nil), do: :ok

  defp write_request(conversation, agent_role, text) do
    conversation
    |> Conversations.add_agent_message(agent_role, "user", text)
    |> normalize()
  end

  defp write_response(_conversation, _agent_role, nil), do: :ok

  defp write_response(conversation, agent_role, text) do
    conversation
    |> Conversations.add_agent_message(agent_role, :assistant, text)
    |> normalize()
  end

  # Tool calls are their own messages, not prose folded into the assistant's.
  # The conversation view renders a :tool message as a tool-call block, and a
  # turn that only called tools has to show which tool and with what arguments
  # — a name alone does not tell an operator what the sprite actually did.
  defp write_tool_calls(_conversation, _agent_role, []), do: :ok

  defp write_tool_calls(conversation, agent_role, [call | rest]) do
    case conversation
         |> Conversations.add_agent_message(agent_role, "tool", call)
         |> normalize() do
      :ok -> write_tool_calls(conversation, agent_role, rest)
      error -> error
    end
  end

  @doc false
  @spec tool_calls(map()) :: [String.t()]
  def tool_calls(%{"content" => content}) when is_list(content) do
    for %{"type" => "tool_use", "name" => name} = block <- content do
      case block["input"] do
        input when is_map(input) and input != %{} -> "#{name}\n#{encode(input)}"
        _ -> name
      end
    end
  end

  def tool_calls(_response), do: []

  defp encode(input) do
    case Jason.encode(input, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(input)
    end
  end

  defp normalize({:ok, _record}), do: :ok
  defp normalize({:error, reason}), do: {:error, reason}

  # A turn that only calls tools is still legible afterwards (8173). The model
  # answers with `tool_use` blocks and no prose, so rendering only `text` would
  # leave the conversation blank for exactly the turns that did the work.
  @doc false
  @spec response_text(map()) :: String.t() | nil
  def response_text(%{"content" => content}) when is_list(content) do
    case content |> Enum.map(&block_text/1) |> Enum.reject(&is_nil/1) |> join() do
      nil -> if tool_calls(%{"content" => content}) == [], do: thinking_only(content), else: nil
      text -> text
    end
  end

  def response_text(_response), do: nil

  defp block_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text

  # A tool result is most of what an agent's later requests are made of: once it
  # has called anything, the next turn's content is these blocks and little
  # else. Dropping them recorded those turns as empty, which is the same defect
  # 8173 names for tool-only responses, on the request side.
  #
  # `is_error` is kept because a failed tool result is the most diagnostic thing
  # an operator can see — it is where a run starts going wrong, several turns
  # before the agent says anything about it.
  defp block_text(%{"type" => "tool_result"} = block) do
    marker = if block["is_error"], do: "failed", else: "result"
    "← #{marker}: #{truncate(tool_result_content(block["content"]))}"
  end

  # An image is worth naming without being rendered — the conversation is a
  # record of what happened, and "a screenshot went to the model here" is the
  # fact that matters.
  defp block_text(%{"type" => "image"}), do: "← image"

  defp block_text(%{"type" => "thinking"}), do: nil
  defp block_text(_block), do: nil

  # Anthropic allows a tool result to be a plain string or a list of blocks.
  defp tool_result_content(content) when is_binary(content), do: content

  defp tool_result_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      %{"type" => type} -> "[#{type}]"
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp tool_result_content(nil), do: ""
  defp tool_result_content(other), do: inspect(other)

  # Tool output is unbounded — a test run or a file read can be megabytes, and
  # the conversation is for reading, not for archiving stdout.
  @result_cap 2_000
  defp truncate(text) when byte_size(text) > @result_cap do
    binary_part(text, 0, @result_cap) <> "\n… (truncated)"
  end

  defp truncate(text), do: text

  # A turn can be nothing but thinking — a small max_tokens spends the budget
  # before any prose is emitted, and the first turn recorded here was exactly
  # that. Thinking is not the model\'s answer, so it is not shown as one, but a
  # blank conversation for a turn that happened is the same failure 8173 names
  # for tool-only turns: the operator sees nothing and concludes nothing ran.
  defp thinking_only(content) do
    if Enum.any?(content, &(is_map(&1) and &1["type"] == "thinking")) do
      "(thought, but reached the token limit before answering)"
    else
      nil
    end
  end

  @doc false
  @spec request_text(map()) :: String.t() | nil
  def request_text(%{"messages" => messages}) when is_list(messages) do
    messages
    |> List.last()
    |> case do
      %{"content" => content} when is_binary(content) -> strip_injected(content)
      %{"content" => content} when is_list(content) -> injected_free_text(content)
      _ -> nil
    end
  end

  def request_text(_request), do: nil

  # Drop the context the client injects, keep what the agent was asked.
  #
  # Recorded turns opened with "Available agent types for the Agent tool: …"
  # — Claude Code's preamble, not the instruction. The last message is the
  # right choice for a simple turn and the wrong one when the client appends
  # context to it, so this removes the appended part rather than choosing a
  # different message: the instruction and the injected block arrive together,
  # in the same message.
  #
  # `<system-reminder>` is the unambiguous case and the only one matched by
  # structure. Anything else is left alone — a heuristic that guessed at prose
  # would eventually eat somebody's actual question, which is worse than a
  # preamble they can scroll past.
  #
  # If stripping leaves nothing, the original is kept. A turn that was *only*
  # injected context still happened, and recording it as blank is the failure
  # 8173 names for tool-only turns: the operator sees nothing and concludes
  # nothing ran.
  defp injected_free_text(content) do
    kept = Enum.reject(content, &injected_block?/1)

    case response_text(%{"content" => kept}) do
      nil -> response_text(%{"content" => content})
      "" -> response_text(%{"content" => content})
      text -> text
    end
  end

  defp injected_block?(%{"type" => "text", "text" => text}) when is_binary(text),
    do: String.starts_with?(String.trim_leading(text), "<system-reminder>")

  defp injected_block?(_block), do: false

  defp strip_injected(text) when is_binary(text) do
    stripped =
      text
      |> String.replace(~r/<system-reminder>.*?<\/system-reminder>/s, "")
      |> String.trim()

    if stripped == "", do: text, else: stripped
  end

  defp join([]), do: nil
  defp join(parts), do: Enum.join(parts, "\n")
end
