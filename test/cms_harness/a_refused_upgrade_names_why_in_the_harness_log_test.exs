defmodule CmsHarness.ARefusedUpgradeNamesWhyInTheHarnessLogTest do
  @moduledoc """
  Issue 62377cc3: a refused socket upgrade logged only `inspect(reason)` --
  Mint's own upgrade-failure protocol error, which reads the same for every
  refusal and never says why the SERVER refused. `UserSocket.handle_connect_error/2`
  now answers with an `x-connect-refusal-reason` header; `ChannelClient`'s
  `disconnect_summary/1` reads it back so the log names the actual cause.

  Driven the same way `channel_client_transport_test.exs` already drives
  `handle_disconnect/2`: a plain `%Slipstream.Socket{}` built by hand, no
  live connection.
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
        attempts: 0,
        pending: %{},
        topic: "harness_project:p1",
        project: %{id: "p1", root: "/tmp/x"}
      }
    }
  end

  test "a refusal the server explained is logged with that reason, not Mint's own error" do
    reason =
      {:upgrade_failure,
       %{
         status_code: 403,
         resp_headers: [{"x-connect-refusal-reason", "token_not_found"}],
         reason: %Mint.WebSocket.UpgradeFailureError{status_code: 403}
       }}

    {_result, log} = with_log(fn -> ChannelClient.handle_disconnect(reason, socket()) end)

    assert log =~ "refused by the server: token_not_found"

    refute log =~ "UpgradeFailureError",
           "the clearer reason should replace Mint's own error, not sit beside it"
  end

  test "a refusal with no reason header still logs something, unchanged" do
    reason = {:upgrade_failure, %{status_code: 403, resp_headers: [], reason: :no_status_line}}

    {_result, log} = with_log(fn -> ChannelClient.handle_disconnect(reason, socket()) end)

    assert log =~ "upgrade_failure"
  end

  test "an ordinary disconnect reason is logged exactly as before" do
    {_result, log} =
      with_log(fn -> ChannelClient.handle_disconnect(:closed_by_remote, socket()) end)

    assert log =~ "closed_by_remote"
  end
end
