defmodule CodeMySpec.Permissions.TapOutPendingTest do
  @moduledoc """
  `Hooks.Stop`'s guard against a session with a tap-out decision outstanding.

  `session.continuous` stays `true` until an `:approve` clears it
  (`TapOut.decision_attrs/3`), so a session that tapped out and was rejected —
  or simply has not heard back yet — still reads "continuous, keep going" to
  every other check in `do_decide/6`. This is the one thing that says
  otherwise, and it has to read the state, not just its presence: a rejected
  or approved request left sitting under `pending_tap_out` must stop counting
  the moment it is decided.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Permissions.TapOut
  alias CodeMySpec.Sessions.Session

  defp session(state), do: %Session{state: state}

  test "a request with no decision yet is pending" do
    assert TapOut.pending?(session(%{"pending_tap_out" => %{"id" => "1", "status" => "pending"}}))
  end

  test "an approved request is not pending" do
    refute TapOut.pending?(
             session(%{"pending_tap_out" => %{"id" => "1", "status" => "approved"}})
           )
  end

  test "a rejected request is not pending" do
    refute TapOut.pending?(
             session(%{"pending_tap_out" => %{"id" => "1", "status" => "rejected"}})
           )
  end

  test "a session that never tapped out is not pending" do
    refute TapOut.pending?(session(%{}))
  end

  test "a session with no state at all is not pending" do
    refute TapOut.pending?(session(nil))
  end
end
