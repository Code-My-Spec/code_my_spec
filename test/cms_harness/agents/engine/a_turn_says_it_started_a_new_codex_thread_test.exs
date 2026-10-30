defmodule CmsHarness.Agents.Engine.ATurnSaysItStartedANewCodexThreadTest do
  @moduledoc """
  A Codex turn that could not resume its thread starts a new one and sends the
  whole transcript uncached, which is where a token burn comes from. The turn
  says so with its usage, so the check-in and token alert can.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Engine.Impl

  defp state(count, reason),
    do: %{"fresh_threads" => %{"count" => count, "reason" => reason}}

  test "a turn whose provider state counts one more new thread names its reason" do
    assert Impl.fresh_thread(state(1, "no_session"), state(2, "history_or_config_changed")) ==
             "history_or_config_changed"

    assert Impl.fresh_thread(nil, state(1, "no_session")) == "no_session"
  end

  test "a turn that resumed, or carries no Codex state, started none" do
    assert Impl.fresh_thread(state(2, "no_session"), state(2, "no_session")) == nil
    assert Impl.fresh_thread(nil, %{session_id: "claude"}) == nil
    assert Impl.fresh_thread(nil, nil) == nil
  end
end
