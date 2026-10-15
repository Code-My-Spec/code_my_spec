defmodule CodeMySpec.AgentHarness.ConversationRecorder do
  @moduledoc """
  Records a sprite's model turns onto the project's agent conversation.

  A sprite's agent points `ANTHROPIC_BASE_URL` at the local harness, so every
  turn passes through here on its way upstream. That is the only place both
  halves of a turn are visible at once — the request the agent sent and the
  response it got back.

  Recording is a side effect and never a precondition: the run survives the
  recorder failing, so every write here is wrapped and its failure logged
  rather than raised.
  """

  require Logger

  alias CodeMySpec.Conversations

  @upstream "https://api.anthropic.com"

  @doc """
  Forward one turn upstream and record both halves.

  A pass-through that happens to observe. The upstream response is returned
  unchanged — an agent must not be able to tell it is being watched.
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

  # The agent's own credential is forwarded. The configured key is only a
  # fallback for a caller that sent none — never an override.
  defp passthrough_headers(opts) do
    headers = Keyword.get(opts, :headers, [])

    # Unconditional so the header set is stable: a cassette recorded with a key
    # must replay without one.
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
    if client_side_call?(request) do
      :ok
    else
      with {:ok, conversation} <-
             Conversations.find_or_create_session_conversation(
               account_id,
               project_id,
               session_external_id
             ),
           :ok <- store_available(opts),
           :ok <- write_request(conversation, agent_role, request),
           :ok <- write_response(conversation, agent_role, response_text(response)),
           :ok <- write_tool_calls(conversation, agent_role, tool_calls(response)) do
        :ok
      else
        {:error, reason} = error ->
          Logger.warning("[ConversationRecorder] recording failed: #{inspect(reason)}")
          error
      end
    end
  end

  # The agent client's own housekeeping calls, dropped before the conversation
  # is found. Literal prefixes anchored at the start, never a heuristic.
  # See knowledge/platform, "Conversation recorder".
  @client_wrappers [
    # Posts the whole transcript, reads back a severity score.
    "<transcript>",
    # Asks what the user might type next.
    "[SUGGESTION MODE:",
    # Asks for a one-line status of what the agent is doing.
    "Current state: "
  ]

  @doc "Whether a turn's request is a `@client_wrappers` prompt rather than a user message."
  def client_side_call?(request) do
    case request_text(request) do
      text when is_binary(text) -> Enum.any?(@client_wrappers, &String.starts_with?(text, &1))
      _ -> false
    end
  end

  # Checked after the conversation is found or created on purpose: a turn that
  # happened leaves a trace even when nothing can be written, and an empty
  # conversation is what the operator's gap notice reads.
  defp store_available(opts) do
    if Keyword.get(opts, :store) == :unwritable, do: {:error, :store_unwritable}, else: :ok
  end

  # A request carries tool results answering the previous turn's calls, and free
  # text. Each result gets its own row carrying its `tool_use_id`, so the view
  # renders it inside the call it answers.
  defp write_request(conversation, agent_role, request) do
    with :ok <- write_tool_results(conversation, agent_role, tool_results(request)) do
      write_free_text(conversation, agent_role, request_text(request))
    end
  end

  defp write_tool_results(_conversation, _agent_role, []), do: :ok

  defp write_tool_results(conversation, agent_role, [result | rest]) do
    case conversation
         |> Conversations.add_tool_result(result.call_id, result.name, result.text,
           agent_role: agent_role,
           failed?: result.failed?
         )
         |> normalize() do
      :ok -> write_tool_results(conversation, agent_role, rest)
      error -> error
    end
  end

  defp write_free_text(_conversation, _agent_role, nil), do: :ok

  # Skips text identical to the last `:user` message (not the last message
  # outright, which is always the previous response). Written as "user" so
  # Conversations files it as the request, not the model's words.
  # See knowledge/platform, "Conversation recorder".
  defp write_free_text(conversation, agent_role, text) do
    if Conversations.last_message_text(conversation, :user) == text do
      :ok
    else
      conversation
      |> Conversations.add_agent_message(agent_role, "user", text)
      |> normalize()
    end
  end

  defp write_response(_conversation, _agent_role, nil), do: :ok

  defp write_response(conversation, agent_role, text) do
    conversation
    |> Conversations.add_agent_message(agent_role, :assistant, text)
    |> normalize()
  end

  # Tool calls are their own messages, rendered as call blocks with their
  # arguments, not prose folded into the assistant's.
  defp write_tool_calls(_conversation, _agent_role, []), do: :ok

  defp write_tool_calls(conversation, agent_role, [call | rest]) do
    case conversation
         |> Conversations.add_tool_call(call.id, call.name, call.input, agent_role)
         |> normalize() do
      :ok -> write_tool_calls(conversation, agent_role, rest)
      error -> error
    end
  end

  # Keeps the provider's `tool_use` id: it is what pairs a result with its call.
  @spec tool_calls(map()) :: [%{id: String.t(), name: String.t(), input: map()}]
  defp tool_calls(%{"content" => content}) when is_list(content) do
    for %{"type" => "tool_use", "name" => name} = block <- content do
      %{
        id: block["id"],
        name: name,
        input: if(is_map(block["input"]), do: block["input"], else: %{})
      }
    end
  end

  defp tool_calls(_response), do: []

  # The results in this turn's request, each with the id of the call it answers.
  # Public: the channel's `record_turn` handler mirrors failures onto the
  # resolved agent's own conversation.
  @spec tool_results(map()) :: [
          %{call_id: String.t(), name: String.t(), text: String.t(), failed?: boolean()}
        ]
  def tool_results(%{"messages" => messages}) when is_list(messages) do
    case List.last(messages) do
      %{"content" => content} when is_list(content) ->
        for %{"type" => "tool_result"} = block <- content do
          %{
            call_id: block["tool_use_id"],
            name: block["name"] || "tool",
            text: truncate(tool_result_content(block["content"])),
            failed?: block["is_error"] == true
          }
        end

      _ ->
        []
    end
  end

  def tool_results(_request), do: []

  defp normalize({:ok, _record}), do: :ok
  defp normalize({:error, reason}), do: {:error, reason}

  # A tool-only turn has no prose; its calls are written separately, so it is
  # still legible.
  @doc "The assistant's prose for a turn — falls back to a thinking-only summary when the turn was all tool calls."
  @spec response_text(map()) :: String.t() | nil
  def response_text(%{"content" => content}) when is_list(content) do
    case content |> Enum.map(&block_text/1) |> Enum.reject(&is_nil/1) |> join() do
      nil -> if tool_calls(%{"content" => content}) == [], do: thinking_only(content), else: nil
      text -> text
    end
  end

  def response_text(_response), do: nil

  defp block_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text

  # `tool_results/1` writes each result as its own row; folding it into prose
  # too would duplicate it unpaired.
  defp block_text(%{"type" => "tool_result"}), do: nil

  # Named, not rendered.
  defp block_text(%{"type" => "image"}), do: "← image"

  defp block_text(%{"type" => "thinking"}), do: nil
  defp block_text(_block), do: nil

  # Anthropic allows a tool result to be a plain string or a list of blocks.
  defp tool_result_content(content) when is_binary(content), do: content

  defp tool_result_content(content) when is_list(content) do
    content
    |> Enum.map_join("\n", fn
      %{"type" => "text", "text" => text} -> text
      %{"type" => type} -> "[#{type}]"
      other -> inspect(other)
    end)
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

  # A thinking-only turn (max_tokens spent before prose) gets a placeholder:
  # thinking is not the answer, but a blank turn reads as nothing having run.
  defp thinking_only(content) do
    if Enum.any?(content, &(is_map(&1) and &1["type"] == "thinking")) do
      "(thought, but reached the token limit before answering)"
    else
      nil
    end
  end

  @doc "The user's text for a turn's last message, with injected wrapper text stripped."
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

  # Drops `<system-reminder>` blocks, the only injected context matched; if
  # nothing is left, the original is kept.
  # See knowledge/platform, "Conversation recorder".
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
