defmodule CmsHarness.Agents.CodexWithToolsTest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias Alloy.Provider.Error
  alias CmsHarness.Agents.CodexWithTools

  @tool %{
    name: "get_next_requirement",
    description: "Get work",
    input_schema: %{type: "object", properties: %{}}
  }

  test "a short resumed turn carries the named catalog" do
    runner =
      runner(fn
        _prompt, 1 -> reply("end_turn", "ready")
        _prompt, 2 -> reply("end_turn", "done")
      end)

    config = config(runner)
    initial = [Message.user("start")]
    assert {:ok, first} = CodexWithTools.complete(initial, [@tool], config)
    assert_receive {:invocation, ["exec" | _], _initial_prompt}
    history = initial ++ first.messages ++ [Message.user("short operator message")]

    assert {:ok, _second} =
             CodexWithTools.complete(
               history,
               [@tool],
               Map.put(config, :provider_state, first.provider_state)
             )

    assert_receive {:invocation, ["exec", "resume" | _], prompt}
    assert prompt =~ "get_next_requirement"
    assert prompt =~ "available_tools"
    assert prompt =~ "Call them by name"
  end

  test "a missing-tools answer on resume is retried once and replaced by a tool call" do
    runner =
      runner(fn
        _prompt, 1 -> reply("end_turn", "ready")
        _prompt, 2 -> reply("end_turn", "get_next_requirement is not available in my tools")
        _prompt, 3 -> tool_reply()
      end)

    config = config(runner)
    initial = [Message.user("start")]
    assert {:ok, first} = CodexWithTools.complete(initial, [@tool], config)
    assert_receive {:invocation, ["exec" | _], _initial_prompt}
    history = initial ++ first.messages ++ [Message.user("get work")]

    assert {:ok, recovered} =
             CodexWithTools.complete(
               history,
               [@tool],
               Map.put(config, :provider_state, first.provider_state)
             )

    assert recovered.stop_reason == :tool_use
    assert [%Message{content: blocks}] = recovered.messages
    assert Enum.any?(blocks, &(&1.name == "get_next_requirement"))
    assert recovered.provider_state == nil
    assert_receive {:invocation, ["exec", "resume" | _], first_prompt}
    refute first_prompt =~ "previous answer incorrectly claimed"
    assert_receive {:invocation, ["exec", "resume" | _], retry_prompt}
    assert retry_prompt =~ "previous answer incorrectly claimed"
    refute_receive {:invocation, _, _}
  end

  test "a repeated false claim becomes a provider fault naming the agent" do
    runner = runner(fn _prompt, _attempt -> reply("end_turn", "I have no tools available") end)

    assert {:error, %Error{kind: :unknown} = error} =
             CodexWithTools.complete([Message.user("work")], [@tool], config(runner))

    assert Exception.message(error) =~ "agent agent-123"
    assert Exception.message(error) =~ "twice claimed"
  end

  test "a mistaken tools namespace claim is retried too" do
    runner =
      runner(fn _prompt, _attempt ->
        reply("end_turn", "tools.get_next_requirement is not a function")
      end)

    assert {:error, %Error{kind: :unknown}} =
             CodexWithTools.complete([Message.user("get work")], [@tool], config(runner))

    assert_receive {:invocation, _, _}
    assert_receive {:invocation, _, _}
    refute_receive {:invocation, _, _}
  end

  defp config(runner) do
    %{
      model: "test-model",
      agent_id: "agent-123",
      persist_session: true,
      workdir: System.tmp_dir!(),
      command_runner: runner
    }
  end

  defp runner(answer) do
    owner = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    fn _command, args, _opts ->
      attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
      prompt = List.last(args)
      send(owner, {:invocation, args, prompt})
      path = Enum.at(args, Enum.find_index(args, &(&1 == "--output-last-message")) + 1)
      File.write!(path, answer.(prompt, attempt))
      {~s({"type":"thread.started","thread_id":"thread-1"}\n), 0}
    end
  end

  defp reply(reason, text), do: Jason.encode!(%{stop_reason: reason, text: text, tool_calls: []})

  defp tool_reply do
    Jason.encode!(%{
      stop_reason: "tool_use",
      text: "",
      tool_calls: [%{call_id: "one", name: "get_next_requirement", arguments_json: "{}"}]
    })
  end
end
