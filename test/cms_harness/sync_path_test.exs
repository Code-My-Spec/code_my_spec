defmodule CmsHarness.SyncPathTest do
  @moduledoc """
  The whole path, over a real websocket: join, take the read model, scan the
  disk, send the manifest.

  The far side is `CmsHarnessTest.FakeServer` — the server's wire contract and
  nothing else — but the near side is the harness's actual Slipstream client,
  its actual watcher and its actual scan. The connection genuinely exists and
  can genuinely be cut, which is what the disconnection tests need.
  """

  use ExUnit.Case, async: false

  import CmsHarnessTest.Projects

  alias CmsHarness.Project.{ChannelClient, Watcher}
  alias CmsHarness.Projects
  alias CmsHarnessTest.FakeServer

  setup do
    previous = System.get_env("CMS_PROJECT_ID")
    System.delete_env("CMS_PROJECT_ID")
    on_exit(fn -> if previous, do: System.put_env("CMS_PROJECT_ID", previous) end)

    project = project_dir()
    write(project.root, "lib/demo/accounts.ex", "defmodule Demo.Accounts do\nend\n")
    write(project.root, "test/demo/accounts_test.exs", "defmodule Demo.AccountsTest do\nend\n")

    on_exit(fn -> stop_project(project.id) end)

    %{project: project}
  end

  defp await_connected(project_id, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if ChannelClient.connected?(project_id) do
        {:halt, true}
      else
        Process.sleep(50)
        {:cont, false}
      end
    end)
  end

  defp eventually(fun, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(50)
        {:cont, false}
      end
    end)
  end

  describe "joining" do
    test "the harness joins its project's topic and takes the read model", %{project: project} do
      FakeServer.start()

      {:ok, _} = Projects.ensure_started(project.root)

      assert_receive {:joined, project_id, payload}, 5_000
      assert project_id == project.id

      assert payload["label"] =~ project.root,
             "a refusal has to be able to name the checkout to go and stop"

      assert_receive {:read_model_requested, _}, 5_000
      assert await_connected(project.id)
    end

    test "the manifest that follows carries conclusions, not content", %{project: project} do
      FakeServer.start()
      {:ok, _} = Projects.ensure_started(project.root)

      assert_receive {:observations, _project_id, observations}, 5_000

      by_path = Map.new(observations, &{&1["path"], &1})

      accounts = by_path["lib/demo/accounts.ex"]
      assert accounts["role"] == "implementation"
      assert accounts["fingerprint"] != nil
      assert accounts["mtime"] != nil
      assert accounts["valid"] == true

      assert accounts["component_id"] == "component-1",
             "the read model, not a query, is what resolves the owner"

      refute Enum.any?(Map.keys(accounts), &(&1 == "content"))
    end

    test "a project another harness holds is refused, and this one stops rather than waiting",
         %{project: project} do
      FakeServer.start(refuse: "the harness at /elsewhere")

      {:ok, _} = Projects.ensure_started(project.root)

      assert_receive {:join_refused, _}, 5_000

      refute await_connected(project.id, 10)
      refute Watcher.watching?(project.id)

      # And it does not come back round. Retrying is the same collision once a
      # second, and it would fill the log with the wrong problem.
      refute_receive {:join_refused, _}, 3_000
    end
  end

  describe "the watcher follows the connection" do
    test "it watches once the channel is joined", %{project: project} do
      FakeServer.start()
      {:ok, _} = Projects.ensure_started(project.root)

      assert await_connected(project.id)
      assert eventually(fn -> Watcher.watching?(project.id) end)
    end

    # A manifest the server refused must not read like one it accepted.
    #
    # This was real: the observations push was fire-and-forget, so the server's
    # reply landed in the generic handle_reply with nothing waiting for it, was
    # logged at debug as "unmatched reply", and dropped. A rejected sync and a
    # successful one were indistinguishable from inside the harness — on the one
    # path where being wrong is least visible.
    test "a rejected manifest is reported loudly, not swallowed", %{project: project} do
      import ExUnit.CaptureLog

      FakeServer.start()
      FakeServer.reject_observations("invalid_manifest")

      log =
        capture_log(fn ->
          {:ok, _} = Projects.ensure_started(project.root)
          assert_receive {:observations, _, _}, 5_000
          Process.sleep(500)
        end)

      assert log =~ "REJECTED",
             "a refused sync has to be an error in the log, not a debug line nobody reads"

      assert log =~ "out of step with the disk",
             "the message has to say what it means for the project, not just echo a reason code"
    end

    test "a file change produces a fresh manifest", %{project: project} do
      FakeServer.start()
      {:ok, _} = Projects.ensure_started(project.root)

      assert_receive {:observations, _, first}, 5_000
      assert eventually(fn -> Watcher.watching?(project.id) end)

      # `watching?` goes true when `FileSystem.start_link/1` returns, but the
      # OS-level stream takes a moment longer to establish. In production the
      # gap is covered by the full sync that runs on join; here it just has to
      # be waited out, or the write races the subscription.
      Process.sleep(1_000)

      write(project.root, "lib/demo/billing.ex", "defmodule Demo.Billing do\nend\n")

      # Wait for a manifest *containing the new file*, not merely for the next
      # one. A reconnect triggers its own full rescan, so the next manifest to
      # arrive is not necessarily the one caused by this write — and asserting
      # on arrival order rather than on content made this fail about one run in
      # five, which reads as "the sync dropped my change" when nothing did.
      second = await_manifest_with(project, "lib/demo/billing.ex")

      assert length(second) == length(first) + 1,
             "the manifest is the whole set, not a delta — that is what lets the " <>
               "server tell a deletion from an omission"
    end

    # Drains manifests until one mentions `path`, so an unrelated rescan cannot
    # be mistaken for the answer.
    defp await_manifest_with(project, path, timeout \\ 10_000) do
      receive do
        {:observations, _, observations} ->
          if path in Enum.map(observations, & &1["path"]) do
            observations
          else
            await_manifest_with(project, path, timeout)
          end
      after
        timeout ->
          flunk("no manifest mentioning #{path} arrived within #{timeout}ms")
      end
    end

    # The property: events it cannot deliver are events it will not remember, so
    # it stops rather than building a backlog whose loss is invisible.
    test "it stops watching the moment the connection goes", %{project: project} do
      server = FakeServer.start()
      {:ok, _} = Projects.ensure_started(project.root)

      assert await_connected(project.id)
      assert eventually(fn -> Watcher.watching?(project.id) end)

      FakeServer.disconnect_everyone(server)

      assert eventually(fn -> not ChannelClient.connected?(project.id) end),
             "the client has to notice the connection went"

      assert eventually(fn -> not Watcher.watching?(project.id) end),
             "a watcher that keeps running while disconnected accumulates events " <>
               "it will silently drop"
    end

    # What makes stopping safe. The manifest is a statement about the working
    # copy *now*, so the events missed while the connection was down do not have
    # to be replayed — a full rescan on rejoin says everything they would have.
    test "reconnecting rescans, so the gap does not have to be remembered",
         %{project: project} do
      server = FakeServer.start()
      {:ok, _} = Projects.ensure_started(project.root)

      assert await_connected(project.id)
      assert_receive {:observations, _, _}, 5_000

      FakeServer.disconnect_everyone(server)
      assert eventually(fn -> not ChannelClient.connected?(project.id) end)

      # Changed while nobody was watching.
      write(project.root, "lib/demo/invoices.ex", "defmodule Demo.Invoices do\nend\n")

      FakeServer.start()

      assert eventually(fn -> ChannelClient.connected?(project.id) end, 200)
      assert_receive {:observations, _, observations}, 10_000

      assert "lib/demo/invoices.ex" in Enum.map(observations, & &1["path"]),
             "a change made during the outage has to be in the manifest that follows it"

      assert eventually(fn -> Watcher.watching?(project.id) end)
    end
  end

  describe "hook decisions" do
    test "a joined channel passes the server's answer straight through", %{project: project} do
      FakeServer.start(hook_decision: %{"decision" => "block", "reason" => "finish task 7"})
      {:ok, _} = Projects.ensure_started(project.root)
      assert await_connected(project.id)

      assert {:ok, %{"decision" => "block", "reason" => "finish task 7"}} =
               ChannelClient.decide_hook(project.id, "stop", %{})
    end

    test "an answer that never comes is an error, never an allow", %{project: project} do
      FakeServer.start(hook_decision: :no_answer)
      {:ok, _} = Projects.ensure_started(project.root)
      assert await_connected(project.id)

      assert {:error, :no_reply} = ChannelClient.decide_hook(project.id, "stop", %{})
    end

    test "with no channel at all it is not_connected, which reads differently", %{
      project: project
    } do
      assert {:error, :not_connected} = ChannelClient.decide_hook(project.id, "stop", %{})
    end
  end

  describe "the empty manifest" do
    # `reconcile/2` deletes every row whose path is absent, so an empty list
    # wipes the project — and over a wire "found nothing" and "did not run"
    # arrive identically. The server refuses one; the harness must not send one.
    test "a scan that found nothing is not sent", %{project: project} do
      FakeServer.start()
      {:ok, _} = Projects.ensure_started(project.root)
      assert_receive {:observations, _, _}, 5_000

      ChannelClient.deliver_observations(project.id, [])

      refute_receive {:observations, _, []}, 500
    end
  end
end
