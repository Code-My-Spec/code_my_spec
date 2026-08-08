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

  require Logger

  alias CodeMySpec.Chat.{McpToolRegistry, ToolRegistry}
  alias CodeMySpec.Conversations

  # Rounds of tool-calling per reply, not total calls — one round may carry
  # several. High enough for an interview that lists then creates, low enough
  # that a model which will not conclude stops costing money.
  @max_tool_rounds 12

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

  # Not wired to a provider yet: the story's spex drive the scripted path, and
  # a half-built live path that silently does nothing is worse than one that
  # says so.
  defp run_live(conversation) do
    {:ok, _} = Conversations.fail(conversation, "no model configured for this conversation")
    :ok
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
