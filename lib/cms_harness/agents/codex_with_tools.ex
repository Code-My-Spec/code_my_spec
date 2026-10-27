defmodule CmsHarness.Agents.CodexWithTools do
  @moduledoc "Keeps the harness tools visible to Codex and checks missing-tools claims."
  @behaviour Alloy.Provider

  alias Alloy.Message
  alias Alloy.Provider.Codex
  alias Alloy.Provider.Error

  @impl true
  def complete(messages, tools, config), do: run(:complete, messages, tools, config, nil)

  @impl true
  def stream(messages, tools, config, on_chunk),
    do: run(:stream, messages, tools, config, on_chunk)

  defp run(mode, messages, tools, config, on_chunk) do
    config = prepare(config, tools, messages)

    case call(mode, messages, tools, config, on_chunk) do
      {:ok, first} = success ->
        if missing_tools_claim?(first, tools) do
          retry_missing_tools(mode, messages, tools, config, on_chunk, first)
        else
          success
        end

      error ->
        error
    end
  end

  defp prepare(config, tools, messages) do
    names = Enum.map_join(tools, ", ", & &1.name)

    reminder =
      "The available Alloy harness tools are: #{names}. Call them by name in tool_calls when needed. They are available on resumed turns too."

    config = Map.update(config, :system_prompt, reminder, &"#{&1}\n\n#{reminder}")

    case List.last(messages) do
      %Message{role: :user} -> resend_catalog(config)
      _ -> config
    end
  end

  defp resend_catalog(config) do
    Map.update(config, :provider_state, nil, fn
      %{"codex_session" => session} = state when is_map(session) ->
        put_in(state, ["codex_session", "resend"], true)

      state ->
        state
    end)
  end

  defp call(:complete, messages, tools, config, _on_chunk),
    do: Codex.complete(messages, tools, config)

  defp call(:stream, messages, tools, config, on_chunk),
    do: Codex.stream(messages, tools, config, on_chunk)

  defp missing_tools_claim?(%{stop_reason: :end_turn, messages: messages}, tools)
       when tools != [] do
    text = Enum.map_join(messages, "\n", &Message.text/1)

    Regex.match?(
      ~r/\b(?:no|missing|unavailable|lack|without|cannot|can't|do not have|don't have|not available)\b.{0,100}\btools?\b|\btools?\b.{0,100}\b(?:not available|not provided|missing|unavailable|not in|cannot call|can't call|do not include)\b|\btools?\.\w+\b.{0,60}\b(?:not a function|undefined)\b|\bnot in\b.{0,80}\btool list\b/is,
      text
    )
  end

  defp missing_tools_claim?(_result, _tools), do: false

  defp retry_missing_tools(mode, messages, tools, config, on_chunk, first) do
    names = Enum.map_join(tools, ", ", & &1.name)

    reminder =
      "The previous answer incorrectly claimed tools were missing. This request supplies these available_tools: #{names}. Continue the task and call the needed tool by its exact name."

    retry_messages = messages ++ first.messages ++ [Message.user(reminder)]
    retry_config = config |> Map.put(:provider_state, first.provider_state) |> resend_catalog()

    case call(mode, retry_messages, tools, retry_config, on_chunk) do
      {:ok, second} ->
        if missing_tools_claim?(second, tools) do
          {:error, provider_fault(config)}
        else
          # The correction was private; resume next time from visible history.
          {:ok, Map.put(second, :provider_state, nil)}
        end

      error ->
        error
    end
  end

  defp provider_fault(config) do
    %Error{
      kind: :unknown,
      message:
        "Codex provider fault for agent #{Map.get(config, :agent_id, "unknown")}: twice claimed the supplied Alloy harness tools were unavailable"
    }
  end
end
