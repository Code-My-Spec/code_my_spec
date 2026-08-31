defmodule CmsHarnessTest.FakeServer do
  @moduledoc """
  A CodeMySpec server, reduced to the wire contract the harness depends on.

  Not a mock of the harness's own collaborators — the harness's real Slipstream
  client connects to this over a real websocket and speaks the real protocol.
  What is faked is the far side, and only as far as the contract in
  `CodeMySpecWeb.HarnessProjectChannel`:

    * join `harness_project:<id>`, refusable with `project_in_use`
    * `read_model` → the scanning slice, `story_ids` as a list
    * `observations` → an upsert summary, and an empty manifest is refused
    * `hook_decision` → whatever a test says, including no answer at all
    * `run_analysis` → pushed *to* the harness, naming analyzers to run
    * `analysis_result` → what came back, refusable

  It exists so the disconnection behaviours can be tested against a connection
  that genuinely goes away, rather than against a flag someone set.
  """

  alias CmsHarnessTest.FakeServer

  @doc """
  Start the fake server on `port` and point the harness's config at it.

  Returns the port. Tears itself down at the end of the test.
  """
  def start(opts \\ []) do
    # 0 means "whatever is free". A fixed port made two concurrent test runs on
    # one machine fight over it, and the loser reported `failed to start child:
    # {FakeServer.Endpoint, :http}` against three unrelated tests. That is not a
    # rare race: the harness runs `mix test` as an analyzer, so it happens every
    # time someone runs the suite by hand while the harness is watching.
    port = Keyword.get(opts, :port, 0)

    listen(self())
    put_hook_decision(Keyword.get(opts, :hook_decision, %{"systemMessage" => "ok"}))
    put_skill_reply(Keyword.get(opts, :skill_reply, %{"prompt" => "ok"}))
    :persistent_term.put({__MODULE__, :reject_obs}, nil)
    :persistent_term.put({__MODULE__, :reject_analysis}, nil)
    :persistent_term.put({__MODULE__, :channel}, nil)
    refuse_joins(Keyword.get(opts, :refuse, nil))

    pubsub = ensure_pubsub()

    Application.put_env(:code_my_spec, FakeServer.Endpoint, endpoint_config(port))
    endpoint = start_endpoint()

    # Asked after starting, because until then a requested 0 is not yet a port.
    port = bound_port()

    previous_url = Application.get_env(:code_my_spec, :harness_server_url)
    previous_token = Application.get_env(:code_my_spec, :harness_token)
    Application.put_env(:code_my_spec, :harness_server_url, "http://127.0.0.1:#{port}")
    Application.put_env(:code_my_spec, :harness_token, "test-token")

    # The environment wins over application config in `CmsHarness.Config`, so a
    # developer with CMS_SERVER_URL exported would otherwise have the suite
    # quietly connect to their real server.
    env_url = System.get_env("CMS_SERVER_URL")
    env_token = System.get_env("CMS_TOKEN")
    env_key = System.get_env("CMS_DEPLOY_KEY")
    Enum.each(~w(CMS_SERVER_URL CMS_TOKEN CMS_DEPLOY_KEY), &System.delete_env/1)

    ExUnit.Callbacks.on_exit(fn ->
      restore("CMS_SERVER_URL", env_url)
      restore("CMS_TOKEN", env_token)
      restore("CMS_DEPLOY_KEY", env_key)
      Application.put_env(:code_my_spec, :harness_server_url, previous_url)
      Application.put_env(:code_my_spec, :harness_token, previous_token)
      stop(current_endpoint())
      stop(pubsub)
    end)

    %{port: port, endpoint: endpoint}
  end

  @doc """
  Cut every connection, the way a network drop does — nothing runs on the way
  out.

  Only the endpoint goes; the pubsub it needs is a named singleton and comes
  back up with it.
  """
  def disconnect_everyone(_server \\ nil) do
    stop(current_endpoint())
    :persistent_term.put({__MODULE__, :endpoint}, nil)
    :ok
  end

  defp ensure_pubsub do
    case Phoenix.PubSub.Supervisor.start_link(name: FakeServer.PubSub) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp start_endpoint do
    {:ok, pid} = FakeServer.Endpoint.start_link([])
    :persistent_term.put({__MODULE__, :endpoint}, pid)
    pid
  end

  defp current_endpoint, do: :persistent_term.get({__MODULE__, :endpoint}, nil)

  defp bound_port do
    {:ok, {_ip, port}} = FakeServer.Endpoint.server_info(:http)
    port
  end

  def endpoint_config(port) do
    [
      http: [ip: {127, 0, 0, 1}, port: port],
      server: true,
      adapter: Bandit.PhoenixAdapter,
      secret_key_base: String.duplicate("fake_server_secret", 4),
      pubsub_server: FakeServer.PubSub
    ]
  end

  # --- what the channel consults ---

  def listen(pid), do: :persistent_term.put({__MODULE__, :listener}, pid)
  def listener, do: :persistent_term.get({__MODULE__, :listener}, nil)

  def put_hook_decision(decision), do: :persistent_term.put({__MODULE__, :decision}, decision)
  def hook_decision, do: :persistent_term.get({__MODULE__, :decision}, %{})

  def put_skill_reply(reply), do: :persistent_term.put({__MODULE__, :skill_reply}, reply)
  def skill_reply, do: :persistent_term.get({__MODULE__, :skill_reply}, %{"prompt" => "ok"})

  # Lets a test make the server reject a manifest, the way version skew would.
  def reject_observations(reason), do: :persistent_term.put({__MODULE__, :reject_obs}, reason)
  def observations_rejection, do: :persistent_term.get({__MODULE__, :reject_obs}, nil)

  def refuse_joins(holder), do: :persistent_term.put({__MODULE__, :refuse}, holder)
  def refusal, do: :persistent_term.get({__MODULE__, :refuse}, nil)

  # Lets a test make the server refuse a result, the way an already-closed run
  # or a payload it cannot read would.
  def reject_analysis(reason), do: :persistent_term.put({__MODULE__, :reject_analysis}, reason)
  def analysis_rejection, do: :persistent_term.get({__MODULE__, :reject_analysis}, nil)

  @doc false
  def channel_joined(pid), do: :persistent_term.put({__MODULE__, :channel}, pid)

  @doc """
  Ask the harness to run analyzers, the way the real server does when its stop
  hook finds a source stale.

  `runs` is a list of `%{"run_id" => id, "source" => source, "args" => args}`.
  """
  def request_analysis(runs) do
    case :persistent_term.get({__MODULE__, :channel}, nil) do
      nil -> {:error, :no_channel}
      pid -> send(pid, {:push_run_analysis, runs})
    end
  end

  def notify(message) do
    case listener() do
      nil -> :ok
      pid -> send(pid, message)
    end
  end

  defp stop(nil), do: :ok

  defp stop(pid) do
    if Process.alive?(pid) do
      # Unlinked first: these are started from the test process, and stopping
      # the server must not stop the test.
      Process.unlink(pid)
      Supervisor.stop(pid, :shutdown)
    end
  catch
    :exit, _ -> :ok
  end

  defp restore(_var, nil), do: :ok
  defp restore(var, value), do: System.put_env(var, value)
