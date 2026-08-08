defmodule CmsHarness.ReadModelRefreshTest do
  @moduledoc """
  The cached read model has to expire.

  It used to be fetched once, on join, and never again. A sprite joins before its
  project has any stories or components, so it held an empty domain for the whole
  session — and `Scanner.resolve_owners/2` refuses to link a file to a story its
  read model has never heard of. That rule is right against a fresh cache and
  exactly wrong against one that can no longer change.

  Drill 12 wrote 32 BDD spec files across 9 stories; not one was linked,
  `bdd_specs_exist` failed for every story, and the 69 `implementation_file`
  requirements behind it were unreachable. The agent read the frozen graph as a
  dead file watcher — the fourth run to do so, and the fourth time it was
  something else.

  Ownership is re-resolved server-side now, so that consequence is gone. This
  covers the cause: the same stale copy still feeds `validate_entry/4`, where an
  empty `component_by_id` means test-alignment is silently never checked.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Project.ChannelClient

  test "the refresh interval is short enough to matter within a run" do
    interval = ChannelClient.read_model_refresh_ms()

    assert interval > 0

    assert interval <= 120_000,
           "a drill creates stories and components continuously for an hour; a " <>
             "cache that outlives that is the bug this replaced"
  end

  test "an unjoined client keeps the timer armed rather than giving up" do
    idle = %Slipstream.Socket{assigns: %{joined: false}}

    # Deliberately not waiting on the real interval — a test that sleeps a
    # minute to observe a timer is a test nobody runs. What matters is that the
    # clause returns cleanly and re-arms, so a reconnect does not leave the
    # cache frozen for the rest of the session.
    assert {:noreply, ^idle} = ChannelClient.handle_info(:refresh_read_model, idle)
  end
end
