defmodule CmsHarness.Agents.CompactionTest do
  @moduledoc """
  What leaves the machine when an agent compacts.

  The event nobody sees fail. Compaction happens when a context fills, which on
  a main agent is weeks in — so a reporter that was never wired, or an envelope
  the wire cannot carry, would sit silent through every test anybody runs and
  surface as an agent that resumes from the top of a conversation nobody can
  hand a model any more.

  Driven at the middleware rather than by filling a real context: compacting for
  real needs a provider and tens of thousands of tokens, and what is under test
  is what gets reported, not Alloy's decision to report it.
  """
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State}
  alias Alloy.Message
  alias CmsHarness.Agents.Compaction

  defp state_with(messages, context) do
    State.init(Config.from_opts(context: context), messages)
  end

  test "the surviving messages go up, as turns" do
    parent = self()

    state =
      state_with(
        [Message.user("the first thing"), Message.assistant("Previous summary: X")],
        %{on_compaction: fn envelope -> send(parent, {:compacted, envelope}) end}
      )

    assert %State{} = Compaction.call(:after_compaction, state)

    assert_receive {:compacted, envelope}
    assert envelope.event == :compacted

    assert envelope.messages == [
             %{"role" => "user", "content" => "the first thing"},
             %{"role" => "assistant", "content" => "Previous summary: X"}
           ]
  end

  test "an agent nobody is keeping the transcript of reports nothing" do
    state = state_with([Message.user("hello")], %{})

    assert %State{} = Compaction.call(:after_compaction, state),
           "a loop with no reporter has to carry on. There is nothing to resume from " <>
             "either, so a checkpoint would have nowhere to go."
  end

  test "a reporter that raises does not take the turn with it" do
    state = state_with([Message.user("hello")], %{on_compaction: fn _ -> raise "boom" end})

    assert %State{} = Compaction.call(:after_compaction, state),
           "the cost of losing a checkpoint is a longer resume; the cost of a failed " <>
             "turn is the turn."
  end

  test "other hooks pass through untouched" do
    parent = self()

    state =
      state_with(
        [Message.user("hello")],
        %{on_compaction: fn envelope -> send(parent, {:compacted, envelope}) end}
      )

    assert %State{} = Compaction.call(:before_completion, state)
    refute_receive {:compacted, _}
  end
end
