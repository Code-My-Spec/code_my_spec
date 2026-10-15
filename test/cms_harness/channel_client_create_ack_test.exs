defmodule CmsHarness.ChannelClientCreateAckTest do
  @moduledoc """
  68d37919: a create_working_copy's reply used to go out as a bare,
  unacknowledged push. If the server never came back -- a crashed channel, a
  lost connection -- the harness had no way to know, and the worktree and
  identity file it had already written sat there with nothing on the server
  recording it. These prove the other half: the create is tracked by a
  native reply ref, cleared the moment the ack arrives, and rolled back if it
  never does.

  Not async: :meck patches CmsHarness.WorkingCopies.Create for the whole VM,
  which this project's own established convention (analysis_controller_test,
  recorded_output_replay_test) already keeps off the async lane for exactly
  that reason.
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

  test "the result is pushed with a tracked native reply" do
    {:noreply, _socket} =
      ChannelClient.handle_info(
        {:create_working_copy_result, "harness_project:p1", "ref-1", "/tmp/x", @ok_result},
        socket()
      )

    assert_receive {:transport_push, "harness_project:p1", "create_working_copy_result", payload,
                    _native_ref}

    assert payload["ref"] == "ref-1"
  end

  test "an ack within the timeout clears the pending entry so no rollback is attempted" do
    :meck.new(Create, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(Create) end)

    {:noreply, socket} =
      ChannelClient.handle_info(
        {:create_working_copy_result, "harness_project:p1", "ref-1", "/tmp/x", @ok_result},
        socket()
      )

    assert_receive {:transport_push, _, "create_working_copy_result", _, native_ref}

    {:ok, socket} = ChannelClient.handle_reply(native_ref, {:ok, %{}}, socket)

    {:noreply, _socket} = ChannelClient.handle_info({:create_ack_timeout, native_ref}, socket)

    refute :meck.called(Create, :rollback_if_untouched, :_)
  end

  test "no ack within the timeout rolls back what the create made" do
    :meck.new(Create, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(Create) end)

    :meck.expect(Create, :rollback_if_untouched, fn root, target, base_head ->
      send(self(), {:rolled_back, root, target, base_head})
      :ok
    end)

    {:noreply, socket} =
      ChannelClient.handle_info(
        {:create_working_copy_result, "harness_project:p1", "ref-1", "/tmp/x", @ok_result},
        socket()
      )

    assert_receive {:transport_push, _, "create_working_copy_result", _, native_ref}

    {:noreply, _socket} = ChannelClient.handle_info({:create_ack_timeout, native_ref}, socket)

    assert_receive {:rolled_back, "/tmp/x", "/tmp/x-copy", "deadbeef"}
  end

  test "a failed create has nothing to track, so a missed ack never attempts a rollback" do
    :meck.new(Create, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(Create) end)

    {:noreply, socket} =
      ChannelClient.handle_info(
        {:create_working_copy_result, "harness_project:p1", "ref-1", "/tmp/x",
         {:error, {:already_exists, "/tmp/x-copy"}}},
        socket()
      )

    assert_receive {:transport_push, _, "create_working_copy_result", _, native_ref}

    {:noreply, _socket} = ChannelClient.handle_info({:create_ack_timeout, native_ref}, socket)

    refute :meck.called(Create, :rollback_if_untouched, :_)
  end
end
