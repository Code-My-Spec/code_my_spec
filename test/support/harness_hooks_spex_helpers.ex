defmodule CodeMySpecSpex.HarnessHooks do
  @moduledoc """
  Hooks driven the way production drives them, end to end.

      context = given_a_live_harness(context, files: %{"lib/app.ex" => "..."})
      write_file(context, ".code_my_spec/qa/1/brief.md", brief)
      decision = post_hook(context, "stop", %{"session_id" => id})

  `post_hook/3` is an HTTP POST to the harness web at
  `/api/harnesses/<working_copy_id>/hooks/<hook>` — what Claude Code's plugin
  sends. The harness forwards it over its real Slipstream socket to the cloud's
  `HarnessProjectChannel`, which decides it with `CodeMySpec.Hooks.*`; every
  file the decision reads goes back over that socket as `fs_request` and is
  answered from the checkout on disk by the harness. The decision returned is
  what the agent would see.

  ## The cloud listens, for real

  `CodeMySpecWeb.Endpoint` runs `server: false` in test. This starts a Bandit
  listener on a free loopback port with the endpoint itself as its plug — the
  same `/socket` mount, `UserSocket` and channel as production, with no
  production code changed — and points the harness's `:harness_server_url` at
  it. The listener is this context's alone and is stopped on exit.

  ## Sandbox ownership

  The processes that touch the database on one hook are none of the test's:
  Bandit's connection process (`UserSocket.connect/3` resolves the deploy key),
  the channel process (join, authorization, the manifest reconcile), the
  channel's `reply_async` task (the decision itself) and the graph watcher.
  Phoenix gives a channel no `$callers` to inherit an allowance through, and
  the join's own queries run before any pid is known to allow. So this runs
  only in `{:shared, owner}` mode, which a non-async spex (and a non-async
  `DataCase`) is already in, and refuses an async context rather than failing
  later with an ownership error.

  ## Teardown

  One `on_exit`, registered before anything starts so a join that fails is
  still cleaned up, and run before the sandbox owner stops. In order: stop the
  listener, so the *cloud* closes the socket (a harness that hangs up first is
  logged at `:error` by the channel as a death); wait for the channel process
  to be gone; stop serving the checkout; put the harness's environment back.
  """

  import ExUnit.Assertions

  alias CmsHarnessTest.LiveHarness
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.TempFile
  alias CodeMySpecSpex.Fixtures
  alias Phoenix.ConnTest
  alias Plug.Conn

  # A join, a read-model round trip, a scan and a reconcile. Generous because
  # the machine running this is usually running other suites too.
  @timeout 10_000

  @doc """
  A checkout of `context.project` on disk, onboarded, served by a real harness
  joined to a listening cloud endpoint.

  Needs `context.scope` and `context.project` (`setup :setup_active_project`).
  Adds `context.harness`: `root`, `working_copy_id`, `deploy_key`, `device_id`
  and `server_url`.

  Options:

    * `:files` — `%{relative_path => content}` written into the checkout and
      committed before the harness starts. Give it at least one file the
      scanner tracks: a harness whose scan finds nothing refuses to send it.
  """
  @spec given_a_live_harness(map(), keyword()) :: map()
  def given_a_live_harness(context, opts \\ []) do
    refuse_async!(context)

    %{scope: scope, project: project} = context
    key = "dk_live_#{System.unique_integer([:positive])}"
    _project = Fixtures.set_project_deploy_key(scope, project, key)
    device = Fixtures.device_fixture(scope)

    root =
      LiveHarness.checkout(%{
        project_id: project.id,
        account_id: project.account_id,
        files: Keyword.get(opts, :files, %{})
      })

    working_copy_id = onboard(project, key, device.id, root)

    :ok =
      LiveHarness.onboard(root, %{
        working_copy_id: working_copy_id,
        project_id: project.id,
        deploy_key: key
      })

    device_file = device_file(device.id)
    {listener, url} = listen()
    topic = "harness_project:#{project.id}"
    handler = watch_channel(topic, working_copy_id)
    saved = LiveHarness.save_env()

    ExUnit.Callbacks.on_exit(fn ->
      teardown(%{
        root: root,
        working_copy_id: working_copy_id,
        listener: listener,
        handler: handler,
        saved: saved
      })
    end)

    :ok = LiveHarness.serve(root, url, device_file, saved)
    await_joined(working_copy_id)

    Map.put(context, :harness, %{
      root: root,
      working_copy_id: working_copy_id,
      topic: topic,
      deploy_key: key,
      device_id: device.id,
      server_url: url
    })
  end

  @doc """
  POST `hook` with `payload` to the harness serving `context.harness`, and
  answer the decoded decision.

  `cwd` is filled in as the checkout's root unless the payload names one —
  every Claude Code hook payload carries it. An absolute `tool_input.file_path`
  is sent as-is: making it project-relative is the harness's job.
  """
  @spec post_hook(map(), String.t(), map()) :: map()
  def post_hook(%{harness: %{working_copy_id: id, root: root}}, hook, payload \\ %{}) do
    LiveHarness.post_hook(id, hook, Map.put_new(payload, "cwd", root))
  end

  @doc """
  Write `content` at `path` in the checkout, as an agent's `Write` does, and
  return once the harness has noticed it and the cloud has recorded it.

  "Recorded" is the cloud's channel having handled a manifest carrying this
  path at this content's fingerprint. A reconcile runs inline in the channel
  under test (`analysis_mode: :inline`), so by then the file's row is written
  and a hook posted next sees it — the ordering a real agent gets from the
  seconds between its write and its stop.

  Answers the absolute path, which is what an agent's `tool_input.file_path`
  carries.
  """
  @spec write_file(map(), String.t(), String.t()) :: String.t()
  def write_file(%{harness: %{root: root, working_copy_id: id}}, path, content) do
    fingerprint = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    ref = {__MODULE__, :observed, make_ref()}

    :ok =
      :telemetry.attach(
        ref,
        [:phoenix, :channel_handled_in],
        &__MODULE__.handle_observations/4,
        %{id: id, path: path, fingerprint: fingerprint, test: self(), ref: ref}
      )

    absolute = Path.join(root, path)
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, content)

    receive do
      {:observed, ^ref} -> :ok
    after
      @timeout ->
        :telemetry.detach(ref)
        flunk("the harness never reported #{path} to the cloud within #{@timeout}ms")
    end

    :telemetry.detach(ref)
    absolute
  end

  @doc "Telemetry handler for `write_file/3`: a manifest carrying the written file arrived."
  def handle_observations([:phoenix, :channel_handled_in], _measure, meta, config) do
    if meta.event == "observations" and copy_id(meta) == config.id and
         Enum.any?(meta.params["observations"] || [], &observed?(&1, config)) do
      send(config.test, {:observed, config.ref})
    end
  end

  # The working copy a channel event belongs to, once its join has assigned one.
  defp copy_id(%{socket: %{assigns: %{harness: %{id: id}}}}), do: id
  defp copy_id(_meta), do: nil

  defp observed?(entry, %{path: path, fingerprint: fingerprint}),
    do: entry["path"] == path and entry["fingerprint"] == fingerprint

  # --- setup ---

  defp refuse_async!(%{async: true}) do
    raise ArgumentError, """
    given_a_live_harness/2 cannot run in an async test.

    The cloud's channel, its decision task and the socket that carries them are
    processes this test does not start and cannot allow before they query, so
    they reach the database through the sandbox's shared mode. An async test
    owns its connection privately and they would see none of it.
    """
  end

  defp refuse_async!(_context), do: :ok

  # What `mix cms.harness.onboard` does: ask the cloud for an id for this
  # checkout, presenting the project's deploy key.
  defp onboard(project, key, device_id, root) do
    ConnTest.build_conn()
    |> Conn.put_req_header("authorization", "Bearer #{key}")
    |> Conn.put_req_header("content-type", "application/json")
    |> ConnTest.dispatch(
      CodeMySpecWeb.Endpoint,
      :post,
      "/api/harnesses",
      Jason.encode!(%{
        project_id: project.id,
        root: root,
        label: "live harness",
        device_id: device_id
      })
    )
    |> ConnTest.json_response(200)
    |> Map.fetch!("working_copy_id")
  end

  defp device_file(device_id) do
    dir = TempFile.dir("live_harness_device")
    File.mkdir_p!(dir)
    file = Path.join(dir, "device.json")
    File.write!(file, Jason.encode!(%{device_id: device_id}))
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    file
  end

  defp listen do
    {:ok, listener} =
      Bandit.start_link(
        plug: CodeMySpecWeb.Endpoint,
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    # Not the test's to take down: the test process exits before `on_exit`
    # runs, and a listener linked to it would close the socket while the
    # harness still serves — which it answers by reconnecting.
    Process.unlink(listener)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    {listener, "http://127.0.0.1:#{port}"}
  end

  # The join and the read model, observed on the cloud side. The read model is
  # the harness's first push after its join reply, so once the channel has
  # handled it the client has marked itself joined — and a hook posted next is
  # answered rather than refused as not connected.
  defp watch_channel(topic, working_copy_id) do
    handler = {__MODULE__, :join, working_copy_id}

    :ok =
      :telemetry.attach_many(
        handler,
        [[:phoenix, :channel_joined], [:phoenix, :channel_handled_in]],
        &__MODULE__.handle_join/4,
        %{topic: topic, id: working_copy_id, test: self()}
      )

    handler
  end

  @doc "Telemetry handler for the join: the channel joined, then served the read model."
  def handle_join([:phoenix, :channel_joined], _measure, meta, config) do
    if meta.socket.topic == config.topic and meta.params["harness_id"] == config.id do
      send(config.test, {:live_harness_joined, config.id, meta.result})
    end
  end

  def handle_join([:phoenix, :channel_handled_in], _measure, meta, config) do
    if meta.event == "read_model" and copy_id(meta) == config.id do
      send(config.test, {:live_harness_ready, config.id})
    end
  end

  defp await_joined(id) do
    receive do
      {:live_harness_joined, ^id, :ok} ->
        :ok

      {:live_harness_joined, ^id, refused} ->
        flunk("the cloud refused the harness's join: #{inspect(refused)}")
    after
      @timeout -> flunk("the harness never joined the cloud within #{@timeout}ms")
    end

    receive do
      {:live_harness_ready, ^id} -> :ok
    after
      @timeout -> flunk("the harness joined but never asked for its read model")
    end
  end

  defp teardown(%{root: root, working_copy_id: id} = live) do
    channel = HarnessRegistry.executor_holder(id)

    :telemetry.detach(live.handler)
    ThousandIsland.stop(live.listener, 1_000)
    await_channel_down(channel)
    LiveHarness.stop_serving(root)
    LiveHarness.restore(live.saved)
  end

  defp await_channel_down({:ok, pid, _instance}) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> raise "the cloud's channel for the live harness outlived its listener"
    end
  end

  defp await_channel_down(:error), do: :ok
end
