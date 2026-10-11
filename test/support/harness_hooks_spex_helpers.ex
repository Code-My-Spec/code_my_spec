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
  same `/socket` mount, `UserSocket` and channel as production. The listener
  and its port are this context's alone and are stopped on exit.

  ## Isolation, so it runs `async: true`

  Each test has its own listener, checkout and database connection, and sets
  nothing in the application or OS environment.

    * **The database.** The cloud processes on one hook — Bandit's connection
      process, the channel, its decision and reconcile tasks — are none of the
      test's. The test's SQL sandbox metadata rides in the socket's
      `user-agent` (`CmsHarnessTest.ConnectHeaders`, keyed on the checkout's
      root) and `UserSocket.connect/3` allows it, as the endpoint's
      `Phoenix.Ecto.SQL.Sandbox` plug does for HTTP. The channel and its tasks
      inherit the allowance through `$callers`.
    * **The server.** `.cms_harness.json` records the server that minted the
      copy — this listener — and the copy dials that
      (`CmsHarness.Config.server_url_for/1`), not the node's configured one.
    * **The harness side** touches no database, and everything it holds is
      keyed on the checkout's root.

  ## Two working copies

  `setup_active_project` gives the scope a fixture working copy; onboarding
  the live harness mints a second one, and the session a hook opens belongs to
  that one. So the live helpers repoint `context.scope.active_working_copy_id`
  at the harness's copy, and what a spex does with `context.scope` afterwards —
  an MCP tool call, a hook of its own — speaks for the copy its session is on.

  The harness's copy is the project's main copy: onboarding designates a
  project's only checkout with a root as main, and the fixture copy has none.
  A team member holds no story on main, so a scenario about a coder working a
  story asks for `feature: true`, which designates the fixture copy main and
  leaves the harness's a feature checkout beside it.

  A known split: a frame or scope captured *before* the harness started still
  names the fixture copy, and so does copy-scoped state a given recorded then —
  analysis runs, agents, problems. A spex whose premise is that state starts
  the harness first. Spex not yet live keep the fixture copy throughout.
  B1c/B2 remove the fixture copy.

  ## Teardown

  One `on_exit`, registered before the harness starts so a join that fails is
  still cleaned up, and run before the sandbox owner stops. In order: stop the
  listener, so the *cloud* closes the socket (a harness that hangs up first is
  logged at `:error` by the channel as a death); wait for the channel process
  to be gone; stop serving the checkout.
  """

  import ExUnit.Assertions

  alias CmsHarnessTest.LiveHarness
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessReports
  alias Phoenix.ConnTest
  alias Phoenix.Ecto.SQL.Sandbox, as: SQLSandbox
  alias Plug.Conn

  # Waits follow the harness rather than a clock. Each step is awaited in
  # windows; after every quiet window the channel client is asked how it is
  # doing, and only a client that is gone, or has no credential, fails the wait
  # early. A client still dialling, joining or scanning is progressing on a
  # loaded machine, and is waited for until the backstop (57aa576c).
  @window 1_000
  @backstop 60_000

  @mix_exs "defmodule App.MixProject do\n  use Mix.Project\nend\n"

  @doc """
  A checkout of `context.project` on disk, onboarded, served by a real harness
  joined to a listening cloud endpoint.

  Needs `context.scope` and `context.project` (`setup :setup_active_project`).
  Adds `context.harness`: `root`, `working_copy_id`, `deploy_key`, `device_id`
  and `server_url`, and points `context.scope.active_working_copy_id` at the
  harness's copy (see "Two working copies" in the moduledoc).

  Options:

    * `:files` — `%{relative_path => content}` written into the checkout and
      left uncommitted on the template's commit. Give it at least one file the
      scanner tracks: a harness whose scan finds nothing refuses to send it.
    * `:feature` — `true` makes this checkout a feature copy, with the scope's
      fixture copy designated main (see "Two working copies").
  """
  @spec given_a_live_harness(map(), keyword()) :: map()
  def given_a_live_harness(context, opts \\ []) do
    %{scope: scope, project: project} = context
    key = "dk_live_#{System.unique_integer([:positive])}"
    _project = Fixtures.set_project_deploy_key(scope, project, key)
    device = Fixtures.device_fixture(scope)
    {listener, url} = listen()

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
        deploy_key: key,
        server_url: url
      })

    topic = "harness_project:#{project.id}"
    handler = watch_channel(topic, working_copy_id)

    ExUnit.Callbacks.on_exit(fn ->
      teardown(%{
        root: root,
        working_copy_id: working_copy_id,
        listener: listener,
        handler: handler
      })
    end)

    :ok = LiveHarness.serve(root, sandbox_user_agent())
    await_joined(working_copy_id, root, handler)

    if Keyword.get(opts, :feature, false),
      do: :ok = Fixtures.designate_main(scope, scope.active_working_copy_id)

    scope = %{scope | active_working_copy_id: working_copy_id}
    :ok = keep_fixture_files(working_copy_id, Map.get(context, :environment))

    context
    |> Map.put(:harness, %{
      root: root,
      working_copy_id: working_copy_id,
      topic: topic,
      deploy_key: key,
      device_id: device.id,
      server_url: url
    })
    |> Map.put(:scope, scope)
  end

  # The fixture's files stay in its in-memory runtime: the server reads that for
  # the harness's copy, never the checkout on disk.
  defp keep_fixture_files(_working_copy_id, nil), do: :ok

  defp keep_fixture_files(working_copy_id, env) do
    :ok = Environments.unregister({:working_copy, working_copy_id})
    Environments.register({:working_copy, working_copy_id}, env)
  end

  @doc """
  `context` with a live harness: the one it already has, or one started now.

  A new checkout holds what `context.environment` holds, so the files earlier
  givens seeded in memory (and synced) are on the disk the hook path reads, and
  in the manifest its File rows come from. Files written to the environment
  after this are the caller's to put on disk, with `write_file/3`.
  """
  @spec ensure_live_harness(map(), keyword()) :: map()
  def ensure_live_harness(context, opts \\ [])
  def ensure_live_harness(%{harness: %{}} = context, _opts), do: context

  def ensure_live_harness(context, opts) do
    files = checkout_files(Map.get(context, :environment))
    given_a_live_harness(context, Keyword.put(opts, :files, files))
  end

  # A mix.exs, as every checkout has: the scan has to find something, and a
  # project whose environment is still empty would otherwise give it nothing.
  defp checkout_files(%Environment{type: :memory} = env) do
    env
    |> Environments.glob("**/*")
    |> Enum.reject(&(String.starts_with?(&1, "/") or String.starts_with?(&1, "\0")))
    |> Map.new(fn path -> {path, read!(env, path)} end)
    |> Map.put_new("mix.exs", @mix_exs)
  end

  defp checkout_files(_environment), do: %{"mix.exs" => @mix_exs}

  defp read!(env, path) do
    {:ok, content} = Environments.read_file(env, path)
    content
  end

  @doc """
  A Claude Code session opened on the live harness: `session-start` for a fresh
  session id, posted through the harness `ensure_live_harness/1` gives the
  context. Answers `{context, session_id}`.
  """
  @spec open_session(map()) :: {map(), String.t()}
  def open_session(context) do
    context = ensure_live_harness(context)
    session_id = "spex-#{System.unique_integer([:positive])}"

    case post_hook(context, "session-start", %{"session_id" => session_id}) do
      %{"status" => "active"} -> {context, session_id}
      refused -> flunk("session-start did not open the session: #{inspect(refused)}")
    end
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

  The harness is asked to scan now — what its watcher does once its debounce
  lapses — rather than waited on for the debounce. A client that is not joined
  at that moment ignores the request and rescans everything when it rejoins,
  which reports the file just the same.

  A path the scanner does not classify is never in a manifest, so it is put on
  disk and not waited for.

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

    if HarnessReports.scanned?(path) do
      :ok = LiveHarness.sync_now(root)

      try do
        await_step(ref, :observed, root, "the harness never reported #{path} to the cloud")
      after
        :telemetry.detach(ref)
      end
    else
      :telemetry.detach(ref)
    end

    absolute
  end

  @doc """
  An analyzer run on this copy that has finished, landed the way production
  lands one: a run opened in the ledger, then its result reported by the
  harness over its socket (`analysis_result`) and converted and reconciled by
  the cloud on the harness's copy. Returns once the cloud has announced the
  run finished, with its status.

  `recording` is the tool's own output for the run, or `nil` for a clean run.
  See `CodeMySpecSpex.HarnessReports.result/3`.

  This is what a spex uses to say "the compiler found this": a stop never
  starts or ingests analysis, so findings are landed as a run first.
  """
  @spec land_analysis(map(), String.t(), String.t() | nil) :: atom()
  def land_analysis(%{harness: %{root: root}, scope: scope} = context, source, recording \\ nil) do
    run = Fixtures.start_analysis_run(scope, source)
    topic = "analysis:#{context.project.id}"
    :ok = Phoenix.PubSub.subscribe(CodeMySpec.PubSub, topic)

    try do
      :ok =
        LiveHarness.deliver_analysis_result(
          root,
          run.id,
          source,
          HarnessReports.result(root, source, recording)
        )

      await_run(run.id, root, now() + @backstop)
    after
      Phoenix.PubSub.unsubscribe(CodeMySpec.PubSub, topic)
    end
  end

  defp await_run(run_id, root, deadline) do
    receive do
      {:analysis, %{run_id: ^run_id, status: status}} -> status
    after
      @window ->
        case {client_progress(root), now() < deadline} do
          {:progressing, true} ->
            await_run(run_id, root, deadline)

          {:progressing, false} ->
            flunk("run #{run_id}'s result never landed in #{@backstop}ms; #{client_state(root)}")

          {{:stuck, why}, _in_time} ->
            flunk("run #{run_id}'s result never landed: #{why}; #{client_state(root)}")
        end
    end
  end

  @doc """
  The harness's analysis queue begins `run`: reported over its socket as
  `analysis_started`, as the queue reports it when a run gets its slot.
  Returns once the cloud's channel has recorded the start.
  """
  @spec start_analysis(map(), map()) :: :ok
  def start_analysis(%{harness: %{root: root, working_copy_id: id}}, %{id: run_id, source: source}) do
    ref = {__MODULE__, :started, make_ref()}

    :ok =
      :telemetry.attach(
        ref,
        [:phoenix, :channel_handled_in],
        &__MODULE__.handle_started/4,
        %{id: id, run_id: run_id, test: self(), ref: ref}
      )

    :ok = LiveHarness.deliver_analysis_started(root, run_id, source, String.duplicate("a", 40))

    try do
      await_step(ref, :handled, root, "the harness never reported run #{run_id} starting")
    after
      :telemetry.detach(ref)
    end

    :ok
  end

  @doc "Telemetry handler for `start_analysis/2`: the cloud recorded a run's start."
  def handle_started([:phoenix, :channel_handled_in], _measure, meta, config) do
    if meta.event == "analysis_started" and copy_id(meta) == config.id and
         meta.params["run_id"] == config.run_id do
      send(config.test, {:live_harness, config.ref, :handled, :ok})
    end
  end

  @doc """
  An agent the live harness runs ends its turn: the harness reports
  `turn_ended` over its socket, and the cloud decides that agent's stop with
  the harness's scope — the path an agent under Alloy takes, with no hook.
  Returns once the cloud's channel has handled the event; what the agent is
  sent arrives through the agent transport the scenario installed.
  """
  @spec end_turn(map(), String.t()) :: :ok
  def end_turn(%{harness: %{root: root, working_copy_id: id}, scope: scope}, agent_id) do
    ref = {__MODULE__, :turn_ended, make_ref()}

    :ok =
      :telemetry.attach(
        ref,
        [:phoenix, :channel_handled_in],
        &__MODULE__.handle_turn_event/4,
        %{id: id, agent_id: agent_id, test: self(), ref: ref}
      )

    :ok = LiveHarness.end_turn(root, agent_id, Fixtures.mailbox_turn_end(scope, agent_id))

    try do
      await_step(ref, :handled, root, "the harness never reported #{agent_id}'s turn ending")
    after
      :telemetry.detach(ref)
    end

    :ok
  end

  @doc "Telemetry handler for `end_turn/2`: the cloud handled the agent's turn event."
  def handle_turn_event([:phoenix, :channel_handled_in], _measure, meta, config) do
    if meta.event == "agent_turn_event" and copy_id(meta) == config.id and
         meta.params["agent_id"] == config.agent_id do
      send(config.test, {:live_harness, config.ref, :handled, :ok})
    end
  end

  @doc """
  Run `trigger`, which asks this copy's harness to rescan, and return once the
  manifest it sends has been handled by the cloud.

  Switching a copy on asks for a rescan (`Agents.set_working_copy_loop`), and
  the manifest lands later over the socket and wakes the copy's agents through
  the graph. A scenario that goes on before it has landed has a wake from its
  own setup arriving in the middle of the step it is measuring (74870eb6).

  Reconciled inline under test, so the handled event means the rows are
  written; settle the graph after this to run the wake it causes.
  """
  @spec await_manifest(map(), (-> any())) :: :ok
  def await_manifest(%{harness: %{root: root, working_copy_id: id}}, trigger)
      when is_function(trigger, 0) do
    ref = {__MODULE__, :manifest, make_ref()}

    :ok =
      :telemetry.attach(
        ref,
        [:phoenix, :channel_handled_in],
        &__MODULE__.handle_manifest/4,
        %{id: id, test: self(), ref: ref}
      )

    try do
      trigger.()
      await_step(ref, :manifest, root, "the harness never sent the manifest its rescan asked for")
    after
      :telemetry.detach(ref)
    end

    :ok
  end

  @doc "Telemetry handler for `await_manifest/2`: any manifest from this copy arrived."
  def handle_manifest([:phoenix, :channel_handled_in], _measure, meta, config) do
    if meta.event == "observations" and copy_id(meta) == config.id do
      send(config.test, {:live_harness, config.ref, :manifest, :ok})
    end
  end

  @doc "Telemetry handler for `write_file/3`: a manifest carrying the written file arrived."
  def handle_observations([:phoenix, :channel_handled_in], _measure, meta, config) do
    if meta.event == "observations" and copy_id(meta) == config.id and
         Enum.any?(meta.params["observations"] || [], &observed?(&1, config)) do
      send(config.test, {:live_harness, config.ref, :observed, :ok})
    end
  end

  # The working copy a channel event belongs to, once its join has assigned one.
  defp copy_id(%{socket: %{assigns: %{harness: %{id: id}}}}), do: id
  defp copy_id(_meta), do: nil

  defp observed?(entry, %{path: path, fingerprint: fingerprint}),
    do: entry["path"] == path and entry["fingerprint"] == fingerprint

  # --- setup ---

  # This test's connection, as `Phoenix.Ecto.SQL.Sandbox` encodes it for a
  # client to send back. Not trapping exits: the process it is applied to is
  # the socket's transport, whose exit handling is Phoenix's.
  defp sandbox_user_agent do
    CodeMySpec.Repo
    |> SQLSandbox.metadata_for(self(), trap_exit: false)
    |> SQLSandbox.encode_metadata()
  end

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

  # The join, the read model and the first manifest, observed on the cloud
  # side. The read model is the harness's first push after its join reply, so
  # once the channel has handled it the client has marked itself joined — and
  # a hook posted next is answered rather than refused as not connected. Its
  # reply starts the first scan, whose manifest is waited for too: reconciled
  # after the givens that follow, it lands under them — on results a spex has
  # just landed, among other things.
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

  @doc """
  Telemetry handler for the join: the channel joined, served the read model,
  then handled the manifest of the harness's first scan.
  """
  def handle_join([:phoenix, :channel_joined], _measure, meta, config) do
    if meta.socket.topic == config.topic and meta.params["harness_id"] == config.id do
      send(config.test, {:live_harness, config.id, :joined, meta.result})
    end
  end

  def handle_join([:phoenix, :channel_handled_in], _measure, meta, config) do
    if copy_id(meta) == config.id do
      case meta.event do
        "read_model" -> send(config.test, {:live_harness, config.id, :ready, :ok})
        "observations" -> send(config.test, {:live_harness, config.id, :scanned, :ok})
        _other -> :ok
      end
    end
  end

  defp await_joined(id, root, handler) do
    case await_step(id, :joined, root, "the harness never joined the cloud") do
      :ok ->
        :ok

      refused ->
        flunk("the cloud refused the harness's join: #{inspect(refused)}; #{client_state(root)}")
    end

    await_step(id, :ready, root, "the harness joined but never asked for its read model")
    await_step(id, :scanned, root, "the harness joined but never sent its first manifest")
    :telemetry.detach(handler)
    :ok
  end

  # One step of a live harness, awaited while its channel client is still
  # getting there. `key` is the copy id or a write's ref.
  defp await_step(key, step, root, what),
    do: await_step(key, step, root, what, now() + @backstop)

  defp await_step(key, step, root, what, deadline) do
    receive do
      {:live_harness, ^key, ^step, result} -> result
    after
      @window ->
        case {client_progress(root), now() < deadline} do
          {:progressing, true} ->
            await_step(key, step, root, what, deadline)

          {:progressing, false} ->
            flunk("#{what} in #{@backstop}ms, though it kept trying; #{client_state(root)}")

          {{:stuck, why}, _in_time} ->
            flunk("#{what}: #{why}; #{client_state(root)}")
        end
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # Whether the client can still get there: alive, and holding a credential.
  # A climbing reconnect or a lease still held by a channel on its way out is
  # progress; a client that is gone or has nothing to connect with is not.
  defp client_progress(root) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [] ->
        {:stuck, "no channel client is running"}

      [{pid, _}] ->
        case :sys.get_state(pid, 2_000) do
          %{assigns: %{no_credential?: true}} -> {:stuck, "the client has no credential"}
          _state -> :progressing
        end
    end
  catch
    :exit, reason -> {:stuck, "the channel client did not answer (#{inspect(reason)})"}
  end

  # What the harness's own channel client says about itself, so a join that
  # never happens names its cause — no process, a climbing reconnect, a refusal,
  # no credential — instead of only the time it took (57aa576c).
  defp client_state(root) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [] ->
        "no channel client is running for #{root} (never started, or it crashed)"

      [{pid, _}] ->
        case :sys.get_state(pid, 2_000) do
          %{assigns: assigns} ->
            "channel client: " <>
              inspect(Map.take(assigns, [:joined, :attempts, :refused, :no_credential?, :topic]))

          other ->
            "channel client state: #{inspect(other, limit: 20)}"
        end
    end
  catch
    :exit, reason -> "channel client did not answer (#{inspect(reason)})"
  end

  defp teardown(%{root: root, working_copy_id: id} = live) do
    channel = HarnessRegistry.executor_holder(id)

    :telemetry.detach(live.handler)
    ThousandIsland.stop(live.listener, 1_000)
    await_channel_down(channel)
    LiveHarness.stop_serving(root)
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
