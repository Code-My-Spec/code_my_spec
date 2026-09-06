defmodule CodeMySpecWeb.Components.ARunBreaksWhereAQuestionWaitsTest do
  @moduledoc """
  A folded run of calls has to break where something must render between two of
  them.

  The fold is right almost always: a run of tool calls collapses into one
  expandable item instead of filling the transcript. It stops being right when a
  pending question sits inside the run — three calls, then `ask_user_question`,
  then two more calls is one item, and a form rendered after it appears below
  work the agent did *after* asking.

  Putting the form inside the collapsed item is the worse of the two: a question
  nobody can see behind an expander is a question that does not get answered.

  So the caller names the messages a run must break after, and everything with
  no boundary folds exactly as it did.
  """
  use ExUnit.Case, async: true

  alias CodeMySpecWeb.ChatComponents

  defp call(id),
    do: %{
      id: "m-#{id}",
      role: :assistant,
      content: [],
      tool_calls: [%{"id" => id, "name" => "bash", "arguments" => %{}}],
      tool_call_id: nil
    }

  defp ids(items), do: Enum.map(items, & &1.id)

  defp items(messages, breaks \\ MapSet.new()) do
    {items, _results} = ChatComponents.group_turns(messages, breaks)
    items
  end

  test "with no boundary a run folds into one item, as before" do
    messages = Enum.map(1..6, &call("call_#{&1}"))

    assert [%{grouped: true, messages: six}] = items(messages)
    assert length(six) == 6
  end

  # The case John named: three calls, the question, two more.
  test "a boundary mid-run splits it in two, in order" do
    messages = Enum.map(1..6, &call("call_#{&1}"))
    breaks = MapSet.new(["m-call_4"])

    assert [first, second] = items(messages, breaks)

    assert ids([first]) == ["m-call_1"]
    assert Enum.map(first.messages, & &1.id) == ~w(m-call_1 m-call_2 m-call_3 m-call_4)
    assert Enum.map(second.messages, & &1.id) == ~w(m-call_5 m-call_6)
  end

  # The break goes *after* the anchored message, so the question renders below
  # the call that asked it rather than above it.
  test "the anchored message stays in the first piece" do
    messages = Enum.map(1..4, &call("call_#{&1}"))
    [first, _second] = items(messages, MapSet.new(["m-call_2"]))

    assert List.last(first.messages).id == "m-call_2"
  end

  # A leftover of one is a single turn, not a group of one — a lone call should
  # render as itself rather than behind an expander that opens on one thing.
  test "a piece of one renders as a single turn" do
    messages = Enum.map(1..3, &call("call_#{&1}"))
    [_first, second] = items(messages, MapSet.new(["m-call_2"]))

    assert second.grouped == false
    assert Enum.map(second.messages, & &1.id) == ["m-call_3"]
  end

  test "a boundary on the last message leaves one piece" do
    messages = Enum.map(1..3, &call("call_#{&1}"))

    assert [only] = items(messages, MapSet.new(["m-call_3"]))
    assert length(only.messages) == 3
  end

  test "a boundary naming a message that is not in the run changes nothing" do
    messages = Enum.map(1..4, &call("call_#{&1}"))

    assert [%{messages: four}] = items(messages, MapSet.new(["m-somewhere-else"]))
    assert length(four) == 4
  end

  test "two boundaries make three pieces" do
    messages = Enum.map(1..6, &call("call_#{&1}"))
    items = items(messages, MapSet.new(["m-call_2", "m-call_4"]))

    assert Enum.map(items, fn i -> Enum.map(i.messages, & &1.id) end) == [
             ~w(m-call_1 m-call_2),
             ~w(m-call_3 m-call_4),
             ~w(m-call_5 m-call_6)
           ]
  end
end
