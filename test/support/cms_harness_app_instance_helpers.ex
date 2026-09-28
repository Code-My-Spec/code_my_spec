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

  alias CmsHarness.Project.ChannelClient
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
    ensure_harness_supervisor_started()
    install_app_instance_runner(runner_opts)
    use_fast_health_wait()
    FakeServer.start()

    root = project_root()
    working_copy_id = onboard(root)

    await_connected(root)

    %{root: root, working_copy_id: working_copy_id}
  end

  # Two attempts, no sleep — against a scripted `Runner` that already knows
  # its answer, waiting the production 15×1000ms for "an app that fails to
  # boot is reported, not waited on" would make that criterion's own subject
  # true of the spex proving it.
  defp use_fast_health_wait do
    previous_attempts = Application.get_env(:code_my_spec, :app_instance_health_wait_attempts)
    previous_interval = Application.get_env(:code_my_spec, :app_instance_health_wait_interval_ms)

    Application.put_env(:code_my_spec, :app_instance_health_wait_attempts, 2)
    Application.put_env(:code_my_spec, :app_instance_health_wait_interval_ms, 0)

    on_exit(fn ->
      put_or_delete(:app_instance_health_wait_attempts, previous_attempts)
      put_or_delete(:app_instance_health_wait_interval_ms, previous_interval)
    end)
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:code_my_spec, key)
  defp put_or_delete(key, value), do: Application.put_env(:code_my_spec, key, value)

  @doc """
  Shrink `AppInstance`'s idle timeout and re-check interval to real
  milliseconds, restored on exit — for a criterion about the idle-stop
  itself, where `app_instance_rig/1`'s own defaults (fast health polling,
  production idle timing) would otherwise mean actually waiting 30 minutes.
  """
  def set_idle_timeout(opts) do
    previous_idle = Application.get_env(:code_my_spec, :app_instance_idle_timeout_ms)
    previous_interval = Application.get_env(:code_my_spec, :app_instance_idle_check_interval_ms)

    Application.put_env(:code_my_spec, :app_instance_idle_timeout_ms, Keyword.fetch!(opts, :idle_ms))
    Application.put_env(:code_my_spec, :app_instance_idle_check_interval_ms, Keyword.fetch!(opts, :check_interval_ms))

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

  @doc "Push one of the app verbs marked `main: true`, the way `HarnessProjectChannel.put_main/2` does for the designated copy."
  def push_app_event_as_main(event, timeout \\ 5_000) do
    ref = FakeServer.push_app_event(event, %{"main" => true})
    await_app_result(event, ref, timeout)
  end

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

    working_copy_id
  end

  defp await_connected(root, attempts \\ 200)

  defp await_connected(_root, 0), do: flunk("the copy's harness never connected to the fake server")

  defp await_connected(root, attempts) do
    if ChannelClient.connected?(root) do
      :ok
    else
      Process.sleep(10)
      await_connected(root, attempts - 1)
    end
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
