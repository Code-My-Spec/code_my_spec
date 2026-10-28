defmodule CmsHarness.ServedRootsTest do
  use ExUnit.Case, async: false

  alias CmsHarness.{Credentials, HarnessConfig, Projects, ServedRoots, WorkingCopyReporter}

  defmodule Server do
    @behaviour CmsHarness.Device.Client
    @impl true
    def announce(device_id, _token, _attrs) do
      send(Application.fetch_env!(:code_my_spec, :root_test_owner), :announced)

      {:ok,
       %{
         device_id: device_id,
         working_copies: Application.fetch_env!(:code_my_spec, :root_test_roster)
       }}
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "served_roots_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    keys = [
      :harness_served_roots_dir,
      :harness_server_url_override,
      :harness_token,
      :harness_deploy_key,
      :device_client,
      :device_config_path,
      :root_test_owner,
      :root_test_roster
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:code_my_spec, &1)})
    variables = ~w(CMS_PROJECT_DIR CMS_PROJECT_ID CMS_TOKEN CMS_DEPLOY_KEY)
    environment = Map.new(variables, &{&1, System.get_env(&1)})
    Enum.each(variables, &System.delete_env/1)
    Enum.each(keys, &Application.delete_env(:code_my_spec, &1))
    Application.put_env(:code_my_spec, :harness_served_roots_dir, Path.join(dir, "hints"))
    Application.put_env(:code_my_spec, :harness_server_url_override, "http://127.0.0.1:1")
    Application.put_env(:code_my_spec, :device_client, Server)
    Application.put_env(:code_my_spec, :device_config_path, Path.join(dir, "device.json"))
    Application.put_env(:code_my_spec, :root_test_owner, self())

    ensure_child(
      Process.whereis(CmsHarness.Registry),
      {Registry, keys: :unique, name: CmsHarness.Registry}
    )

    ensure_child(
      Process.whereis(CmsHarness.CopiesSupervisor),
      {DynamicSupervisor, name: CmsHarness.CopiesSupervisor, strategy: :one_for_one}
    )

    on_exit(fn ->
      for root <- Projects.list(), String.starts_with?(root, dir), do: Projects.stop_serving(root)
      Enum.each(previous, &restore_config/1)
      Enum.each(environment, &restore_environment/1)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "boot uses a remembered credential but restores only the current server roster", %{
    dir: dir
  } do
    root = copy(dir, "agent-only")
    retired = copy(dir, "offboarded-while-offline")
    roster = Map.new([root, retired], &serve_then_lose/1)
    refute root in Projects.list()
    refute retired in Projects.list()
    rewrite(root, "deploy_key", "rotated-key")
    [hint | _] = Path.wildcard(Path.join(dir, "hints/**/*.json"))
    File.write!(Path.join(Path.dirname(hint), "corrupt.json"), "invalid JSON")

    # No served roots supply this credential: hints break the announce cycle.
    assert {:ok, _key, :working_copy_key} = Credentials.any()
    assert {:ok, "rotated-key", :working_copy_key} = Credentials.for_working_copy(root)

    # The server removed retired while the daemon was offline. Its valid hint
    # must never cause a channel join that would recreate the deleted row.
    roster = Map.reject(roster, fn {_id, path} -> path == retired end)
    boot_reporter(roster)
    assert root in Projects.list()
    refute retired in Projects.list()

    assert :ok = Projects.stop_serving(root)
    refute root in ServedRoots.list()
  end

  test "boot skips missing paths and changed identities or servers", %{dir: dir} do
    roots = Enum.map(~w(missing identity server), &copy(dir, &1))
    roster = Map.new(roots, &serve_then_lose/1)
    [missing, identity, server] = roots
    File.rm_rf!(missing)
    rewrite(identity, "working_copy_id", "re-onboarded")
    rewrite(server, "server_url", "https://another-server.invalid")

    boot_reporter(roster)
    assert Enum.all?(roots, &(&1 not in Projects.list()))
  end

  test "hints contain no credentials and are isolated by server and current credentials", %{
    dir: dir
  } do
    root = copy(dir, "one")
    serve_then_lose(root)
    [path] = Path.wildcard(Path.join(dir, "hints/**/*.json"))
    refute File.read!(path) =~ "fixture-key"
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert ServedRoots.list() == [root]
    rewrite(root, "deploy_key", nil)
    assert ServedRoots.list() == []
    rewrite(root, "deploy_key", "rotated-key")

    Application.put_env(
      :code_my_spec,
      :harness_server_url_override,
      "https://another-server.invalid"
    )

    assert ServedRoots.list() == []
    assert {:error, :no_credential} = Credentials.any()

    conn = CmsHarness.Web.HealthController.index(Plug.Test.conn(:get, "/health"), %{})
    health = Jason.decode!(conn.resp_body)
    assert health["credential"] == false
    assert Map.has_key?(health, "authorization")
  end

  defp boot_reporter(roster) do
    # Token exchange is outside this test. Credential bootstrap is asserted
    # before setting this synthetic token, then the real reporter boot timer
    # drives the stubbed authoritative server response and actual subtrees.
    oauth_dir = CmsHarnessTest.HarnessOAuthFixture.isolate()

    CmsHarnessTest.HarnessOAuthFixture.seed(
      oauth_dir,
      CmsHarness.Config.server_url(),
      "fixture-harness-token"
    )

    Application.put_env(:code_my_spec, :root_test_roster, roster)
    pid = start_supervised!({WorkingCopyReporter, name: :served_roots_boot_test})
    # Generous: the boot report waits on a timer and a credential lookup, and
    # a 1s wait lost to gate load (2026-10-13). Returns as soon as it lands.
    assert_receive :announced, 15_000
    :sys.get_state(pid, 30_000)
  end

  defp serve_then_lose(root) do
    assert {:ok, project} = Projects.ensure_started(root)
    [{_pid, _}] = Registry.lookup(CmsHarness.Registry, {:project, root})
    # Application shutdown, not deliberate offboarding: the channel chain goes,
    # and the root stays remembered.
    assert :ok = CmsHarness.Copy.Supervisor.unserve(root)
    await_unregistered({:project, root})
    {project.working_copy_id, root}
  end

  # Registry's own docs: "if a process crashes, its keys are automatically
  # removed from the registry but the change may not propagate immediately."
  # `terminate_child/2` guarantees the project process is dead; it says
  # nothing about CmsHarness.Registry having processed that death yet. Under
  # concurrent registry traffic (this suite's other async cases registering
  # and unregistering their own projects at the same time) that gap is wide
  # enough for `Projects.list()` to still report a root this very function
  # just terminated (8034e7b7).
  #
  # No sleep: `:erlang.yield/0` reliably resolves this in under a millisecond
  # in a 30-trial reproduction run under equivalent concurrent registry load
  # (immediate checks raced ~80% of the time; every yield-based retry cleared
  # on its first or second iteration). A fixed delay would either flake again
  # on a slower box or pad every passing run for no reason.
  defp await_unregistered(key, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    await_unregistered(key, deadline, Registry.lookup(CmsHarness.Registry, key))
  end

  defp await_unregistered(_key, _deadline, []), do: :ok

  defp await_unregistered(key, deadline, entries) do
    retry_or_flunk(key, deadline, entries, System.monotonic_time(:millisecond) < deadline)
  end

  defp retry_or_flunk(key, deadline, _entries, true = _within_deadline?) do
    :erlang.yield()
    await_unregistered(key, deadline)
  end

  defp retry_or_flunk(key, _deadline, entries, false = _within_deadline?) do
    flunk("Registry.lookup(CmsHarness.Registry, #{inspect(key)}) still #{inspect(entries)}")
  end

  defp ensure_child(nil, spec), do: start_supervised!(spec)
  defp ensure_child(pid, _spec), do: pid
  defp restore_config({key, nil}), do: Application.delete_env(:code_my_spec, key)
  defp restore_config({key, value}), do: Application.put_env(:code_my_spec, key, value)
  defp restore_environment({key, nil}), do: System.delete_env(key)
  defp restore_environment({key, value}), do: System.put_env(key, value)

  defp copy(dir, name) do
    root = Path.join(dir, name)
    File.mkdir_p!(root)

    :ok =
      HarnessConfig.write(root, %{
        working_copy_id: Ecto.UUID.generate(),
        project_id: Ecto.UUID.generate(),
        deploy_key: "fixture-key",
        server_url: "http://127.0.0.1:1"
      })

    root
  end

  defp rewrite(root, key, value) do
    path = HarnessConfig.path(root)
    contents = path |> File.read!() |> Jason.decode!() |> Map.put(key, value)
    File.write!(path, Jason.encode!(contents))
  end
end
