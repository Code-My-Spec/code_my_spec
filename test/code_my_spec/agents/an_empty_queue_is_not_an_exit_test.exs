defmodule CodeMySpec.Agents.AnEmptyQueueIsNotAnExitTest do
  @moduledoc """
  An agent's queue running out is a stop nobody has to be woken out of.

  Issue `227d1595`, settled by John on 2026-10-05: *"when there's no work the
  graph shouldn't offer the agent"*. Three agents were observed correctly
  finding nothing actionable and saying so in prose, and story 1039's criterion
  3542 asserts they should have called `tap_out` instead. The criterion is the
  half that is wrong, and the reason is in the issue's own text: `tap_out`
  publishes a permission request and **exits continuous mode**, so an agent that
  taps out on an empty queue has to be put back by hand before any later work
  can reach it. `61c87cd5` is the recorded cost — re-staffed after a granted
  tap-out, it re-checked, found nothing had changed, and tapped out again.

  So the menu stops making the offer into one:

    * `Menu.render/4` still answers `""` when nothing is live for the role —
      that is the loop's terminus, and the agent simply stops;
    * `Menu.tap_out_offer/1` is unchanged for an agent with work in front of it,
      because *there* "continuing is not worth the tokens" is the judgement the
      offer is for;
    * the block-with-feedback path in `Hooks.Stop`, which today refuses a stop
      and then, in the same breath, tells the agent to ask to leave the loop,
      no longer says it.

  What is asserted here is the sentence an agent actually reads, because that
  sentence is the whole of the defect: the behaviour it was written to produce
  costs a person's approval to undo.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.Menu

  @menu_source "lib/code_my_spec/agents/menu.ex"
  @stop_source "lib/code_my_spec/hooks/stop.ex"

  describe "the tap-out offer an agent with work reads" do
    test "is still made when the loop is running" do
      offer = Menu.tap_out_offer(true)

      assert offer =~ "tap_out",
             "an agent with work in front of it must still be told how to leave"
    end

    test "is not made outside the loop" do
      assert Menu.tap_out_offer(false) == ""
    end
  end

  describe "the refusal the stop hook writes" do
    test "does not offer to leave the loop it is holding the agent in" do
      source = File.read!(@stop_source)

      refute source =~ ~r/block_with_reason\([^)]*true\)/s,
             """
             #{@stop_source} renders the menu with `continuous?: true` on the
             block-with-feedback path, which appends the tap-out offer to a
             refusal. The agent is being held in the loop by this very response;
             telling it to ask to leave is the offer `227d1595` removes.
             """

      assert source =~ "Menu.render(scope, false, nil, owner)",
             """
             the block-with-feedback menu must be rendered with the tap-out
             offer off, so a refusal carries the work and not the exit.
             """
    end
  end

  describe "the menu's own record of the decision" do
    test "says an empty queue is a stop and not an exit" do
      source = File.read!(@menu_source)

      assert source =~ "empty queue",
             """
             #{@menu_source} should record why an empty queue is not the tap-out
             offer's case, so the next reader does not re-derive `227d1595`.
             """
    end
  end
end
