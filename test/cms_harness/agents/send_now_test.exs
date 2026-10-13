defmodule CmsHarness.Agents.SendNowTest do
  @moduledoc """
  A message sent now follows a round of tool results inside the running turn
  (story 1051). Driven at the middleware: what is under test is what the model
  is handed after the round, not Alloy's decision to run the hook.
  """
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State}
  alias Alloy.Message
  alias CmsHarness.Agents.SendNow

  @results Message.tool_results([
             %{type: "tool_result", tool_use_id: "call-1", content: "3 tests, 0 failures"}
           ])

  defp after_round(take) do
    [Message.user("run the tests")]
    |> then(&State.init(Config.from_opts(context: %{take_send_now: take}), &1))
    |> State.append_messages(@results)
    |> then(&SendNow.call(:after_tool_execution, &1))
  end

  test "messages sent now follow the round's results as one user message" do
    state =
      after_round(fn -> {:ok, %{"messages" => ["Stop and merge main.", "Then report."]}} end)

    assert [%Message{role: :user, content: "Stop and merge main.\n\nThen report."}, @results | _] =
             state.messages_new
  end

  test "nothing sent leaves the round as it was" do
    assert [@results] = after_round(fn -> {:ok, %{"messages" => []}} end).messages_new
  end

  test "a server that cannot answer leaves the round as it was" do
    assert [@results] = after_round(fn -> {:error, :not_connected} end).messages_new
  end

  test "an agent with no asker is unchanged" do
    assert [@results] = after_round(nil).messages_new
  end

  test "only the tool boundary asks" do
    state = State.init(Config.from_opts(context: %{take_send_now: fn -> raise "asked" end}))
    assert ^state = SendNow.call(:before_completion, state)
  end
end
