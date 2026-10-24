defmodule CodeMySpecWeb.HarnessProjectChannelAppTest do
  @moduledoc """
  The wire for story 1108: the server can ask a connected copy to bring its
  own app up, restart it, or stop it, and get a correlated reply back.

  Same mechanism `start_agent`/`create_working_copy` already use — a
  `handle_call` mints a ref, pushes an event, parks the caller; the far side
  answers with a `_result` push carrying that ref, and `handle_in` replies to
  whoever is still waiting. These tests drive it from the server's own
  `handle_call`, standing in for what `CodeMySpec.AppInstances.Transport`
  does in production, and answer from the test process the way a harness's
  `ChannelClient` would — proving the round trip without booting one.
  """

  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import Phoenix.ChannelTest
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.AppInstances
  alias CodeMySpec.Workspaces.PreviewAddress
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket

  @endpoint CodeMySpecWeb.Endpoint
  @label "the harness at /workspace/app"

  setup do
    scope = full_scope_fixture()
    {:ok, _reply, socket} = join_as(scope)
    %{socket: socket, scope: scope}
  end

  defp join_as(scope) do
    Process.put(:app_test_scope, scope)
    {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)

    socket(UserSocket, "harness_test", %{scope: scope})
    |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{scope.active_project_id}", %{
      "label" => @label,
      "root" => copy.root || scope.cwd,
      "harness_id" => scope.active_working_copy_id,
      "device" => %{"id" => copy.device_id || device_fixture(scope).id}
    })
  end

  # The call blocks on the reply, same as a real `AppTransport` call would —
  # so it has to run off the test process, which is the one about to answer it.
  defp call_async(pid, {verb, request}) do
    scope = Process.get(:app_test_scope)

    descriptor =
      scope
      |> AppInstances.for_working_copy(scope.active_working_copy_id)
      |> AppInstances.descriptor()

    message = {verb, Map.put_new(request, :instance, descriptor)}
    Task.async(fn -> GenServer.call(pid, message, :infinity) end)
  end

  # Simulates the harness's `_result` push and asserts the channel
  # acknowledged it — separate from `GenServer.reply/2` resolving the parked
  # `AppTransport` call, which the caller checks via `Task.await/1`.
  defp answer(socket, event, ref, payload) do
    payload = Map.put_new(payload, "instance_id", Process.get({:app_reply_id, ref}))
    push_ref = push(socket, event, Map.put(payload, "ref", ref))
    assert %Phoenix.Socket.Reply{status: :ok, payload: %{}} = await_reply(push_ref)
  end

  # These waits follow protocol events; ExUnit's test deadline bounds a stall.
  defp await_push(event) do
    receive do
      %Phoenix.Socket.Message{event: ^event, payload: payload} ->
        Process.put({:app_reply_id, payload["ref"]}, get_in(payload, ["instance", "instance_id"]))
        payload
    end
  end

  defp await_reply(ref) do
    receive do
      %Phoenix.Socket.Reply{ref: ^ref} = reply -> reply
    end
  end

  describe "ensure_app_running" do
    test "pushes the request and resolves once the far side answers", %{socket: socket} do
      task = call_async(socket.channel_pid, {:ensure_app_running, %{}})

      assert %{"ref" => ref} = await_push("ensure_app_running")
      assert is_binary(ref)

      answer(socket, "ensure_app_running_result", ref, %{
        "status" => "ok",
        "app_status" => "serving",
        "app_url" => "http://127.0.0.1:51234",
        "app_commit" => "abc123"
      })

      assert Task.await(task) ==
               {:ok,
                %{
                  instance_id: Process.get({:app_reply_id, ref}),
                  status: "serving",
                  url: "http://127.0.0.1:51234",
                  commit: "abc123",
                  serving_commit: nil,
                  head: nil,
                  action: nil,
                  action_reason: nil
                }}
    end

    # 048d1f4f: an agent read its own copy's app, launched before HEAD moved,
    # as main failing to restart after a promote.
    test "the tool names the copy, and says when HEAD moved past the commit being served" do
      scope = full_scope_fixture()
      {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)
      {:ok, _copy} = WorkingCopies.report_root(copy, "/tmp/ensure_tool_three_features")
      {:ok, _reply, socket} = join_as(scope)

      frame = %Anubis.Server.Frame{assigns: %{current_scope: scope}}

      task =
        Task.async(fn ->
          ToolLibrary.run(
            "ensure_app_running",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )
        end)

      assert %{"ref" => ref} = await_push("ensure_app_running")

      answer(socket, "ensure_app_running_result", ref, %{
        "status" => "ok",
        "app_status" => "serving",
        "app_url" => "http://127.0.0.1:59302",
        "app_commit" => "e6d1d8fc",
        "app_head" => "bb936fa6"
      })

      response = Task.await(task)
      text = response_text(response)

      assert text =~ "/tmp/ensure_tool_three_features"
      assert text =~ "e6d1d8fc"
      assert text =~ "bb936fa6"
      assert match?({:error, _}, response)
      assert text =~ "Do not test against this app yet"
      assert text =~ "QA requires matching revisions"
      assert text =~ "restart_app"
      refute text =~ "http://127.0.0.1:59302"
    end

    for health <- ["down", "erroring"] do
      test "the tool explains an #{health} app and distinguishes its last commit from HEAD" do
        scope = full_scope_fixture()
        {:ok, _reply, socket} = join_as(scope)
        frame = %Anubis.Server.Frame{assigns: %{current_scope: scope}}

        task =
          Task.async(fn ->
            ToolLibrary.run(
              "ensure_app_running",
              %{},
              Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
            )
          end)

        assert %{"ref" => ref} = await_push("ensure_app_running")

        answer(socket, "ensure_app_running_result", ref, %{
          "status" => "ok",
          "app_status" => unquote(health),
          "app_commit" => "old111",
          "app_head" => "new222",
          "app_action_reason" => "The health probe failed; inspect log /tmp/candidate.log."
        })

        response = Task.await(task)
        assert match?({:error, _}, response)
        text = response_text(response)
        assert text =~ "old111"
        assert text =~ "new222"
        assert text =~ "/tmp/candidate.log"
        assert text =~ "Not serving"
      end
    end

    # A first start that has not come up within its inline window answers
    # `starting`; the server read that as an unexpected reply and failed the call.
    test "a first start still booting comes back as starting, not an error", %{socket: socket} do
      task = call_async(socket.channel_pid, {:ensure_app_running, %{}})

      assert %{"ref" => ref} = await_push("ensure_app_running")

      answer(socket, "ensure_app_running_result", ref, %{
        "status" => "ok",
        "app_status" => "starting",
        "app_url" => "http://127.0.0.1:51234",
        "app_commit" => "abc123"
      })

      assert {:ok, %{status: "starting", url: "http://127.0.0.1:51234"}} = Task.await(task)
    end

    test "the tool reports a first start still booting as starting, not as a failure" do
      scope = full_scope_fixture()
      {:ok, _reply, socket} = join_as(scope)

      frame = %Anubis.Server.Frame{assigns: %{current_scope: scope}}

      task =
        Task.async(fn ->
          ToolLibrary.run(
            "ensure_app_running",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )
        end)

      assert %{"ref" => ref} = await_push("ensure_app_running")

      answer(socket, "ensure_app_running_result", ref, %{
        "status" => "ok",
        "app_status" => "starting",
        "app_url" => "http://127.0.0.1:59303",
        "app_commit" => "e6d1d8fc"
      })

      response = Task.await(task)

      assert match?({:ok, _}, response), response_text(response)
      assert response_text(response) =~ "starting e6d1d8fc at http://127.0.0.1:59303"
    end

    test "an error on the far side comes back as an error, not a crash", %{socket: socket} do
      task = call_async(socket.channel_pid, {:ensure_app_running, %{}})

      assert %{"ref" => ref} = await_push("ensure_app_running")

      answer(socket, "ensure_app_running_result", ref, %{
        "status" => "error",
        "reason" => "no_start_recipe"
      })

      assert Task.await(task) == {:error, "no_start_recipe"}
    end
  end

  describe "restart_app" do
    test "same round trip, its own event names", %{socket: socket} do
      task = call_async(socket.channel_pid, {:restart_app, %{}})

      assert %{"ref" => ref} = await_push("restart_app")

      answer(socket, "restart_app_result", ref, %{
        "status" => "ok",
        "app_status" => "serving",
        "app_url" => "http://127.0.0.1:51235",
        "app_commit" => "def456"
      })

      assert {:ok, %{status: "serving"}} = Task.await(task)
    end
  end

  describe "reload_app" do
    test "a harness that never declared it is refused at once, never pushed", %{socket: socket} do
      task = call_async(socket.channel_pid, {:reload_app, %{}})

      assert Task.await(task) == {:error, :reload_not_supported}
      refute_push("reload_app", _)
    end

    test "a harness that declared it gets the push, and the serving commit is recorded" do
      scope = full_scope_fixture()

      {:ok, _reply, socket} =
        socket(UserSocket, "harness_test", %{scope: scope})
        |> subscribe_and_join(
          HarnessProjectChannel,
          "harness_project:#{scope.active_project_id}",
          %{
            "label" => @label,
            "root" => scope.cwd,
            "harness_id" => scope.active_working_copy_id,
            "device" => %{"id" => device_fixture(scope).id},
            "app_verbs" => ["reload_app"]
          }
        )

      Process.put(:app_test_scope, scope)
      {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)
      {:ok, copy} = WorkingCopies.report_root(copy, scope.cwd)
      {:ok, _instance} = AppInstances.ensure_default(scope, copy)
      task = call_async(socket.channel_pid, {:reload_app, %{}})

      assert %{"ref" => ref} = await_push("reload_app")

      answer(socket, "reload_app_result", ref, %{
        "status" => "ok",
        "app_status" => "serving",
        "app_commit" => "launch0",
        "app_serving_commit" => "reload1",
        "app_action" => "reloaded"
      })

      assert {:ok, %{serving_commit: "reload1", commit: "launch0", action: "reloaded"}} =
               Task.await(task)

      instance = AppInstances.for_working_copy(scope, scope.active_working_copy_id)
      assert instance.commit == "launch0"
      assert instance.serving_commit == "reload1"
    end
  end

  describe "stop_app" do
    test "answers :ok with no status payload to decode", %{socket: socket} do
      task = call_async(socket.channel_pid, {:stop_app, %{}})

      assert %{"ref" => ref} = await_push("stop_app")
      answer(socket, "stop_app_result", ref, %{"status" => "ok"})

      assert Task.await(task) == :ok
    end
  end

  describe "discard_app" do
    test "acknowledges disposal against the requested instance", %{socket: socket} do
      task = call_async(socket.channel_pid, {:discard_app, %{}})
      assert %{"ref" => ref, "instance" => %{"instance_id" => id}} = await_push("discard_app")
      answer(socket, "discard_app_result", ref, %{"status" => "ok", "instance_id" => id})
      assert Task.await(task) == :ok
    end

    test "cleanup failure propagates to its caller", %{socket: socket} do
      task = call_async(socket.channel_pid, {:discard_app, %{}})
      assert %{"ref" => ref} = await_push("discard_app")

      answer(socket, "discard_app_result", ref, %{
        "status" => "error",
        "reason" => "database_busy"
      })

      assert Task.await(task) == {:error, "database_busy"}
    end
  end

  describe "instance identity" do
    test "a reply cannot update a different instance", %{socket: socket, scope: scope} do
      target = AppInstances.for_working_copy(scope, scope.active_working_copy_id)
      secondary = secondary_instance(scope)
      task = call_async(socket.channel_pid, {:ensure_app_running, %{}})

      assert %{"ref" => ref, "instance" => %{"instance_id" => id}} =
               await_push("ensure_app_running")

      assert id == target.id

      answer(socket, "ensure_app_running_result", ref, %{
        "instance_id" => secondary.id,
        "status" => "ok",
        "app_status" => "serving",
        "app_commit" => "wrong-instance"
      })

      assert Task.await(task) == {:error, :instance_source_mismatch}
      assert AppInstances.get(scope, target.id).commit == nil
      assert AppInstances.get(scope, secondary.id).commit == nil
    end

    test "unknown result references do not write status", %{socket: socket, scope: scope} do
      instance = AppInstances.for_working_copy(scope, scope.active_working_copy_id)

      ref =
        push(socket, "ensure_app_running_result", %{
          "ref" => "unrequested",
          "instance_id" => instance.id,
          "status" => "ok",
          "app_status" => "serving",
          "app_commit" => "unrequested"
        })

      assert %Phoenix.Socket.Reply{status: :error} = await_reply(ref)
      assert AppInstances.get(scope, instance.id).commit == nil
    end

    test "descriptor roots are checked against the stored source", %{socket: socket, scope: scope} do
      instance = AppInstances.for_working_copy(scope, scope.active_working_copy_id)

      descriptor =
        instance |> AppInstances.descriptor() |> Map.put("root", "/tmp/unrelated-source")

      task = call_async(socket.channel_pid, {:restart_app, %{instance: descriptor}})
      assert Task.await(task) == {:error, :instance_source_mismatch}
      refute_push("restart_app", _)
    end

    test "background status writes only the named instance", %{socket: socket, scope: scope} do
      default = AppInstances.for_working_copy(scope, scope.active_working_copy_id)
      secondary = secondary_instance(scope)

      ref =
        push(socket, "app_status", %{
          "instance_id" => secondary.id,
          "status" => "serving",
          "commit" => "secondary-head",
          "serving_commit" => "secondary-reload"
        })

      assert %Phoenix.Socket.Reply{status: :ok} = await_reply(ref)
      assert AppInstances.get(scope, secondary.id).serving_commit == "secondary-reload"
      assert AppInstances.get(scope, default.id).commit == nil
    end

    test "join reports retain their own instance identities", %{scope: scope, socket: current} do
      secondary = secondary_instance(scope)
      {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)
      Process.unlink(current.channel_pid)
      monitor = Process.monitor(current.channel_pid)
      Phoenix.ChannelTest.leave(current)
      assert_receive {:DOWN, ^monitor, :process, _, _}, 2_000

      assert {:ok, _, _} =
               socket(UserSocket, "harness_rejoin", %{scope: scope})
               |> subscribe_and_join(
                 HarnessProjectChannel,
                 "harness_project:#{scope.active_project_id}",
                 %{
                   "harness_id" => copy.id,
                   "root" => copy.root,
                   "device" => %{"id" => copy.device_id},
                   "app_instances" => [
                     %{
                       "instance_id" => secondary.id,
                       "status" => "serving",
                       "commit" => "recovered"
                     }
                   ]
                 }
               )

      assert AppInstances.get(scope, secondary.id).commit == "recovered"
    end
  end

  defp secondary_instance(scope) do
    {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)

    {:ok, instance} =
      AppInstances.create(scope, %{
        project_id: copy.project_id,
        working_copy_id: copy.id,
        device_id: copy.device_id,
        source_root: copy.root,
        default: false,
        persistent: false,
        port_mode: :allocated,
        database_mode: :clone,
        database_source: "test_dev",
        after_promote: false
      })

    instance
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

      for {verb, event} <- [
            {:ensure_app_running, "ensure_app_running"},
            {:restart_app, "restart_app"}
          ] do
        task = call_async(socket.channel_pid, {verb, %{}})

        assert %{"ref" => ref, "instance" => %{"persistent" => true}, "tunnel" => tunnel} =
                 await_push(event)

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

      assert %{"instance" => %{"persistent" => true}} = payload = await_push("ensure_app_running")
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
      {:ok, main} = WorkingCopies.fetch(scope.active_working_copy_id)
      {:ok, _main} = WorkingCopies.report_root(main, scope.cwd)

      {:ok, worktree} =
        WorkingCopies.issue(scope, nil, label: "worktree", device: device_fixture(scope))

      {:ok, worktree} = WorkingCopies.report_root(worktree, "/tmp/put_tunnel_worktree")

      {:ok, _instance} =
        WorkingCopies.record_app_status(worktree, %{
          status: "serving",
          url: "http://127.0.0.1:41234"
        })

      {:ok, _instance} =
        WorkingCopies.record_preview_tunnel(worktree, %{
          preview_url: PreviewAddress.url(worktree.id),
          preview_tunnel_id: "tunnel-1",
          preview_tunnel_secret: "s3cret"
        })

      refute worktree.main

      {:ok, _reply, socket} = join_as(%{scope | active_working_copy_id: worktree.id})

      task = call_async(socket.channel_pid, {:ensure_app_running, %{}})

      assert %{"instance" => %{"persistent" => false}} =
               payload = await_push("ensure_app_running")

      refute Map.has_key?(payload, "tunnel")

      answer(socket, "ensure_app_running_result", payload["ref"], %{
        "status" => "ok",
        "app_status" => "serving"
      })

      Task.await(task)
    end
  end
end
