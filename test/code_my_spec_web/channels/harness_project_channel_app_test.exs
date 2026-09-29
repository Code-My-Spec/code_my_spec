defmodule CodeMySpecWeb.HarnessProjectChannelAppTest do
  @moduledoc """
  The wire for story 1108: the server can ask a connected copy to bring its
  own app up, restart it, or stop it, and get a correlated reply back.

  Same mechanism `start_agent`/`create_working_copy` already use — a
  `handle_call` mints a ref, pushes an event, parks the caller; the far side
  answers with a `_result` push carrying that ref, and `handle_in` replies to
  whoever is still waiting. These tests drive it from the server's own
  `handle_call`, standing in for what `CodeMySpec.WorkingCopies.AppTransport`
  does in production, and answer from the test process the way a harness's
  `ChannelClient` would — proving the round trip without booting one.
  """

  use CodeMySpecTest.DataCase, async: false

  import Phoenix.ChannelTest
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces.PreviewAddress
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket

  @endpoint CodeMySpecWeb.Endpoint
  @label "the harness at /workspace/app"

  setup do
    scope = full_scope_fixture()
    {:ok, _reply, socket} = join_as(scope)
    %{socket: socket}
  end

  defp join_as(scope) do
    socket(UserSocket, "harness_test", %{scope: scope})
    |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{scope.active_project_id}", %{
      "label" => @label,
      "harness_id" => scope.active_working_copy_id,
      "device" => %{"id" => device_fixture(scope).id}
    })
  end

  # The call blocks on the reply, same as a real `AppTransport` call would —
  # so it has to run off the test process, which is the one about to answer it.
  defp call_async(pid, message) do
    Task.async(fn -> GenServer.call(pid, message, 5_000) end)
  end

  # Simulates the harness's `_result` push and asserts the channel
  # acknowledged it — separate from `GenServer.reply/2` resolving the parked
  # `AppTransport` call, which the caller checks via `Task.await/1`.
  defp answer(socket, event, ref, payload) do
    push_ref = push(socket, event, Map.put(payload, "ref", ref))
    assert_reply push_ref, :ok
  end

  describe "ensure_app_running" do
    test "pushes the request and resolves once the far side answers", %{socket: socket} do
      task = call_async(socket.channel_pid, {:ensure_app_running, %{}})

      assert_push "ensure_app_running", %{"ref" => ref}
      assert is_binary(ref)

      answer(socket, "ensure_app_running_result", ref, %{
        "status" => "ok",
        "app_status" => "serving",
        "app_url" => "http://127.0.0.1:51234",
        "app_commit" => "abc123"
      })

      assert Task.await(task) ==
               {:ok, %{status: "serving", url: "http://127.0.0.1:51234", commit: "abc123"}}
    end

    test "an error on the far side comes back as an error, not a crash", %{socket: socket} do
      task = call_async(socket.channel_pid, {:ensure_app_running, %{}})

      assert_push "ensure_app_running", %{"ref" => ref}
      answer(socket, "ensure_app_running_result", ref, %{"status" => "error", "reason" => "no_start_recipe"})

      assert Task.await(task) == {:error, "no_start_recipe"}
    end
  end

  describe "restart_app" do
    test "same round trip, its own event names", %{socket: socket} do
      task = call_async(socket.channel_pid, {:restart_app, %{}})

      assert_push "restart_app", %{"ref" => ref}

      answer(socket, "restart_app_result", ref, %{
        "status" => "ok",
        "app_status" => "serving",
        "app_url" => "http://127.0.0.1:51235",
        "app_commit" => "def456"
      })

      assert {:ok, %{status: "serving"}} = Task.await(task)
    end
  end

  describe "stop_app" do
    test "answers :ok with no status payload to decode", %{socket: socket} do
      task = call_async(socket.channel_pid, {:stop_app, %{}})

      assert_push "stop_app", %{"ref" => ref}
      answer(socket, "stop_app_result", ref, %{"status" => "ok"})

      assert Task.await(task) == :ok
    end
  end

  describe "the harness holds the tunnel (2026-09-29)" do
    test "main with a stored tunnel is told to run it, on ensure and on restart" do
      scope = full_scope_fixture()
      {:ok, copy} = WorkingCopies.issue(scope, nil, label: "main", device: device_fixture(scope))
      {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/put_tunnel_main")
      assert copy.main, "the premise needs a copy that designated itself main"

      {:ok, _copy} =
        WorkingCopies.record_preview_tunnel(copy, %{
          preview_url: PreviewAddress.url(copy.id),
          preview_tunnel_id: "tunnel-1",
          preview_tunnel_secret: "s3cret"
        })

      {:ok, _reply, socket} = join_as(%{scope | active_working_copy_id: copy.id})

      for {verb, event} <- [{:ensure_app_running, "ensure_app_running"}, {:restart_app, "restart_app"}] do
        task = call_async(socket.channel_pid, {verb, %{}})

        assert_push ^event, %{"ref" => ref, "main" => true, "tunnel" => tunnel}

        assert tunnel["tunnel_id"] == "tunnel-1"
        assert tunnel["tunnel_secret"] == "s3cret"
        assert tunnel["hostname"] == PreviewAddress.host(copy.id)
        assert tunnel["account_tag"] == "test-account"

        answer(socket, "#{event}_result", ref, %{"status" => "ok", "app_status" => "serving"})
        Task.await(task)
      end
    end

    test "main with no tunnel of its own is told main, and told nothing about one" do
      scope = full_scope_fixture()
      {:ok, copy} = WorkingCopies.issue(scope, nil, label: "main", device: device_fixture(scope))
      {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/put_tunnel_main_none")
      assert copy.main

      {:ok, _reply, socket} = join_as(%{scope | active_working_copy_id: copy.id})

      task = call_async(socket.channel_pid, {:ensure_app_running, %{}})

      assert_push "ensure_app_running", %{"main" => true} = payload
      refute Map.has_key?(payload, "tunnel")

      answer(socket, "ensure_app_running_result", payload["ref"], %{
        "status" => "ok",
        "app_status" => "serving"
      })

      Task.await(task)
    end

    # A sibling sharing another copy's tunnel (criterion 1586) holds the same
    # tunnel id and secret on its own row — it must never be told to run a
    # connector of its own, only main may be.
    test "a non-main copy is never told to run a tunnel, even one sharing another's" do
      scope = full_scope_fixture()
      {:ok, worktree} = WorkingCopies.issue(scope, nil, label: "worktree", device: device_fixture(scope))

      {:ok, worktree} =
        WorkingCopies.record_app_status(worktree, %{
          status: "serving",
          url: "http://127.0.0.1:41234"
        })

      {:ok, worktree} =
        WorkingCopies.record_preview_tunnel(worktree, %{
          preview_url: PreviewAddress.url(worktree.id),
          preview_tunnel_id: "tunnel-1",
          preview_tunnel_secret: "s3cret"
        })

      refute worktree.main

      {:ok, _reply, socket} = join_as(%{scope | active_working_copy_id: worktree.id})

      task = call_async(socket.channel_pid, {:ensure_app_running, %{}})

      assert_push "ensure_app_running", %{"main" => false} = payload
      refute Map.has_key?(payload, "tunnel")

      answer(socket, "ensure_app_running_result", payload["ref"], %{
        "status" => "ok",
        "app_status" => "serving"
      })

      Task.await(task)
    end
  end
end
