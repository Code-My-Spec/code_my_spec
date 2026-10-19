defmodule CmsHarness.ChannelClientRegistrationResultTest do
  @moduledoc """
  Issue 37f35126: the harness's own transport-level ack of a
  "create_working_copy_result" push only ever confirmed the server
  received it -- never that `Staffing.mint/2`'s own registration
  (`WorkingCopies.issue/3`, `report_root/2`) went on to succeed, since
  that runs afterward, in a different process. These prove the explicit
  signal that closes that gap: an error rolls back immediately, through
  the same `rollback_if_untouched/3` the existing ack-timeout path already
  used; an ok clears cleanly; an unknown id is a no-op; and the two
  tracking maps (the existing ack-based one, and this one) are
  independent, so clearing one never silently clears the other.

  Not async, for the same reason `ChannelClientCreateAckTest` is not: meck
  patches `CmsHarness.WorkingCopies.Create` for the whole VM.
  """
  use ExUnit.Case, async: false

  alias CmsHarness.Project.ChannelClient
  alias CmsHarness.Project.Transport
  alias CmsHarness.WorkingCopies.Create

  setup do
    Process.put({Transport, :impl}, CmsHarness.Project.Transport.Test)
    Process.put({CmsHarness.Project.Transport.Test, :owner}, self())
    :ok
  end

  defp socket(assigns \\ %{}) do
    %Slipstream.Socket{
      assigns:
        Map.merge(
          %{joined: true, topic: "harness_project:p1", project: %{id: "p1", root: "/tmp/x"}},
          assigns
        )
    }
  end

  @ok_result {:ok,
              %{
                root: "/tmp/x-copy",
                working_copy_id: "wc1",
                setup: :project_recipe,
                base_head: "deadbeef"
              }}

  defp with_pending_registration do
    {:noreply, socket} =
      ChannelClient.handle_info(
        {:create_working_copy_result, "harness_project:p1", "ref-1", "/tmp/x", @ok_result},
        socket()
      )

    socket
  end

  test "an ok registration clears the pending entry and rolls nothing back" do
    :meck.new(Create, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(Create) end)

    socket = with_pending_registration()

    {:ok, socket} =
      ChannelClient.handle_message(
        "harness_project:p1",
        "create_working_copy_registered",
        %{"working_copy_id" => "wc1", "status" => "ok"},
        socket
      )

    refute :meck.called(Create, :rollback_if_untouched, :_)
    refute Map.has_key?(socket.assigns[:pending_registration] || %{}, "wc1")
  end

  test "an error registration rolls back immediately, without waiting for the ack timeout" do
    :meck.new(Create, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(Create) end)

    :meck.expect(Create, :rollback_if_untouched, fn root, target, base_head ->
      send(self(), {:rolled_back, root, target, base_head})
      :ok
    end)

    socket = with_pending_registration()

    {:ok, socket} =
      ChannelClient.handle_message(
        "harness_project:p1",
        "create_working_copy_registered",
        %{"working_copy_id" => "wc1", "status" => "error"},
        socket
      )

    assert_receive {:rolled_back, "/tmp/x", "/tmp/x-copy", "deadbeef"}
    refute Map.has_key?(socket.assigns[:pending_registration] || %{}, "wc1")
  end

  test "an unknown working_copy_id is a no-op" do
    :meck.new(Create, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(Create) end)

    {:ok, _socket} =
      ChannelClient.handle_message(
        "harness_project:p1",
        "create_working_copy_registered",
        %{"working_copy_id" => "no-such-copy", "status" => "error"},
        socket()
      )

    refute :meck.called(Create, :rollback_if_untouched, :_)
  end

  test "the transport ack clearing the existing tracking never clears this one" do
    :meck.new(Create, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(Create) end)

    socket = with_pending_registration()
    assert_receive {:transport_push, _, "create_working_copy_result", _, native_ref}

    {:ok, socket} = ChannelClient.handle_reply(native_ref, {:ok, %{}}, socket)

    assert Map.has_key?(socket.assigns[:pending_registration] || %{}, "wc1"),
           "the ack and the explicit registration outcome track independently -- " <>
             "receiving one must never silently clear the other"
  end
end
