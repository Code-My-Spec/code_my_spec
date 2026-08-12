defmodule CodeMySpec.Chat.Runner do
  @moduledoc """
  Runs one turn of an agent conversation: send the history, execute whatever
  tools the model asks for, feed the results back, repeat until it stops asking
  or the cap is reached.

  Every turn is persisted as it happens rather than at the end, because the
  point of showing tool calls is showing them *while* they run. A conversation
  that fails halfway keeps everything already written, which is the same
  promise the intake interview makes when a workspace fails under it.

  ## Test seam

  `:chat_llm` in application env replaces the provider with a script:

      %{tool_calls: [%{name: "create_story", arguments: %{...}}],
        chunks_after_tool: ["Here is the story I captured."],
        error: :provider_unavailable}

  The provider is the only thing faked. Tool dispatch, persistence, broadcasts
  and the step cap all run for real, so a spex driving this exercises
  everything except the network.
  """

  alias CodeMySpec.Chat.{McpToolRegistry, Provider, ToolRegistry}
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message

  # Rounds of tool-calling per reply, not total calls — one round may carry
  # several. High enough for an interview that lists then creates, low enough
  # that a model which will not conclude stops costing money.
  @max_tool_rounds 12

  @default_model "anthropic:claude-sonnet-5"

  @doc "Runs a turn to completion. Returns `:ok` — progress is observed on the conversation."
  @spec run(Conversations.Conversation.t(), String.t()) :: :ok
  def run(conversation, user_text) do
    {:ok, _} = Conversations.add_agent_message(conversation, nil, "user", user_text)

    case Application.get_env(:code_my_spec, :chat_llm) do
      nil -> run_live(conversation)
      fixture -> run_scripted(conversation, fixture)
    end
  end

  @doc "Rounds allowed before a conversation is halted."
  @spec max_tool_rounds() :: pos_integer()
  def max_tool_rounds, do: @max_tool_rounds

  # --- scripted -------------------------------------------------------------

  # Walks the scripted calls through the same execute-and-persist path the live
  # runner uses, so what a spex observes is what production writes.
  defp run_scripted(conversation, fixture) do
    calls = Map.get(fixture, :tool_calls, [])

    conversation
    |> execute_rounds(calls, tools(conversation), 0)
    |> finish(conversation, fixture)
  end

  defp execute_rounds(_conversation, [], _tools, _round), do: :done

  defp execute_rounds(_conversation, _calls, _tools, round) when round >= @max_tool_rounds,
    do: :halted

  defp execute_rounds(conversation, [call | rest], tools, round) do
    call_id = "call_#{round}"

    {:ok, _} =
      Conversations.add_tool_call(conversation, call_id, call_name(call), call_args(call))

    {:ok, _} =
      Conversations.add_tool_result(conversation, call_id, call_name(call), invoke(tools, call))

    execute_rounds(conversation, rest, tools, round + 1)
  end

  defp finish(:halted, conversation, _fixture) do
    {:ok, _} = Conversations.halt(conversation, "stopped after #{@max_tool_rounds} rounds")
    :ok
  end

  defp finish(:done, conversation, %{error: reason}) do
    {:ok, _} = Conversations.fail(conversation, to_string(reason))
    :ok
  end

  defp finish(:done, conversation, fixture) do
    fixture
    |> Map.get(:chunks_after_tool, [])
    |> Enum.each(&Conversations.add_agent_message(conversation, nil, "assistant", &1))

    :ok
  end

  # --- live -----------------------------------------------------------------

  # This used to be a stub that failed every send with "no model configured for
  # this conversation", so the feature only ever worked inside `mix spex` —
  # QA found nine of the story's thirteen criteria unexercisable against the
  # running app (issue 1d82eeea). The stub was honest about being unbuilt, which
  # is why it says so rather than silently doing nothing; it still meant the
  # scripted path was the only path.
  #
  # Rounds go through `execute_rounds/4`'s persistence, so a spex and a live
  # conversation write the same rows in the same order — the moduledoc's claim
  # that the provider is the only thing faked is only true if this is the only
  # thing that differs.
  defp run_live(conversation) do
    if Provider.impl().ready?() do
      converse(conversation, history(conversation), tools(conversation), 0)
    else
      {:ok, _} = Conversations.fail(conversation, "no model configured for this conversation")
      :ok
    end
  end

  # The cap counts provider round-trips, matching the scripted path's rounds.
  # Halting rather than failing: everything already written stays, which is the
  # promise "a failure mid-conversation keeps what Sam already said" makes.
  defp converse(conversation, _messages, _tools, round) when round >= @max_tool_rounds do
    {:ok, _} = Conversations.halt(conversation, "stopped after #{@max_tool_rounds} rounds")
    :ok
  end

  defp converse(conversation, messages, tools, round) do
    case Provider.impl().generate_text(model(), messages,
           tools: tools,
           system_prompt: system_prompt(),
           temperature: 0.3
         ) do
      {:ok, response} ->
        continue(conversation, messages, tools, round, response)

      {:error, reason} ->
        {:ok, _} = Conversations.fail(conversation, describe(reason))
        :ok
    end
  end

  # No tool calls means the model is talking, which is how a turn ends.
  defp continue(conversation, messages, tools, round, response) do
    case ReqLLM.Response.tool_calls(response) do
      [] ->
        emit_text(conversation, ReqLLM.Response.text(response))
        :ok

      calls ->
        # Text the model emitted alongside its calls is part of the transcript;
        # dropping it loses the "here is what I am about to do" half of a turn.
        emit_text(conversation, ReqLLM.Response.text(response))

        results = Enum.map(calls, &execute_live_call(conversation, tools, &1))

        # The assistant turn must go back carrying its tool_calls, and each
        # result must name the call it answers, or the provider sees answers to
        # questions it has no record of asking.
        messages =
          messages ++
            [response.message] ++
            Enum.map(results, fn {id, text} -> ReqLLM.Context.tool_result(id, text) end)

        converse(conversation, messages, tools, round + 1)
    end
  end

  defp execute_live_call(conversation, tools, call) do
    name = call.function.name
    args = decode_args(call.function.arguments)

    {:ok, _} = Conversations.add_tool_call(conversation, call.id, name, args)
    text = invoke(tools, %{name: name, arguments: args})
    {:ok, _} = Conversations.add_tool_result(conversation, call.id, name, text)

    {call.id, text}
  end

  # What the provider is given as context: the conversation so far, in order.
  # Read from the database rather than accumulated in memory so a turn resumed
  # after a failure sees everything already written — "Sam steps away and picks
  # up where he left off" is the same read.
  defp history(conversation) do
    conversation
    |> Conversations.list_messages()
    |> Enum.flat_map(&to_provider_message/1)
  end

  defp to_provider_message(%{role: :tool, tool_call_id: id} = message) when is_binary(id) do
    [ReqLLM.Context.tool_result(id, Message.text(message))]
  end

  # An assistant turn that made tool calls has to go back carrying them. Without
  # this it returns as text alone — and a tool-call row has no text, so it
  # vanishes entirely and the `tool_result` after it names a call the provider
  # has no record of making. Anthropic rejects the whole request:
  #
  #     unexpected `tool_use_id` found in `tool_result` blocks: toolu_…
  #     Each `tool_result` block must have a corresponding `tool_use` block
  #
  # Only from the second message onward, which is why it survived every test:
  # inside one turn `continue/5` appends the live `response.message`, tool calls
  # intact. History is rebuilt from these rows, and only a follow-up rebuilds it.
  defp to_provider_message(%{role: :assistant, tool_calls: calls} = message)
       when is_list(calls) and calls != [] do
    [ReqLLM.Context.assistant(assistant_content(message), tool_calls: calls)]
  end

  defp to_provider_message(%{role: :assistant} = message) do
    case Message.text(message) do
      "" -> []
      text -> [ReqLLM.Context.assistant(text)]
    end
  end

  # Empty content as a list, not `""`: a blank text part alongside a tool call
  # is a block with nothing in it, which providers reject in their own dialects.
  defp assistant_content(message) do
    case Message.text(message) do
      "" -> []
      text -> text
    end
  end

  # `:operator` is a human on the other side of the widget, which to the model
  # is the same speaking position as `:user`.
  defp to_provider_message(%{role: role} = message) when role in [:user, :operator] do
    case Message.text(message) do
      "" -> []
      text -> [ReqLLM.Context.user(text)]
    end
  end

  defp to_provider_message(_message), do: []

  defp emit_text(_conversation, text) when text in [nil, ""], do: :ok

  defp emit_text(conversation, text) do
    {:ok, _} = Conversations.add_agent_message(conversation, nil, "assistant", text)
    :ok
  end

  # Arguments arrive as a JSON string on the wire. A model that emits malformed
  # JSON is a tool call we cannot honour, not a crash — `invoke/2` will report
  # the empty-argument failure through the same path as any other tool error.
  defp decode_args(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_args(arguments) when is_map(arguments), do: arguments
  defp decode_args(_), do: %{}

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{__exception__: true} = error), do: Exception.message(error)
  defp describe(reason), do: inspect(reason)

  defp model do
    :code_my_spec
    |> Application.get_env(CodeMySpec.Chat, [])
    |> Keyword.get(:model, @default_model)
  end

  defp system_prompt do
    """
    You are interviewing someone who has just signed up and has no code yet.
    Your job is to turn what they tell you into exactly one user story.

    Ask one short question at a time, in their words, about what the
    application should do — never about frameworks, hosting or technology.
    After about four answers you will know enough.

    Then call `create_story` once, with a `title` that reads as an outcome and
    a `story` in the form "As a <role>, I want <capability>, so that <reason>."

    Exactly one story. If one already exists on this project, do not create
    another — call `update_story` to correct it, or say plainly that the story
    is already captured and ask whether they want it changed. A second story is
    refused, not silently added.

    When the story is captured, say so briefly and stop.
    """
  end

  # --- tools ----------------------------------------------------------------

  defp tools(conversation), do: registry().list_tools(conversation)

  defp registry do
    Application.get_env(:code_my_spec, :chat_tool_registry, McpToolRegistry)
  end

  defp invoke(tools, call) do
    name = call_name(call)

    case Enum.find(tools, &(&1.name == name)) do
      nil ->
        "no such tool: #{name}"

      tool ->
        case ReqLLM.Tool.execute(tool, stringify(call_args(call))) do
          {:ok, result} -> to_text(result)
          {:error, reason} -> "error: #{inspect(reason)}"
        end
    end
  end

  defp call_name(%{name: name}), do: name
  defp call_name(%{"name" => name}), do: name

  defp call_args(%{arguments: args}), do: args
  defp call_args(%{"arguments" => args}), do: args
  defp call_args(_), do: %{}

  defp stringify(args) when is_map(args) do
    Map.new(args, fn {k, v} -> {to_string(k), v} end)
  end

  defp to_text(result) when is_binary(result), do: result
  defp to_text(result), do: inspect(result)

  @behaviour_check ToolRegistry
  @doc false
  def __behaviour__, do: @behaviour_check
end
