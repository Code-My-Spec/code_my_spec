defmodule CodeMySpecSpex.Story1108.Criterion4663Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4663 — A promote restarts main's app through restart.

  Rule: Main's dev app runs under the same start, restart and stop, and a
  promote restarts it.

  `Promotion.Runner.restart/3` used to shell `just restart` directly,
  through `Steps.restart/2`. It now calls
  `WorkingCopies.AppTransport.restart_app/2` — the same channel verb every
  other working copy's own `restart_app` MCP tool already uses — so a
  promotion's restart is the *same* mechanism every copy's app already
  answers to, not a second, main-only path to the same machine. Proven
  concretely: main's own harness receives the same `restart_app` push,
  tagged `main: true` the way `HarnessProjectChannel.put_main/2` already
  tags it for every other app verb, and a successful reply is read back as
  the revision now serving.

  A second scenario covers this repo's own optional after-promote hook
  (`AppInstance.after_promote/1`): it runs only when the restart is main's —
  the recipe lives in the shared justfile every working copy's checkout has,
  so running it for an ordinary copy's own "HEAD moved" restart would bounce
  the one shared harness on every agent's commit, not just a promote. Its
  own failure, and why that can only be logged rather than replied, is
  proven separately in `test/cms_harness/app_instance_test.exs` — asserting
  it here would trip this project's spex-wide "no error-level log during a
  spex" rule (`SexySpex.ErrorCapture`) on a failure this scenario means to
  provoke on purpose, not one it means to catch by surprise.

  The same scenario also covers main's port already being held by an
  untracked process — the first unified restart ever run against a checkout
  whose dev server predates story 1108, or was ever started by hand.
  `running?/1` only tracks a *persisted* `os_pid`, so that old process would
  otherwise sit on the port forever. It's adopted (killed) once its own cwd
  is confirmed to be this checkout's root, and the restart is refused
  loudly, not killed, when it isn't.
  """

  use CodeMySpecSpex.Case

  import Phoenix.ChannelTest
  import CodeMySpecSpex.DeviceHelpers
  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner
  alias CodeMySpec.Promotion.Runner
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Promotion's restart step goes through the same channel verb every copy's app uses", criterion: 1539 do
    scenario "the project's designated main copy" do
      given_ "this copy is the project's designated main, harness connected", context do
        {:ok, main_copy} = WorkingCopies.designate_main(context.scope, context.scope.active_working_copy_id)

        {:ok, _reply, socket} = join_harness_project(context)

        {:ok, context |> Map.put(:socket, socket) |> Map.put(:main_copy, main_copy)}
      end

      when_ "promotion restarts this working copy's app", context do
        task =
          Task.async(fn ->
            Runner.restart(context.scope, context.main_copy.root, context.main_copy.id)
          end)

        {:ok, Map.put(context, :task, task)}
      end

      then_ "the harness is asked to restart, told this is main, and the reply reports the commit now serving",
            context do
        assert_push "restart_app", %{"ref" => ref, "main" => true}

        reply(context.socket, "restart_app_result", %{
          "ref" => ref,
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
        assert Enum.count(FakeAppInstanceRunner.calls(), &match?({:run_after_promote, _}, &1)) == 1,
               "a successful restart with the recipe declared should still have run it"

        {:ok, context}
      end

      when_ "the server later asks the same copy to restart again, this time not marked main",
            context do
        {:ok, Map.put(context, :ordinary_result, push_app_event("restart_app"))}
      end

      then_ "that restart still reports success", context do
        assert %{"status" => "ok", "app_status" => "serving"} = context.ordinary_result
        {:ok, context}
      end

      then_ "the after-promote recipe was not run a second time — a promote is main's alone",
            context do
        assert Enum.count(FakeAppInstanceRunner.calls(), &match?({:run_after_promote, _}, &1)) == 1,
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
        FakeAppInstanceRunner.configure(listener_pid: 88_888, process_root: "/some/other/checkout")
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

  defp join_harness_project(context) do
    scope = context.scope

    socket(UserSocket, "harness_test", %{scope: scope})
    |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{scope.active_project_id}", %{
      "label" => "the harness at /workspace/app",
      "harness_id" => scope.active_working_copy_id,
      "device" => %{"id" => device_id(context)}
    })
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
