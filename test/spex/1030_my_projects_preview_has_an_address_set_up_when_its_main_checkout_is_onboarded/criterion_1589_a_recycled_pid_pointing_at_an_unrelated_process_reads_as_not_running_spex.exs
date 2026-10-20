defmodule CodeMySpecSpex.Story1030.Criterion1589Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main
  checkout is onboarded.
  Criterion 1589 — A recycled pid pointing at an unrelated process reads as
  not running.

  Rule: A working copy's app is treated as running only when the tracked
  `os_pid` still belongs to this copy's own checkout, not merely when
  something answers to that pid. A persisted `state.json` (rehydrate) or a
  stop can outlive the process it named; the OS is then free to reissue
  that pid to anything, and treating it as alive would let a stop kill a
  stranger. Identity is confirmed the same way `ensure_port_free/2` already
  confirms it before adopting a port: the process's own working directory
  matches this copy's root.

  Found live: after stopping a working copy's app by hand,
  `~/.codemyspec/app-instances/<id>/state.json` still named the dead
  process's `os_pid` as `status: "serving"`. `Runner.alive?/1` alone cannot
  tell "still ours" from "reassigned" — only that some process now answers
  to that number — so `handle_call({:restart, main?}, ...)`'s own
  `if running?(state), do: stop_process(state)` would `kill -TERM` whatever
  the OS has since handed that pid to.

  Exercised via `restart_app` rather than `ensure_app_running`: the latter's
  own retry path calls `launch/6` again on anything it decides is not
  running, and this suite's fake resets its scripted `process_root` to
  match on every `launch/6` call (see that helper's own comment) — the same
  thing a *real* fresh launch would do, since a freshly-launched process's
  cwd trivially matches its own root. `restart_app`'s `stop_process(state)`
  call is what this criterion is actually about: the one place a stale
  identity, left unchecked, reaches for `kill -TERM` before anything new
  has been launched to replace it.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  spex "A recycled pid pointing at an unrelated process reads as not running",
    criterion: 1589 do
    scenario "restarting a copy whose tracked pid now belongs elsewhere" do
      given_ "a working copy whose app is running", context do
        rig = app_instance_rig(database_exists?: true)
        context = Map.merge(context, rig)
        {:ok, Map.put(context, :result, push_app_event("ensure_app_running"))}
      end

      then_ "the app is reported serving", context do
        assert %{"status" => "ok", "app_status" => "serving"} = context.result
        {:ok, context}
      end

      when_ "the tracked pid's own working directory stops matching this copy's root, and a restart is asked for",
            context do
        # The pid itself never changes — this is the recycling case, not a
        # crash: something still answers `alive?` for it, it is simply not
        # this copy's process any more.
        FakeAppInstanceRunner.put_process_root("/somewhere/else/entirely")
        {:ok, Map.put(context, :result, push_app_event("restart_app"))}
      end

      then_ "the restart still succeeds, launching fresh rather than trusting the stale pid",
            context do
        assert %{"status" => "ok", "app_status" => "serving"} = context.result
        {:ok, context}
      end

      then_ "no stop was ever sent to the mismatched pid", context do
        stop_calls = Enum.filter(FakeAppInstanceRunner.calls(), &match?({:stop_process, _}, &1))

        assert stop_calls == [],
               "a pid whose cwd no longer matches this copy's root should read as " <>
                 "already not running, so the restart's own \"stop what's running\" " <>
                 "step has nothing to stop — reaching `kill -TERM` for it at all is " <>
                 "the hazard this criterion exists to prevent, whatever pid it would " <>
                 "have named. Got: #{inspect(stop_calls)}"

        {:ok, context}
      end

      then_ "a fresh launch replaced it", context do
        launch_calls = Enum.filter(FakeAppInstanceRunner.calls(), &match?({:launch, _}, &1))

        assert length(launch_calls) == 2,
               "the first launch from ensure_app_running, then a second from restart_app " <>
                 "once the mismatched pid was correctly distrusted. Got: #{inspect(launch_calls)}"

        {:ok, context}
      end
    end
  end
end
