defmodule CmsHarness.ARefusedUpgradeNamesWhyInTheHarnessLogTest do
  @moduledoc """
  Issue 62377cc3 / 620b0389, merged: a harness whose socket upgrade is
  refused with a 403 used to retry forever on the same backoff as a live
  credential, logging only `inspect(reason)` -- Mint's own upgrade-failure
  protocol error, the same for every refusal, never why the SERVER refused.
  One instance produced 537 identical refusals at a steady 30s; the real
  complaint in both reports is the hammering, not the missing log line.

  A 403 is now terminal: `ChannelClient.handle_disconnect/2` logs once with
  the reason `UserSocket.handle_connect_error/2` puts in the
  `x-connect-refusal-reason` header (Slipstream keeps headers on a failed
  upgrade but discards the body), stops scheduling `:reconnect` entirely,
  and records the reason where `CmsHarness.Channel.terminal_refusal/1`
  (and so `/health`) can show it to whoever is running the harness. Network
  errors and 5xx are untouched -- same backoff, same reschedule, same log
  shape as before this issue.

  Driven the same way `channel_client_transport_test.exs` already drives
  `handle_disconnect/2`: a plain `%Slipstream.Socket{}` built by hand, no
  live connection, no socket to production.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CmsHarness.Project.ChannelClient

  setup do
    Process.put({CmsHarness.Project.Transport, :impl}, CmsHarness.Project.Transport.Test)
    Process.put({CmsHarness.Project.Transport.Test, :owner}, self())
    :ok
  end

  defp socket do
    %Slipstream.Socket{
      assigns: %{
        joined: false,
        refused: nil,
        terminal_refusal: nil,
        attempts: 0,
        pending: %{},
        topic: "harness_project:p1",
        project: %{id: "p1", root: "/tmp/x"}
      }
    }
  end

  defp upgrade_failure(status, headers \\ []) do
    {:upgrade_failure,
     %{
       status_code: status,
       resp_headers: headers,
       reason: %Mint.WebSocket.UpgradeFailureError{status_code: status}
     }}
  end

  describe "a 403" do
    test "is logged once, with the server's own reason, and stops retrying" do
      reason = upgrade_failure(403, [{"x-connect-refusal-reason", "token_not_found"}])

      {{:ok, stopped}, log} =
        with_log(fn -> ChannelClient.handle_disconnect(reason, socket()) end)

      assert log =~ "the server refused this harness's socket upgrade (token_not_found)"
      assert log =~ "stopping"

      refute log =~ "UpgradeFailureError",
             "the clearer reason should replace Mint's own error, not sit beside it"

      assert stopped.assigns.terminal_refusal == "token_not_found"
      assert stopped.assigns.joined == false

      refute_receive :reconnect,
                     100,
                     "a terminal refusal must never be retried on a timer"
    end

    test "with no reason header still stops, and says so plainly" do
      reason = upgrade_failure(403)

      {{:ok, stopped}, log} =
        with_log(fn -> ChannelClient.handle_disconnect(reason, socket()) end)

      assert log =~ "no reason given"
      assert stopped.assigns.terminal_refusal == "no reason given"

      refute_receive :reconnect, 100
    end
  end

  describe "anything other than a 403" do
    test "a 5xx on the upgrade still retries, unchanged" do
      reason = upgrade_failure(503)

      {{:ok, retrying}, log} =
        with_log(fn -> ChannelClient.handle_disconnect(reason, socket()) end)

      assert log =~ "upgrade_failure"
      assert retrying.assigns.attempts == 1
      assert_receive :reconnect, 1_500
    end

    test "an ordinary disconnect reason still retries, unchanged" do
      {{:ok, retrying}, log} =
        with_log(fn -> ChannelClient.handle_disconnect(:closed_by_remote, socket()) end)

      assert log =~ "closed_by_remote"
      assert retrying.assigns.attempts == 1
      assert_receive :reconnect, 1_500
    end
  end

  describe "retry_now/2" do
    test "clears a terminal refusal and resets the attempt count" do
      stopped =
        socket()
        |> Map.update!(
          :assigns,
          &Map.merge(&1, %{terminal_refusal: "token_not_found", attempts: 3})
        )

      {:noreply, resumed} = ChannelClient.handle_cast(:retry_now, stopped)

      assert resumed.assigns.terminal_refusal == nil
      assert resumed.assigns.attempts == 0
    end
  end
end