end

defmodule CmsHarnessTest.FakeServer.ProjectChannel do
  @moduledoc false
  use Phoenix.Channel

  alias CmsHarnessTest.FakeServer

  @impl true
  def join("harness_project:" <> project_id, payload, socket) do
    case FakeServer.refusal() do
      nil ->
        FakeServer.notify({:joined, project_id, payload})
        FakeServer.channel_joined(self())
        {:ok, assign(socket, :project_id, project_id)}

      holder ->
        FakeServer.notify({:join_refused, project_id})
        {:error, %{reason: "project_in_use", held_by: holder}}
    end
  end

  @impl true
  def handle_in("read_model", _payload, socket) do
    FakeServer.notify({:read_model_requested, socket.assigns.project_id})

    {:reply,
     {:ok,
      %{
        "component_by_module" => %{"Demo.Accounts" => "component-1"},
        "component_by_id" => %{"component-1" => %{"module_name" => "Demo.Accounts"}},
        "story_ids" => [42],
        "strict" => true
      }}, socket}
  end

  # Mirrors the real channel: an empty manifest is refused rather than obeyed.
  def handle_in("observations", %{"observations" => []}, socket) do
    {:reply, {:error, %{"reason" => "empty_manifest"}}, socket}
  end

  def handle_in("observations", %{"observations" => observations}, socket) do
    FakeServer.notify({:observations, socket.assigns.project_id, observations})

    case FakeServer.observations_rejection() do
      nil -> reply_accepted(observations, socket)
      reason -> {:reply, {:error, %{"reason" => reason}}, socket}
    end
  end

  def handle_in("module_name", %{"module_name" => name}, socket) do
    FakeServer.notify({:module_name, socket.assigns.project_id, name})
    {:reply, :ok, socket}
  end

  def handle_in("health_route_status", %{"status" => status}, socket) do
    FakeServer.notify({:health_route_status, socket.assigns.project_id, status})
    {:reply, :ok, socket}
  end

  def handle_in("hook_decision", payload, socket) do
    FakeServer.notify({:hook_decision, payload})

    case FakeServer.hook_decision() do
      :no_answer -> {:noreply, socket}
      decision -> {:reply, {:ok, decision}, socket}
    end
  end

  def handle_in("skill_start", payload, socket) do
    FakeServer.notify({:skill_start, payload})

    case FakeServer.skill_reply() do
      :no_answer -> {:noreply, socket}
      reply -> {:reply, {:ok, reply}, socket}
    end
  end

  def handle_in("analysis_result", payload, socket) do
    FakeServer.notify({:analysis_result, socket.assigns.project_id, payload})

    case FakeServer.analysis_rejection() do
      nil -> {:reply, {:ok, %{"run_id" => payload["run_id"], "status" => "completed"}}, socket}
      reason -> {:reply, {:error, %{"reason" => reason}}, socket}
    end
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  # What the real channel replies: the manifest is taken, and reconciled after
  # the reply so a big one cannot hold the channel while a stop decision waits
  # behind it. A fake that still answered with counts would let the harness's
  # old branch keep passing after the real server had stopped sending them.
  defp reply_accepted(observations, socket) do
    {:reply, {:ok, %{"status" => "accepted", "observations" => length(observations)}}, socket}
  end

  @impl true
  def handle_info({:push_run_analysis, runs}, socket) do
    push(socket, "run_analysis", %{"runs" => runs})
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end

defmodule CmsHarnessTest.FakeServer.UserSocket do
  @moduledoc false
  use Phoenix.Socket

  channel("harness_project:*", CmsHarnessTest.FakeServer.ProjectChannel)

  @impl true
  def connect(%{"token" => token}, socket, _info) when is_binary(token) and token != "" do
    {:ok, assign(socket, :token, token)}
  end

  def connect(_params, _socket, _info), do: :error

  @impl true
  def id(_socket), do: nil
end

defmodule CmsHarnessTest.FakeServer.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :code_my_spec

  socket("/socket", CmsHarnessTest.FakeServer.UserSocket,
    websocket: true,
    longpoll: false
  )

  plug(:not_found)

  defp not_found(conn, _), do: Plug.Conn.send_resp(conn, 404, "")
end
