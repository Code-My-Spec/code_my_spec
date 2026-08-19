defmodule CmsHarness.ManifestReplyShapesTest do
  @moduledoc """
  A reply the harness cannot read is not a refusal.

  Found by running drill 16. A sprite image built 2026-08-02 met a server
  carrying `6e389c29` from 2026-08-09, which changed the manifest reply from
  counts to `%{"status" => "accepted", "observations" => n}`. The old harness
  had no clause for the new shape, fell through to the catch-all, and logged:

      [CmsHarness] the server REJECTED the manifest for /workspace/e2e_todo:
      {:ok, %{"observations" => 51, "status" => "accepted"}}

  The word REJECTED sits directly above the server saying "accepted". Worse, the
  message's own closing line guesses version skew — correctly — while its
  headline asserts a refusal that did not happen. And `drill.sh` waits for the
  string "accepted the manifest" before starting the agent, so a drill whose
  manifest landed perfectly well timed out at the preflight and reported the
  harness as broken.

  The clause for an *older* server already existed, with the reasoning written
  out: "Anything that still replies with counts accepted the manifest, and
  calling it a rejection would be a lie in the direction that costs the most."
  That is exactly right and the same courtesy was owed in the other direction —
  to a server newer than the harness.

  These pin the three shapes and, more importantly, the boundary: a reply that
  says it succeeded is never reported as a refusal, whatever else it carries.
  """

  # Not async: this lowers the global Logger level, and doing that under other
  # tests would change what they capture.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CmsHarness.Project.ChannelClient

  # The suite runs at `warning` (config/test.exs), so `Logger.info` is dropped
  # before any handler sees it and `capture_log`'s own `level:` cannot recover
  # what was never emitted. Two of the accepting cases log at info, which is
  # correct — an accepted manifest is not a warning — so the level has to come
  # down here rather than the code being made noisier to suit the test.
  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  # A real `%Slipstream.Socket{}` — `Slipstream.Socket.assign/3` matches on the
  # struct, and `handle_reply/3` assigns before it branches. A bare map passes
  # the pattern in the function head and dies one line later, which reads as a
  # bug in the code under test rather than in the fixture.
  defp socket do
    %Slipstream.Socket{
      assigns: %{observations_ref: make_ref(), project: %{root: "/workspace/app"}}
    }
  end

  defp reply_with(payload) do
    s = socket()
    ref = s.assigns.observations_ref

    # `level: :info` explicitly. The suite's Logger level drops info and
    # warning, so a bare `capture_log` returns "" for exactly the accepting
    # cases — and `refute log =~ "REJECTED"` passes vacuously against an empty
    # string. Every test below therefore also asserts something positive, so an
    # empty capture fails loudly instead of reading as a pass.
    capture_log([level: :info], fn ->
      assert {:ok, _socket} = ChannelClient.handle_reply(ref, payload, s)
    end)
  end

  describe "a reply that says it was accepted" do
    test "the current shape is accepted quietly" do
      log = reply_with({:ok, %{"status" => "accepted", "observations" => 51}})

      assert log =~ "accepted the manifest"
      assert log =~ "51 observations"
      refute log =~ "REJECTED"
    end

    test "an older server's counts are still accepted" do
      log = reply_with({:ok, %{"upserted" => 12, "removed" => 3}})

      assert log =~ "accepted the manifest"
      refute log =~ "REJECTED"
    end

    test "extra keys on the known shape change nothing" do
      # Map patterns are partial, so a server that adds a field is still the
      # known shape. Worth pinning: it is the cheap half of forward tolerance
      # and it already worked.
      log =
        reply_with(
          {:ok, %{"status" => "accepted", "observations" => 51, "something_new" => %{"a" => 1}}}
        )

      assert log =~ "accepted the manifest"
      refute log =~ "REJECTED"
    end

    test "a shape this harness does not recognise is not a refusal" do
      # The generalised drill-16 case. That drill's reply carried counts and so
      # matches the clause above on current code — the harness that mislabelled
      # it was a week old and had no such clause. This is the same event as seen
      # from *today's* harness meeting a *future* server: an explicit success in
      # a shape with nothing else familiar in it.
      log = reply_with({:ok, %{"status" => "accepted", "reconcile_id" => "r-1"}})

      refute log =~ "REJECTED",
             "the server said accepted; only the shape was unfamiliar"

      assert log =~ "accepted the manifest"
      assert log =~ "older than the server", "say which end to fix"
    end

    test "drill.sh's preflight string survives every accepting shape" do
      # `drill.sh` greps the container log for this literal before starting the
      # agent. If any accepting shape stops emitting it, a healthy drill hangs
      # at the preflight and reports the harness as broken — which is how this
      # was found.
      for payload <- [
            {:ok, %{"status" => "accepted", "observations" => 51}},
            {:ok, %{"upserted" => 1, "removed" => 0}},
            {:ok, %{"status" => "accepted", "unknown" => true}}
          ] do
        assert reply_with(payload) =~ "accepted the manifest",
               "drill.sh waits on this string for #{inspect(payload)}"
      end
    end
  end

  describe "a reply that does not claim success" do
    test "is still reported as a refusal, loudly" do
      log = reply_with({:error, %{"reason" => "project not served here"}})

      assert log =~ "REJECTED the manifest"
      assert log =~ "out of step with the disk"
    end

    # This used to be the example above, and it was the wrong one to pick.
    #
    # `unmatched topic` is what a push gets when the channel has already left
    # its topic, which is ordinary shutdown: `stop`, `just refresh` and
    # `refresh-harness` all leave a scan in flight whose manifest lands after
    # the leave. It fires on every restart, on the *outgoing* instance, seconds
    # before anything else has tried to join.
    #
    # Reported as a loud refusal carrying "usually version skew", it cost a QA
    # agent a session: it compared shas across two checkouts, checked whether a
    # bare restart cleared the symptom, and concluded "genuine code drift" —
    # careful reasoning from a premise the log asserted and did not hold
    # (`2d26df7c`).
    #
    # Quiet is honest here because nothing is lost. A rejoin re-scans and
    # re-sends the whole manifest — `holding` is followed by `scanned N files`
    # and `sent N observations` on every join, verified in harness.log — so the
    # dropped push is replaced rather than missed.
    test "a push that lands after the channel left its topic is not a refusal" do
      log = reply_with({:error, %{"reason" => "unmatched topic"}})

      refute log =~ "REJECTED the manifest",
             "restart noise reported as a refusal sends people hunting version skew"

      assert log =~ "shutting down or reconnecting"
    end

    test "an unrecognised reply with no success claim is a refusal" do
      # The catch-all keeps its teeth. Silence about success is not success —
      # the whole point of the original clause was that a sync nobody noticed
      # failing leaves the requirement graph computed from a stale picture.
      assert reply_with({:ok, %{"queued" => 4}}) =~ "REJECTED the manifest"
    end
  end
end
