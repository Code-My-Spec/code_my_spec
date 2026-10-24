defmodule CodeMySpecSpex.Story1108.Criterion4663Spex do
  @moduledoc """
  Promotion reloads or restarts its selected AppInstance through the source
  checkout's authenticated harness channel. The descriptor carries the
  instance identity and explicit policies; successful replies report the
  revision now serving. Hook execution follows the after_promote policy.
  """

  use CodeMySpecSpex.Case

  import Phoenix.ChannelTest
  import CodeMySpecSpex.DeviceHelpers
  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner
  alias CodeMySpec.Promotion.Runner
  alias CodeMySpec.AppInstances
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Promotion's reload goes to main's harness on the channel every copy's app uses",
    criterion: 1539 do
    scenario "the project's designated main copy, its harness able to reload" do
      given_ "this copy is the project's designated main, its harness declaring reload_app",
             context do
        {:ok, main_copy} =
          WorkingCopies.designate_main(context.scope, context.scope.active_working_copy_id)

        {:ok, _reply, socket} = join_harness_project(context, ["reload_app"])

        {:ok,
         context
         |> Map.put(:socket, socket)
         |> Map.put(:main_copy, main_copy)
         |> Map.put(:main_instance, promotion_instance(context.scope, main_copy))}
      end

      when_ "promotion reloads this working copy's app", context do
        task =
          Task.async(fn ->
            Runner.reload(
              context.scope,
              context.main_instance.source_root,
              context.main_instance.id
            )
          end)

        {:ok, Map.put(context, :task, task)}
      end

      then_ "the harness is asked to reload, told this is main, and the reply reports the commit now serving",
            context do
        assert_push("reload_app", %{
          "ref" => ref,
          "instance" => %{"instance_id" => instance_id, "after_promote" => true}
        })

        assert instance_id == context.main_instance.id

        reply(context.socket, "reload_app_result", %{
          "ref" => ref,
          "instance_id" => instance_id,
          "status" => "ok",
          "app_status" => "serving",
          "app_url" => "http://127.0.0.1:4000",
          "app_commit" => "cafef00d",
          "app_serving_commit" => "beadfeed"
        })

        assert {:ok, %{revision: "beadfeed"}} = Task.await(context.task)
        {:ok, context}
      end
    end
  end

  spex "A reload runs main's after-promote hook once",
    criterion: 1539 do
    scenario "a running app whose project declares reload and after-promote recipes" do
      given_ "a running working copy whose project declares reload and after-promote recipes",
             context do
        rig =
          app_instance_rig(
            current_commit: "cafef00d",
            recipe: %{"after-promote" => true, "reload" => true}
          )

        assert %{"status" => "ok"} = push_app_event_as_main("ensure_app_running")
        {:ok, Map.merge(context, rig)}
      end

      when_ "the server asks this copy, marked main, to reload", context do
        {:ok, Map.put(context, :main_result, push_app_event_as_main("reload_app"))}
      end

      then_ "it reloaded in place and ran after-promote once", context do
        assert %{"status" => "ok", "app_action" => "reloaded"} = context.main_result
        sync_after_reply(context.root)

        assert Enum.count(FakeAppInstanceRunner.calls(), &match?({:reload, _}, &1)) == 1

        assert Enum.count(FakeAppInstanceRunner.calls(), &match?({:run_after_promote, _}, &1)) ==
                 1

        {:ok, context}
      end

      when_ "the server asks the same copy to reload again, not marked main", context do
        {:ok, Map.put(context, :ordinary_result, push_without_hook(context.root, "reload_app"))}
      end

      then_ "it reloads without running after-promote again", context do
        assert %{"status" => "ok", "app_action" => "reloaded"} = context.ordinary_result
        sync_after_reply(context.root)

        assert Enum.count(FakeAppInstanceRunner.calls(), &match?({:run_after_promote, _}, &1)) ==
                 1

        {:ok, context}
      end
    end
  end

  spex "A copy with no reload recipe restarts when asked to reload", criterion: 1539 do
    scenario "a running app whose project has no reload recipe" do
      given_ "a running working copy with no reload recipe", context do
        rig = app_instance_rig(current_commit: "cafef00d", recipe: %{"reload" => false})
        assert %{"status" => "ok"} = push_app_event("restart_app")
        {:ok, Map.merge(context, rig)}
      end

      when_ "the server asks it to reload", context do
        {:ok, Map.put(context, :result, push_app_event("reload_app"))}
      end

      then_ "it restarts instead, and says why", context do
        assert %{"status" => "ok", "app_action" => "restarted", "app_action_reason" => reason} =
                 context.result

        assert reason =~ "reload"
        refute Enum.any?(FakeAppInstanceRunner.calls(), &match?({:reload, _}, &1))
        {:ok, context}
      end
    end
  end

  spex "Promotion's restart step goes through the same channel verb every copy's app uses",
    criterion: 1539 do
    scenario "the project's designated main copy" do
      given_ "this copy is the project's designated main, harness connected", context do
        {:ok, main_copy} =
          WorkingCopies.designate_main(context.scope, context.scope.active_working_copy_id)

        {:ok, _reply, socket} = join_harness_project(context)

        {:ok,
         context
         |> Map.put(:socket, socket)
         |> Map.put(:main_copy, main_copy)
         |> Map.put(:main_instance, promotion_instance(context.scope, main_copy))}
      end

      when_ "promotion restarts this working copy's app", context do
        task =
          Task.async(fn ->
            Runner.restart(
              context.scope,
              context.main_instance.source_root,
              context.main_instance.id
            )
          end)

        {:ok, Map.put(context, :task, task)}
      end

      then_ "the harness is asked to restart, told this is main, and the reply reports the commit now serving",
            context do
        assert_push("restart_app", %{
          "ref" => ref,
          "instance" => %{"instance_id" => instance_id, "after_promote" => true}
        })

        assert instance_id == context.main_instance.id

        reply(context.socket, "restart_app_result", %{
          "ref" => ref,
          "instance_id" => instance_id,
          "status" => "ok",
          "app_status" => "serving",
          "app_url" => "http://127.0.0.1:4000",
          "app_commit" => "cafef00d"
        })

        assert {:ok, %{revision: "cafef00d"}} = Task.await(context.task)

        {:ok, context}
      end
    end

    scenario "a project that declares an after-promote recipe" do
      given_ "a working copy whose project declares an after-promote recipe", context do
        rig =
          app_instance_rig(
            current_commit: "cafef00d",
            recipe: %{"after-promote" => true}
          )

        {:ok, Map.merge(context, rig)}
      end

      when_ "the server asks this copy, marked main, to restart", context do
        {:ok, Map.put(context, :main_result, push_app_event_as_main("restart_app"))}
      end

      then_ "the restart reports the commit now serving", context do
        assert %{"status" => "ok", "app_status" => "serving", "app_commit" => "cafef00d"} =
                 context.main_result

        {:ok, context}
      end

      then_ "the after-promote recipe was actually run, not skipped", context do
        # A barrier on the reply-then-hook ordering `AppInstanceHelpers.
        # sync_after_reply/1` documents — not a read of AppInstance's state,
        # which this assertion must not depend on. Flaky without it under
        # load: caught as ~1-in-3 across repeated full-suite runs, unrelated
        # to any of this session's own changes (git blame on this file:
        # 9192ad367, well before today).
        sync_after_reply(context.root)

        assert Enum.count(FakeAppInstanceRunner.calls(), &match?({:run_after_promote, _}, &1)) ==
                 1,
               "a successful restart with the recipe declared should still have run it"

        {:ok, context}
      end

      when_ "the server later asks the same copy to restart again, this time not marked main",
            context do
        {:ok, Map.put(context, :ordinary_result, push_without_hook(context.root, "restart_app"))}
      end

      then_ "that restart still reports success", context do
        assert %{"status" => "ok", "app_status" => "serving"} = context.ordinary_result
        {:ok, context}
      end

      then_ "the after-promote recipe was not run a second time — a promote is main's alone",
            context do
        assert Enum.count(FakeAppInstanceRunner.calls(), &match?({:run_after_promote, _}, &1)) ==
                 1,
               "the recipe lives in the shared justfile every working copy's checkout has; " <>
                 "running it for an ordinary copy's own restart would bounce the one shared " <>
                 "harness on every agent's commit, not just a promote"

        {:ok, context}
      end

      when_ "the server asks this copy, marked main, to restart while its own port is still held by an untracked process — the first restart ever run against a checkout whose dev server predates story 1108",
            context do
        FakeAppInstanceRunner.configure(listener_pid: 99_999, process_root: context.root)
        {:ok, Map.put(context, :adopt_result, push_app_event_as_main("restart_app"))}
      end

      then_ "the restart still succeeds — the old process is adopted (killed), not left holding the port next to the new one",
            context do
        assert %{"status" => "ok", "app_status" => "serving"} = context.adopt_result

        assert Enum.any?(FakeAppInstanceRunner.calls(), &match?({:stop_process, [99_999]}, &1)),
               "an untracked listener, once its own cwd is confirmed to be this checkout's " <>
                 "root, has to be killed before serve runs next to it"

        {:ok, context}
      end

      when_ "the server asks the same copy to restart again while its port is held by a process that turns out not to be this checkout at all",
            context do
        FakeAppInstanceRunner.configure(
          listener_pid: 88_888,
          process_root: "/some/other/checkout"
        )

        {:ok, Map.put(context, :refuse_result, push_app_event_as_main("restart_app"))}
      end

      then_ "the restart is refused loudly instead of killing a stranger's process on the strength of the port number alone",
            context do
        assert %{"status" => "error", "reason" => reason} = context.refuse_result
        assert reason =~ "port_held_by_untracked_process"

        refute Enum.any?(FakeAppInstanceRunner.calls(), &match?({:stop_process, [88_888]}, &1)),
               "a listener whose cwd doesn't match this checkout is never killed, whatever " <>
                 "it's doing on the port"

        {:ok, context}
      end
    end
  end

  defp join_harness_project(context, app_verbs \\ []) do
    scope = context.scope

    socket(UserSocket, "harness_test", %{scope: scope})
    |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{scope.active_project_id}", %{
      "label" => "the harness at /workspace/app",
      "root" => scope.cwd || "/workspace/app",
      "harness_id" => scope.active_working_copy_id,
      "device" => %{"id" => device_id(context)},
      "app_verbs" => app_verbs
    })
  end

  defp promotion_instance(scope, copy) do
    instance = AppInstances.for_working_copy(scope, copy.id)

    {:ok, instance} =
      AppInstances.update(scope, instance, %{
        persistent: true,
        after_promote: true,
        port_mode: :configured,
        database_mode: :configured
      })

    instance
  end

  defp push_without_hook(root, event) do
    descriptor =
      Map.merge(instance(root), %{
        "persistent" => true,
        "port_mode" => "configured",
        "database_mode" => "configured",
        "after_promote" => false
      })

    push_app_event_with(event, %{"instance" => descriptor})
  end

  defp reply(socket, event, payload) do
    ref = Phoenix.ChannelTest.push(socket, event, payload)

    receive do
      %Phoenix.Socket.Reply{ref: ^ref, status: :ok} -> :ok
    after
      1_000 -> flunk("#{event} was never acknowledged")
    end
  end
end
