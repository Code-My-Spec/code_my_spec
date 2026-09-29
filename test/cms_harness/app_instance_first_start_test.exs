defmodule CmsHarness.AppInstanceFirstStartTest do
  @moduledoc """
  2026-09-29, Harness session: a live QA defect on metric_flow (its
  `assets/node_modules` was never installed, story 1108's per-copy apps
  read as "serving" with a dead JS bundle) led to a broader fix — a genuine
  first start's cold `npm install`/compile can legitimately outrun the
  120s ceiling every other `ensure_running` call gets, and a `GenServer.call`
  that never replies within its own timeout used to read as a crash to its
  caller (an agent's own tool-call timeout), not a slow-but-working copy.

  So a first start (`commit == nil` — never successfully started before, as
  opposed to an ordinary restart, which by definition always has one) never
  blocks past a short inline window: it replies `starting`, with the
  address, and keeps polling in the background toward its own 10-minute
  ceiling, reporting the eventual `serving`/`erroring` transition through
  `app_status` (see `criterion_1526_...spex.exs` for that push, exercised
  through the full channel/`FakeServer` round trip). What this file covers
  instead is `AppInstance`'s own internal state directly — the ordinary
  restart path is genuinely unchanged, and that is easiest to prove by
  reading `:sys.get_state/1` rather than threading it through a channel.
  """

  use ExUnit.Case, async: false

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarness.AppInstance
  alias CmsHarnessTest.FakeAppInstanceRunner

  describe "a first start that outlasts the short inline window" do
    test "reports starting immediately, then serving once the background watch catches up" do
      %{root: root} = app_instance_rig(probe: :down)

      assert %{"status" => "ok", "app_status" => "starting"} = push_app_event("ensure_app_running")

      # The copy is genuinely still coming up — `probe: :down` above is the
      # scripted stand-in for "the port doesn't answer yet," not a crash. Once
      # it would actually be serving, nothing new needs to be asked of the
      # copy: the same background watch that just reported `starting` picks
      # this up on its own next tick.
      FakeAppInstanceRunner.put_probe(:serving)

      # Forced directly rather than waiting out `health_wait_interval_ms/0`'s
      # real delay: `:first_start_check` is the same message
      # `Process.send_after/3` would deliver on its own, and `:sys.get_state/1`
      # right after is a barrier on this GenServer having fully processed it
      # (the same reasoning `sync_after_reply/1` documents), not a read of
      # internals a spex would be barred from — this is a plain `mix test`
      # file inside `CmsHarness`'s own namespace.
      pid = GenServer.whereis(AppInstance.via(root))
      send(pid, :first_start_check)
      state = :sys.get_state(pid)

      assert state.status == "serving"
      assert state.first_start_deadline == nil
    end
  end

  describe "an ordinary restart is unchanged" do
    test "a copy that has already started once, and now never answers, still reports down within the old bounded wait" do
      %{root: root} = app_instance_rig(database_exists?: true)

      # Establishes a real prior success — `commit` is only ever set once
      # `launch_process/1` succeeds, which is exactly what makes the next
      # call an "ordinary restart" rather than a first start.
      assert %{"status" => "ok", "app_status" => "serving"} = push_app_event("ensure_app_running")

      FakeAppInstanceRunner.put_probe(:down)

      assert %{"status" => "ok", "app_status" => "down"} = push_app_event("restart_app")

      state = :sys.get_state(GenServer.whereis(AppInstance.via(root)))
      assert state.first_start_deadline == nil, "an ordinary restart must never enter the first-start ceiling path"
    end
  end
end
