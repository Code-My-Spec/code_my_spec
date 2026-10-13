defmodule CodeMySpecWeb.FsResultReasonTest do
  @moduledoc """
  A file that is missing on a harness is `:enoent`, as it is anywhere else.

  87099ba04 stopped `fs_result` minting an atom for every reason off the wire,
  and a missing file came back as `"enoent"`. Every caller matching
  `{:error, :enoent}` then fell through on a harness environment (8e3669fc).
  """
  # Not async: the channel takes the project's advisory lock on join.
  use CodeMySpecTest.DataCase, async: false

  import Phoenix.ChannelTest
  import CodeMySpec.UsersFixtures

  alias CmsHarness.Project.ChannelClient
  alias CodeMySpecWeb.HarnessProjectChannel

  @endpoint CodeMySpecWeb.Endpoint

  @fs_reasons ~w(enoent eacces eperm eisdir enotdir eexist enotempty enospc edquot
                 erofs ebusy etxtbsy enametoolong eloop exdev emfile enfile efbig eio
                 einval ebadf enomem espipe emlink badarg not_regular
                 no_working_directory)a

  describe "decode_fs_result/1" do
    test "a filesystem reason comes back as its atom" do
      for reason <- @fs_reasons do
        assert HarnessProjectChannel.decode_fs_result(%{"error" => Atom.to_string(reason)}) ==
                 {:error, reason}
      end
    end

    test "decodes what the harness encodes, for every filesystem reason" do
      for reason <- @fs_reasons do
        wire = {:error, reason} |> ChannelClient.encode_fs_result() |> json_round_trip()
        assert HarnessProjectChannel.decode_fs_result(wire) == {:error, reason}
      end
    end

    test "an unknown reason stays a string rather than becoming an atom" do
      reason = "eweird_#{System.unique_integer([:positive])}"

      assert HarnessProjectChannel.decode_fs_result(%{"error" => reason}) == {:error, reason}

      assert_raise ArgumentError, fn -> String.to_existing_atom(reason) end
    end

    test "a structured refusal keeps its structure" do
      assert HarnessProjectChannel.decode_fs_result(%{"error" => %{"reason" => "dirty"}}) ==
               {:error, %{"reason" => "dirty"}}
    end

    test "a reason that is neither a string nor a map is unreadable, not an error atom" do
      assert {:error, {:unreadable_fs_result, _}} =
               HarnessProjectChannel.decode_fs_result(%{"error" => 42})
    end
  end

  describe "over the channel" do
    setup do
      scope = full_scope_fixture()

      {:ok, _reply, socket} =
        CodeMySpecWeb.UserSocket
        |> socket("harness_socket:#{scope.active_working_copy_id}", %{scope: scope})
        |> subscribe_and_join(
          HarnessProjectChannel,
          "harness_project:#{scope.active_project_id}",
          %{
            "label" => "fs reasons",
            "harness_id" => scope.active_working_copy_id
          }
        )

      %{socket: socket}
    end

    test "a missing file reaches the cloud caller as :enoent", %{socket: socket} do
      task =
        Task.async(fn ->
          GenServer.call(socket.channel_pid, {:fs_request, "read_file", %{"path" => "x"}}, 5_000)
        end)

      assert_push "fs_request", pushed, 2_000

      push(
        socket,
        "fs_result",
        Map.put(ChannelClient.encode_fs_result({:error, :enoent}), "ref", pushed["ref"])
      )

      assert Task.await(task, 3_000) == {:error, :enoent}
    end
  end

  # A screenshot read for QA's evidence went into the JSON reply as raw PNG; the
  # encoder raised and took the copy's channel, and both agents' turns, down
  # (2026-10-13).
  describe "a file that is not text" do
    @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>

    test "crosses the wire and comes back byte for byte" do
      sent = ChannelClient.encode_fs_result({:ok, @png})

      assert HarnessProjectChannel.decode_fs_result(json_round_trip(sent)) == {:ok, @png}
    end

    test "text still crosses as itself" do
      sent = ChannelClient.encode_fs_result({:ok, "# Brief\n"})

      assert sent["result"] == "# Brief\n"
      assert HarnessProjectChannel.decode_fs_result(json_round_trip(sent)) == {:ok, "# Brief\n"}
    end
  end

  defp json_round_trip(map), do: map |> Jason.encode!() |> Jason.decode!()
end
