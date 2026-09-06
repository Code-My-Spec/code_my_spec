defmodule CodeMySpecWeb.Components.AResultBelongsToItsOwnCallTest do
  @moduledoc """
  Tool call ids repeat, so a result has to be matched to the call it answered.

  They are sequential per agent run — `call_1`, `call_16`, `call_26_retry` — and
  a conversation that has run all day holds each of them several times over.
  Collected into a map keyed by id alone, the newest call inherited the oldest
  surviving answer.

  On 2026-09-06 that put "No session_id available. Call `register_session`…" —
  a real error, from a `start_task` eight hours earlier that happened to be
  `call_16` too — underneath an `ask_user_question` that had worked. The
  question had been created, delivered and answered. John, reasonably: "ask user
  question looks like it failed."

  It surfaced only after scrolling loaded the older turns, which is why it
  appeared long after the call itself and looked like a fresh failure.
  """
  use ExUnit.Case, async: true

  alias CodeMySpecWeb.ChatComponents

  defp call(id, name),
    do: %{
      id: "m-#{id}-call",
      role: :assistant,
      content: [],
      tool_calls: [%{"id" => id, "name" => name, "arguments" => %{}}],
      tool_call_id: nil
    }

  defp result(id, text),
    do: %{
      id: "m-#{id}-result-#{System.unique_integer([:positive])}",
      role: :tool,
      content: [%{"type" => "text", "text" => text}],
      tool_calls: nil,
      tool_call_id: id
    }

  defp results_for(messages) do
    {_items, results} = ChatComponents.group_turns(messages)
    results
  end

  test "a result pairs with the call it answered" do
    results = results_for([call("call_1", "start_task"), result("call_1", "started")])

    assert %{content: [%{"text" => "started"}]} = results["call_1"]
  end

  # The bug. A second call with the same id must not inherit the first's answer.
  test "a later call with a reused id does not inherit the earlier answer" do
    messages = [
      call("call_16", "start_task"),
      result("call_16", "No session_id available."),
      call("call_16", "ask_user_question")
    ]

    refute Map.has_key?(results_for(messages), "call_16"),
           "the new call inherited an eight-hour-old error and rendered as having failed"
  end

  test "the reused call still pairs with its own answer when one arrives" do
    messages = [
      call("call_16", "start_task"),
      result("call_16", "No session_id available."),
      call("call_16", "ask_user_question"),
      result("call_16", "Asked 1 question(s).")
    ]

    assert %{content: [%{"text" => "Asked 1 question(s)."}]} = results_for(messages)["call_16"]
  end

  # Unrelated ids are untouched by the clearing — a call must only supersede
  # answers standing against its own id.
  test "clearing one id leaves the others alone" do
    messages = [
      call("call_1", "start_task"),
      result("call_1", "started"),
      call("call_2", "ask_user_question"),
      result("call_2", "asked"),
      call("call_2", "ask_user_question")
    ]

    results = results_for(messages)

    assert %{content: [%{"text" => "started"}]} = results["call_1"]
    refute Map.has_key?(results, "call_2")
  end

  # One assistant turn can carry several calls at once; each of them clears its
  # own id.
  test "a turn making several calls clears each of their ids" do
    both = %{
      id: "m-both",
      role: :assistant,
      content: [],
      tool_calls: [
        %{"id" => "call_1", "name" => "a", "arguments" => %{}},
        %{"id" => "call_2", "name" => "b", "arguments" => %{}}
      ],
      tool_call_id: nil
    }

    messages = [
      call("call_1", "old"),
      result("call_1", "stale one"),
      call("call_2", "old"),
      result("call_2", "stale two"),
      both
    ]

    assert results_for(messages) == %{}
  end
end
