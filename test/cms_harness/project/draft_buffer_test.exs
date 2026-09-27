defmodule CmsHarness.Project.DraftBufferTest do
  use ExUnit.Case, async: true

  alias CmsHarness.Project.DraftBuffer

  test "fragments of one model call add up to one draft, sent whole" do
    {payloads, _buffer} =
      DraftBuffer.new()
      |> DraftBuffer.add("a1", 1, "Plums ")
      |> DraftBuffer.add("a1", 1, "are fruit.")
      |> DraftBuffer.take()

    assert payloads == [%{"agent_id" => "a1", "turn" => 1, "text" => "Plums are fruit."}]
  end

  test "a new model call starts a new draft" do
    {[payload], _buffer} =
      DraftBuffer.new()
      |> DraftBuffer.add("a1", 1, "first call")
      |> DraftBuffer.add("a1", 2, "second")
      |> DraftBuffer.take()

    assert payload["text"] == "second"
  end

  test "a draft is sent again only once it has changed" do
    {[_], buffer} = DraftBuffer.new() |> DraftBuffer.add("a1", 1, "Hi") |> DraftBuffer.take()
    assert {[], buffer} = DraftBuffer.take(buffer)

    assert {[%{"text" => "Hi there"}], _} =
             buffer |> DraftBuffer.add("a1", 1, " there") |> DraftBuffer.take()
  end

  test "each agent has its own draft" do
    {payloads, _} =
      DraftBuffer.new()
      |> DraftBuffer.add("a1", 1, "one")
      |> DraftBuffer.add("a2", 1, "two")
      |> DraftBuffer.take()

    assert payloads |> Enum.map(& &1["text"]) |> Enum.sort() == ["one", "two"]
  end

  # Alloy counts turns from 1 again on every run, so a draft left behind would
  # have the next run's first fragment appended to it.
  test "a turn that settles drops the draft, so the next run starts clean" do
    for event <- [:message, :turn_ended, :turn_failed, :turn_cut_off] do
      {[payload], _} =
        DraftBuffer.new()
        |> DraftBuffer.add("a1", 1, "old reply")
        |> DraftBuffer.settle("a1", event)
        |> DraftBuffer.add("a1", 1, "new")
        |> DraftBuffer.take()

      assert payload["text"] == "new", "#{event} left the old draft behind"
    end
  end

  test "any other event leaves the draft alone" do
    buffer =
      DraftBuffer.new()
      |> DraftBuffer.add("a1", 1, "still writing")
      |> DraftBuffer.settle("a1", :tool_start)

    assert {[%{"text" => "still writing"}], _} = DraftBuffer.take(buffer)
  end
end
