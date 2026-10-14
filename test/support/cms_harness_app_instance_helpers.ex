defmodule CmsHarnessTest.AppInstanceHelpers do
  @moduledoc """
  The rig story 1108's criteria share: a working copy connected to
  `CmsHarnessTest.FakeServer` over a real `CmsHarness.Project.ChannelClient`,
  with `CmsHarness.AppInstance` behind `CmsHarnessTest.FakeAppInstanceRunner`
  — so the channel plumbing and `AppInstance`'s own orchestration run for
  real, and no spex here shells out to `just`, `psql` or a real OS process
  (this project's own rule; see `feedback-no-live-shell-outs-in-tests`).

  `AppInstance` was verified once for real, by hand, against this project's
  own working copy — see the story 1108 handoff. What these specs are about
  is everything *around* that: does the harness ask for it, does the state
  land on the copy, does an agent get refused reaching another one's.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  import CmsHarnessTest.Projects, only: [ensure_harness_supervisor_started: 0]

  alias CmsHarnessTest.FakeAppInstanceRunner
  alias CmsHarnessTest.FakeServer

  @doc """
  Bring up a fresh working copy, connected to a fresh `FakeServer`, with
  `AppInstance`'s runner faked and scripted with `runner_opts`.

  See `FakeAppInstanceRunner.configure/1` for what it accepts —
  `recipe: %{"serve" => false}` for "no start recipe", `probe: :down` for
  "never comes up", and so on.
  """
  def app_instance_rig(runner_opts \\ []) do
    # `FakeServer.start/1` first, not after: `ensure_harness_supervisor_started/0`
    # boots the global, one-time `CmsHarness.Supervisor` — idempotent for
    # every call after the first, in the whole suite — and that first boot
    # is the one moment a machine-wide token exchange and announce happen,
    # reading `CmsHarness.Config.server_url/0` before this rig has told it
    # anything. Started after `FakeServer.start/1` instead, that first boot
    # sees this rig's own `:harness_server_url_override` already in place,
    # the same as every later call does.
    FakeServer.start()
    ensure_harness_supervisor_started()
    install_app_instance_runner(runner_opts)
    use_fast_health_wait()

    root = project_root()
    working_copy_id = onboard(root)

    await_connected(root, working_copy_id)

    %{root: root, working_copy_id: working_copy_id}
  end

  # A 10ms poll rather than the production 1s — against a scripted `Runner`
  # that already knows its answer, a real-second poll would make "an app that
  # fails to boot is reported, not waited on" true of the spex proving it.
  defp use_fast_health_wait do
    previous_interval = Application.get_env(:code_my_spec, :app_instance_health_wait_interval_ms)

    Application.put_env(:code_my_spec, :app_instance_health_wait_interval_ms, 10)

    on_exit(fn -> put_or_delete(:app_instance_health_wait_interval_ms, previous_interval) end)
  end

  @doc """
  Shrink the timeout an `AppInstance` call is given to `ms`, restored on exit.
  A start settles by three quarters of it, so a test of an app that never
  answers waits that long rather than the production 90s.
  """
  def set_op_timeout(ms) do
    previous = Application.get_env(:code_my_spec, :app_instance_op_timeout_ms)
    Application.put_env(:code_my_spec, :app_instance_op_timeout_ms, ms)
    on_exit(fn -> put_or_delete(:app_instance_op_timeout_ms, previous) end)
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:code_my_spec, key)
  defp put_or_delete(key, value), do: Application.put_env(:code_my_spec, key, value)

  @doc """
  Shrink a first start's 10-minute ceiling to `ms`, restored on exit — for a
  criterion about what happens once that ceiling passes, where the
  production default would mean actually waiting 10 minutes. Combined with
  `app_instance_rig/1`'s own fast health-wait interval (10ms), the background
  check this schedules fires on its very next tick, so a spex can
  `assert_receive` the resulting `app_status` push instead of sleeping for
  either duration.
  """
  def set_first_start_ceiling(ms) do
    previous = Application.get_env(:code_my_spec, :app_instance_first_start_ceiling_ms)
    Application.put_env(:code_my_spec, :app_instance_first_start_ceiling_ms, ms)
    on_exit(fn -> put_or_delete(:app_instance_first_start_ceiling_ms, previous) end)
  end

  @doc """
  Shrink `AppInstance`'s idle timeout and re-check interval to real
  milliseconds, restored on exit — for a criterion about the idle-stop
  itself, where `app_instance_rig/1`'s own defaults (fast health polling,
  production idle timing) would otherwise mean actually waiting 30 minutes.
  """
  def set_idle_timeout(opts) do
    previous_idle = Application.get_env(:code_my_spec, :app_instance_idle_timeout_ms)
    previous_interval = Application.get_env(:code_my_spec, :app_instance_idle_check_interval_ms)

    Application.put_env(
      :code_my_spec,
      :app_instance_idle_timeout_ms,
      Keyword.fetch!(opts, :idle_ms)
    )

    Application.put_env(
      :code_my_spec,
      :app_instance_idle_check_interval_ms,
      Keyword.fetch!(opts, :check_interval_ms)
    )

    on_exit(fn ->
      put_or_delete(:app_instance_idle_timeout_ms, previous_idle)
      put_or_delete(:app_instance_idle_check_interval_ms, previous_interval)
    end)
  end

  @doc """
  Install (or reconfigure) `FakeAppInstanceRunner` as `AppInstance`'s runner.

  Idempotent for the same reason `install_workspace_runner/2` is: scenarios
  inside one `spex` block share a test process, so a second `given_` in a
  later scenario meets an `{:already_started, pid}` rather than starting a
  second fake — that reads as a supervision bug in the code under test, not
  as a second call to a fixture.
  """
  def install_app_instance_runner(opts \\ []) do
    Application.put_env(:code_my_spec, CmsHarness.AppInstance, runner: FakeAppInstanceRunner)

    case Process.whereis(FakeAppInstanceRunner) do
      nil ->
        {:ok, pid} = FakeAppInstanceRunner.start_link(opts)
        Process.unlink(pid)
        on_exit(fn -> stop_fake(pid) end)

      _already_running ->
        FakeAppInstanceRunner.configure(opts)
    end

    :ok
  end

  defp stop_fake(pid) do
    if Process.alive?(pid), do: Agent.stop(pid)
  catch
    :exit, _ -> :ok
  end

  @doc "Push one of the app verbs to the copy's real harness and wait for its `_result`."
  def push_app_event(event, timeout \\ 5_000) do
    ref = FakeServer.push_app_event(event, %{})
    await_app_result(event, ref, timeout)
  end

  @doc "Push one of the app verbs with a payload of the caller's choosing — a `tunnel`, say — and wait for its `_result`."
  def push_app_event_with(event, payload, timeout \\ 5_000) do
    ref = FakeServer.push_app_event(event, payload)
    await_app_result(event, ref, timeout)
  end

  @doc "Push one of the app verbs marked `main: true`, the way `HarnessProjectChannel.put_main/2` does for the designated copy."
  def push_app_event_as_main(event, timeout \\ 5_000) do
    ref = FakeServer.push_app_event(event, %{"main" => true})
    await_app_result(event, ref, timeout)
  end

  @doc """
  A barrier on `AppInstance`'s own reply-then-hook ordering for `root`'s
  copy — not a read of its state, which a caller must not assert on.

  `handle_call({:restart, ...})` replies before running the after-promote
  hook, on purpose (its own comment explains why: the recipe can kill the
  very BEAM answering the call). That hook is the next statement in the
  same `handle_call` clause, not a separate later message, so it is not
  necessarily done by the time a caller's own channel round trip delivers
  the reply — spex may not reference `CmsHarness` directly, so this wraps
  the wait every such assertion needs: `:sys.get_state/1` on the same
  GenServer cannot be answered until the clause that sent the reply has
  fully returned, which puts the hook's completion strictly before this
  call's.
  """
  def sync_after_reply(root), do: :sys.get_state(CmsHarness.AppInstance.via(root))

  # --- internals ---

  # A directory that looks enough like a project to be served, mirroring
  # `CmsHarnessTest.Projects.project_dir/1` — `lib/`, `test/`, `.code_my_spec/`
  # so `Watcher` finds something to watch, and a `justfile` so a criterion
  # that inspects the real file (rather than the faked `recipe?/2` answer)
  # has one to look at. Nothing here is ever shelled out to — `AppInstance`'s
  # own filesystem/process calls all go through the faked `Runner`.
  defp project_root do
    root = CodeMySpec.TempFile.dir("spex-1108")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))
    File.mkdir_p!(Path.join(root, ".code_my_spec"))
    File.write!(Path.join(root, "justfile"), "serve:\n    @true\n")

    # One trackable file so a scan mid-test finds something rather than
    # erroring "found no trackable files" — a real error-level log this
    # rig's own emptiness would cause, unrelated to whatever a criterion is
    # asserting.
    File.write!(Path.join(root, "lib/fake_app.ex"), "defmodule FakeApp do\nend\n")

    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp onboard(root) do
    working_copy_id = Ecto.UUID.generate()

    :ok =
      CmsHarness.HarnessConfig.write(root, %{
        working_copy_id: working_copy_id,
        project_id: "1",
        root: root
      })

    {:ok, _identity} = CmsHarnessTest.Projects.ensure_started(root)
    on_exit(fn -> CmsHarnessTest.Projects.stop_project(root) end)
    on_exit(fn -> stop_app_instance(root) end)

    working_copy_id
  end

  # `AppInstance` deliberately lives outside the project's own `rest_for_one`
  # chain (see its own moduledoc: it must survive a reconnect or a channel
  # blip), so `stop_project/1` above never touches it — a test whose
  # scenario actually started one (`ensure_app_running`/`restart_app`
  # against a scripted "serving" runner) leaves it running with whatever
  # idle timeout was live at the time, sometimes many minutes, sometimes
  # milliseconds if a *later* test in the same run calls `set_idle_timeout/1`
  # and this leftover reads the same global config on its next tick.
  #
  # Left alone, it fires its own `handle_info(:timeout, ...)` on its own
  # schedule, calling into `FakeAppInstanceRunner` — a global, singleton
  # fake this rig reconfigures per test rather than restarting — from a
  # process nothing is asserting on any more. If a later test happens to be
  # mid-teardown of that same fake right when it fires, the call raises
  # `:noproc` and logs an unrelated `[error]` against whatever test happens
  # to be running at that moment. Stopping it here, at the end of the test
  # that started it, is what prevents it from outliving the fake it depends
  # on.
  defp stop_app_instance(root) do
    case Registry.lookup(CmsHarness.Registry, {:app_instance, root}) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(CmsHarness.Copy.Supervisor.apps(root), pid)

      [] ->
        :ok
    end
  end

  # Event-driven, not polled. `FakeServer.ProjectChannel.join/3` sends
  # `{:joined, project_id, payload}` to whoever called `FakeServer.listen/1`
  # (this test process, via `FakeServer.start/1`) the moment the real
  # `ChannelClient`'s join actually lands, so this returns the instant that
  # happens instead of on a fixed clock.
  #
  # The previous version polled `Channel.connected?/1` on a 200×10ms
  # (2s) budget — a sleep loop, and one this project's own rule forbids in
  # tests. It also went red under Criterion Binding's full-suite branch
  # sweep (run 52853, 14 of story 1108's spex, all "never connected"): the
  # harness's own reconnect backoff is 1-2s a step, so a single lost first
  # attempt under heavier load could eat the whole 2s budget on its own
  # retry, cutting off a connection that was always going to land a moment
  # later. A wait bounded by the event itself has no such ceiling to race.
  #
  # Matched on `harness_id`, not left a wildcard: every rig's `onboard/1`
  # joins as project "1" (there is only ever one project id in this rig), so
  # a stale reconnect from a *previous* test's not-yet-torn-down harness
  # lands here too, and an unmatched `{:joined, _, _}` was satisfied by that
  # one instead — this test's own join hadn't happened yet, `push_app_event`
  # ran a moment later against a channel that was never actually set, and
  # the failure read as "no channel has joined the fake server", not as the
  # stale-message bug it was. `harness_id` is this rig's own working copy
  # id, unique per call, so only this test's own join can satisfy it.
  defp await_connected(root, working_copy_id) do
    assert_receive {:joined, _project_id, %{"harness_id" => ^working_copy_id}},
                   10_000,
                   "the copy's harness never connected to the fake server (root: #{root})"
  end

  defp await_app_result(event, ref, timeout) do
    # `FakeServer.notify/1` tags its message with the atom
    # `:<event>_result` (see `handle_in("ensure_app_running_result", ...)`
    # etc. in `CmsHarnessTest.FakeServer`) — not the string this module's
    # other names are built from. A pinned string here matched nothing and
    # every call fell through to the timeout looking exactly like a hang,
    # while the real round trip (channel push, `AppInstance`, push back) had
    # already completed correctly.
    result_event = String.to_existing_atom("#{event}_result")

    receive do
      {^result_event, %{"ref" => ^ref} = payload} -> payload
      {^result_event, _other} -> await_app_result(event, ref, timeout)
    after
      timeout -> flunk("no #{result_event} for ref #{ref} within #{timeout}ms")
    end
  end
end
