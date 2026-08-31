defmodule CmsHarness.SyncPathTest do
  @moduledoc """
  The whole path, over a real websocket: join, take the read model, scan the
  disk, send the manifest.

  The far side is `CmsHarnessTest.FakeServer` — the server's wire contract and
  nothing else — but the near side is the harness's actual Slipstream client,
  its actual watcher and its actual scan. The connection genuinely exists and
  can genuinely be cut, which is what the disconnection tests need.
  """

  # Sync, because the thing under test registers globally.
  #
  # `Projects.ensure_started/1` puts the project in `CmsHarness.Registry`, which
  # is one registry for the node, and the assertions here are `assert_receive
  # {:joined, project_id, _}`. Run async, a second test's join arrives first and
  # the id does not match — which is what happened when this was flipped:
  # `assert project_id == project.id` failed in the suite while passing alone.
  #
  # Not a sandbox or filesystem problem, so none of the usual remedies apply.
  # The registry is process-global by design; the only isolation available is
  # not running two of these at once.
  use ExUnit.Case, async: false

  import CmsHarnessTest.Projects

  alias CmsHarness.Project.{ChannelClient, Watcher}
  alias CmsHarness.Projects
  alias CmsHarnessTest.FakeServer

  setup do
    previous = System.get_env("CMS_PROJECT_ID")
    System.delete_env("CMS_PROJECT_ID")
    on_exit(fn -> restore_project_id(previous) end)

    project = project_dir()
    write(project.root, "lib/demo/accounts.ex", "defmodule Demo.Accounts do\nend\n")
    write(project.root, "test/demo/accounts_test.exs", "defmodule Demo.AccountsTest do\nend\n")

    on_exit(fn -> stop_project(project.root) end)

    %{project: project}
  end

  # Nothing was configured before this suite and something was are two cases,
  # not a condition — same shape the transport test uses.
  defp restore_project_id(nil), do: :ok
  defp restore_project_id(value), do: System.put_env("CMS_PROJECT_ID", value)

  defp await_connected(root, attempts \\ 100) do
    eventually(fn -> ChannelClient.connected?(root) end, attempts)
  end

  defp eventually(fun, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _, _ -> poll(fun.()) end)
  end

  defp poll(true), do: {:halt, true}

  defp poll(_) do
    Process.sleep(50)
    {:cont, false}
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
      assert await_connected(project.root)
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

    # A server-side deploy-readiness check has no real way to read this
    # project's `mix.exs` at all — see `CodeMySpec.Provisioning.
    # Steps.app_path/1` — so this machine, which can, reports the real app
    # name on every sync rather than waiting on a separate onboarding step
    # to have asked for it correctly.
    test "mix.exs's own app name is reported alongside the manifest", %{project: project} do
      write(
        project.root,
        "mix.exs",
        """
        defmodule Demo.MixProject do
          use Mix.Project
          def project, do: [app: :demo, version: "0.1.0"]
        end
        """
      )

      FakeServer.start()
      {:ok, _} = Projects.ensure_started(project.root)

      assert_receive {:module_name, project_id, "Demo"}, 5_000
      assert project_id == project.id
    end

    # The same reachability gap, on a check with no Files-table fallback at
    # all — `Generators.health_route_finding/3` has nothing to read server-side
    # for a harness-only project, so this machine runs the real content check
    # (`DeployBoilerplate.health_route_unpiped/2`) where the files actually
    # are and reports the verdict.
    test "a real health route is checked and reported alongside the manifest", %{
      project: project
    } do
      write(
        project.root,
        "mix.exs",
        """
        defmodule Demo.MixProject do
          use Mix.Project
          def project, do: [app: :demo, version: "0.1.0"]
        end
        """
      )

      write(project.root, "lib/demo_web/router.ex", """
      defmodule DemoWeb.Router do
        use DemoWeb, :router

        scope "/", DemoWeb do
          get "/health", HealthController, :show
        end
      end
      """)

      FakeServer.start()
      {:ok, _} = Projects.ensure_started(project.root)

      assert_receive {:health_route_status, project_id, "ok"}, 5_000
      assert project_id == project.id
    end

    test "a project another harness holds is not served", %{project: project} do
      FakeServer.start(refuse: "the harness at /elsewhere")

      {:ok, _} = Projects.ensure_started(project.root)

      assert_receive {:join_refused, _}, 5_000

      refute await_connected(project.root, 10)
      refute Watcher.watching?(project.root)

      # It does come back round, a bounded number of times. This used to assert
      # the opposite — one refusal and done — on the reasoning that a retry is
      # just the same collision again. That reasoning missed the commonest
      # holder of all: the server node this one is replacing, which lets go
      # within seconds of a restart. Where the retries stop is asserted in
      # `ChannelClientTransportTest`, which can do it without spending the
      # backoff in real time.
      assert_receive {:join_refused, _},
                     5_000,
                     "a refusal during a server handover has to heal itself"
    end
  end

  describe "the watcher follows the connection" do
    test "it watches once the channel is joined", %{project: project} do
      FakeServer.start()
      {:ok, _} = Projects.ensure_started(project.root)

      assert await_connected(project.root)
      assert eventually(fn -> Watcher.watching?(project.root) end)
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
      assert eventually(fn -> Watcher.watching?(project.root) end)

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
          observations
          |> Enum.any?(&(&1["path"] == path))
          |> manifest_or_retry(observations, project, path, timeout)
      after
        timeout ->
          flunk("no manifest mentioning #{path} arrived within #{timeout}ms")
      end
    end

    defp manifest_or_retry(true, observations, _project, _path, _timeout), do: observations

    defp manifest_or_retry(false, _observations, project, path, timeout),
      do: await_manifest_with(project, path, timeout)

    # The property: events it cannot deliver are events it will not remember, so
    # it stops rather than building a backlog whose loss is invisible.
    test "it stops watching the moment the connection goes", %{project: project} do
      server = FakeServer.start()
      {:ok, _} = Projects.ensure_started(project.root)

      assert await_connected(project.root)
      assert eventually(fn -> Watcher.watching?(project.root) end)

      FakeServer.disconnect_everyone(server)

      assert eventually(fn -> not ChannelClient.connected?(project.root) end),
             "the client has to notice the connection went"

      assert eventually(fn -> not Watcher.watching?(project.root) end),
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

      assert await_connected(project.root)
      assert_receive {:observations, _, _}, 5_000

      FakeServer.disconnect_everyone(server)
      assert eventually(fn -> not ChannelClient.connected?(project.root) end)

      # Changed while nobody was watching.
      write(project.root, "lib/demo/invoices.ex", "defmodule Demo.Invoices do\nend\n")

      FakeServer.start()

      assert eventually(fn -> ChannelClient.connected?(project.root) end, 200)
      assert_receive {:observations, _, observations}, 10_000

      assert "lib/demo/invoices.ex" in Enum.map(observations, & &1["path"]),
             "a change made during the outage has to be in the manifest that follows it"

      assert eventually(fn -> Watcher.watching?(project.root) end)
    end
  end

  describe "hook decisions" do
    test "a joined channel passes the server's answer straight through", %{project: project} do
      FakeServer.start(hook_decision: %{"decision" => "block", "reason" => "finish task 7"})
      {:ok, _} = Projects.ensure_started(project.root)
      assert await_connected(project.root)

      assert {:ok, %{"decision" => "block", "reason" => "finish task 7"}} =
               ChannelClient.decide_hook(project.root, "stop", %{})
    end

    test "an answer that never comes is an error, never an allow", %{project: project} do
      FakeServer.start(hook_decision: :no_answer)
      {:ok, _} = Projects.ensure_started(project.root)
      assert await_connected(project.root)

      assert {:error, :no_reply} = ChannelClient.decide_hook(project.root, "stop", %{})
    end

    test "with no channel at all it is not_connected, which reads differently", %{
      project: project
    } do
      assert {:error, :not_connected} = ChannelClient.decide_hook(project.root, "stop", %{})
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

      ChannelClient.deliver_observations(project.root, [])

      refute_receive {:observations, _, []}, 500
    end
  end
end
