defmodule CmsHarness.ReporterPicksUpWhatTheServerSaysTest do
  @moduledoc """
  A restarted harness serves the copies it is carrying, without waiting to be
  hooked.

  `Projects.ensure_started/1` adopted a copy on its **first hook request**, so a
  checkout became served when somebody opened a session in it and never
  otherwise. Fine for a person; wrong for everything else. A background agent
  makes no hook requests, and a worktree created *for* an agent has nobody in it
  to make one.

  So every harness restart — and every rebuild restarts it — silently dropped
  every copy without a live session in its directory. The agents on them kept
  their `running` rows and became unreachable, and the only thing that said so
  was a message failing to deliver. Observed three times on 2026-09-04, twice
  against an agent the owner was actively trying to talk to.

  The server already answers the question: `Device.announce/1` replies with the
  copies attached to this device, and the reporter has always merged them into
  `known` and used them for nothing else.
  """

  use ExUnit.Case, async: false

  alias CmsHarness.WorkingCopyReporter

  defmodule ServerSays do
    @moduledoc "Answers announce with a fixed set, the way the server does."
    @behaviour CmsHarness.Device.Client

    @impl true
    def announce(device_id, _token, _attrs) do
      # Application env, not `Process.get/1`: this runs inside the reporter's
      # own process, so anything the test put in its own dictionary is invisible
      # here. The stub answered `%{}` and made a working fix look broken.
      {:ok,
       %{
         device_id: device_id,
         working_copies: Application.get_env(:code_my_spec, :test_server_copies, %{}),
         pending_local_projects: Application.get_env(:code_my_spec, :test_server_pending, [])
       }}
    end
  end

  defmodule TellsTheTest do
    @moduledoc "A generator runner that reports its first command and goes no further."
    @behaviour CmsHarness.Projects.Generator.Runner

    @impl true
    def cmd(cwd, command, args) do
      send(Application.fetch_env!(:code_my_spec, :test_pid), {:generator, cwd, command, args})
      {:error, :stopped_by_test}
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "reporter_pickup_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    previous = %{
      client: Application.get_env(:code_my_spec, :device_client),
      token: Application.get_env(:code_my_spec, :harness_token),
      path: Application.get_env(:code_my_spec, :device_config_path)
    }

    # The harness tree this needs. `mix test` does not start the harness, and
    # `ensure_started/1` has nowhere to put a subtree without it.
    ensure_started(CmsHarness.Registry, fn ->
      Registry.start_link(keys: :unique, name: CmsHarness.Registry)
    end)

    ensure_started(CmsHarness.CopiesSupervisor, fn ->
      DynamicSupervisor.start_link(name: CmsHarness.CopiesSupervisor, strategy: :one_for_one)
    end)

    Application.put_env(:code_my_spec, :device_client, ServerSays)
    oauth_dir = CmsHarnessTest.HarnessOAuthFixture.isolate()

    CmsHarnessTest.HarnessOAuthFixture.seed(
      oauth_dir,
      CmsHarness.Config.server_url(),
      "stub-token"
    )

    Application.put_env(:code_my_spec, :device_config_path, Path.join(dir, "device.json"))

    on_exit(fn ->
      restore(:device_client, previous.client)
      restore(:harness_token, previous.token)
      restore(:device_config_path, previous.path)
      Application.delete_env(:code_my_spec, :test_server_copies)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  # Unlinked, matching how the suite's other harness helpers do it: linked, the
  # tree dies with whichever test happened to start it and the next one either
  # raises `unknown registry` or starts a second tree beside the first.
  defp ensure_started(name, start) do
    start_if_needed(Process.whereis(name), start)
  end

  defp start_if_needed(nil, start) do
    {:ok, pid} = start.()
    Process.unlink(pid)
    :ok
  end

  defp start_if_needed(_pid, _start), do: :ok

  defp restore(key, nil), do: Application.delete_env(:code_my_spec, key)
  defp restore(key, value), do: Application.put_env(:code_my_spec, key, value)

  test "a copy the server names is picked up even though nothing hooked into it", %{dir: dir} do
    root = Path.join(dir, "a-checkout-nobody-opened")
    File.mkdir_p!(root)

    # A real working copy: the identity file is what makes a directory one, and
    # `ProjectIdentity.resolve/1` refuses anything without it — correctly.
    File.write!(
      Path.join(root, ".cms_harness.json"),
      Jason.encode!(%{
        working_copy_id: "copy-1",
        harness_id: "copy-1",
        project_id: Ecto.UUID.generate(),
        root: root
      })
    )

    Application.put_env(:code_my_spec, :test_server_copies, %{"copy-1" => root})

    # No hook has arrived for this root, which is the whole premise: after a
    # restart the only thing that knew about it is the server.
    refute root in served(),
           "the premise failed — this root is already being served"

    {:ok, pid} = start_supervised({WorkingCopyReporter, name: :pickup_test, known: %{}})
    WorkingCopyReporter.report(pid)

    assert root in served(),
           "the harness was told it is carrying this copy and did not pick it up. " <>
             "Every restart drops every copy nobody has a session open in, and the " <>
             "agents on them go unreachable with nothing saying so."
  end

  test "a copy the server names that is not on disk is left alone", %{dir: dir} do
    gone = Path.join(dir, "removed-worktree")

    Application.put_env(:code_my_spec, :test_server_copies, %{"copy-2" => gone})

    {:ok, pid} = start_supervised({WorkingCopyReporter, name: :pickup_gone_test, known: %{}})
    WorkingCopyReporter.report(pid)

    refute gone in served(),
           "a directory that is not there was adopted. That is what the " <>
             "missing-checkout report is for, and starting a subtree to watch " <>
             "nothing turns a clean answer into a crash loop."
  end

  # d4747513: nothing dropped a gone checkout's databases.
  test "a checkout gone from disk has its databases dropped, once", %{dir: dir} do
    gone = Path.join(dir, "removed-gate-copy")
    prior = Application.get_env(:code_my_spec, CmsHarness.CopyDatabases)

    Application.put_env(:code_my_spec, CmsHarness.CopyDatabases,
      runner: CmsHarnessTest.FakeAppInstanceRunner
    )

    on_exit(fn -> Application.put_env(:code_my_spec, CmsHarness.CopyDatabases, prior) end)
    start_supervised!(CmsHarnessTest.FakeAppInstanceRunner)
    Application.put_env(:code_my_spec, :test_server_copies, %{"copy-3" => gone})

    {:ok, pid} = start_supervised({WorkingCopyReporter, name: :drop_gone_test, known: %{}})
    WorkingCopyReporter.report(pid)
    WorkingCopyReporter.report(pid)
    WorkingCopyReporter.report(pid)

    asked =
      for {:idle_databases_matching, [regex]} <- CmsHarnessTest.FakeAppInstanceRunner.calls(),
          do: regex

    assert [_once] = asked
  end

  describe "a project the server offers to generate" do
    setup do
      previous = %{
        runner: Application.get_env(:code_my_spec, :generator_runner),
        project_dir: System.get_env("CMS_PROJECT_DIR")
      }

      on_exit(fn ->
        restore(:generator_runner, previous.runner)
        Application.delete_env(:code_my_spec, :test_server_pending)
        Application.delete_env(:code_my_spec, :test_pid)
        restore_env("CMS_PROJECT_DIR", previous.project_dir)
      end)

      Application.put_env(:code_my_spec, :generator_runner, TellsTheTest)
      Application.put_env(:code_my_spec, :test_pid, self())

      Application.put_env(:code_my_spec, :test_server_pending, [
        # Named so no directory is there: the stubbed `mix cms.new` is the first
        # step, and nothing is made.
        %{
          id: Ecto.UUID.generate(),
          name: "Never made",
          app_name: "reporter_test_#{System.unique_integer([:positive])}",
          deploy_key: "dk"
        }
      ])

      :ok
    end

    test "is generated by the machine's harness" do
      System.delete_env("CMS_PROJECT_DIR")

      {:ok, pid} = start_supervised({WorkingCopyReporter, name: :generate_test, known: %{}})
      WorkingCopyReporter.report(pid)

      assert_receive {:generator, _cwd, "mix", ["cms.new" | _]}, 5_000
    end

    # A QA harness on one fixture copy started generating the account's new
    # project, deps and database included.
    test "is left alone by a harness started for one copy", %{dir: dir} do
      System.put_env("CMS_PROJECT_DIR", Path.join([dir, "device-a", "copy"]))

      {:ok, pid} = start_supervised({WorkingCopyReporter, name: :no_generate_test, known: %{}})
      WorkingCopyReporter.report(pid)

      refute_receive {:generator, _, _, _}, 500
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp served do
    CmsHarness.Projects.list()
  end
end
