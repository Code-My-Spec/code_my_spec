defmodule CodeMySpecSpex.CodexCloudHelpers do
  @moduledoc """
  Executes the shipped cloud CLI against a controlled external harness HTTP boundary.
  These scenarios exercise the provider client, not installation of a real release or
  the harness's WebSocket transport. Those remain integration QA obligations.
  """
  import ExUnit.Callbacks

  def prepared_cloud(context) do
    base = Path.join(System.tmp_dir!(), "codex-cloud-spex-#{System.unique_integer([:positive])}")
    root = Path.join(base, "target")
    state = Path.join(base, "state")
    File.mkdir_p!(root)
    File.mkdir_p!(state)
    id = Ecto.UUID.generate()

    config = %{
      server_url: "https://cloud.example.test",
      project_id: 123,
      device_id: Ecto.UUID.generate(),
      harness_version: "0.1.0",
      target: "phoenix"
    }

    write_json(Path.join(state, "config.json"), config)

    write_json(Path.join(root, ".cms_harness.json"), %{
      id: id,
      working_copy_id: id,
      project_id: 123,
      root: root
    })

    File.write!(Path.join(root, "mix.exs"), "# Already validated generation target fixture\n")
    File.write!(Path.join(root, "mix.lock"), "%{}\n")
    validation = %{root: root, status: "passed", fingerprint: fingerprint(root)}
    write_json(Path.join(state, "validation.json"), validation)

    observer =
      start_supervised!(
        {Agent,
         fn ->
           %{
             requests: [],
             device_id: config.device_id,
             root: root,
             id: id,
             connected: true,
             watching: true,
             onboarded: true,
             agents: %{},
             initialized: MapSet.new()
           }
         end},
        id: {:cloud_observer, base}
      )

    listener =
      start_supervised!(
        {Bandit,
         [
           plug: {CodeMySpecSpex.CodexCloudBoundary, observer},
           ip: {127, 0, 0, 1},
           port: 0
         ]},
        id: {:cloud_listener, base}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    on_exit(fn ->
      File.rm_rf!(base)
    end)

    Map.merge(context, %{
      cloud_root: root,
      cloud_state: state,
      cloud_observer: observer,
      cloud_url: "http://127.0.0.1:#{port}"
    })
  end

  def cloud_command(context, command, thread \\ nil) do
    script = Path.join([:code.priv_dir(:code_my_spec), "dev_boxes", "codex_cloud.py"])
    env = [{"CODEX_THREAD_ID", thread}] ++ Map.get(context, :cloud_env, [])

    {output, status} =
      System.cmd(
        "python3",
        [
          script,
          command,
          "--root",
          context.cloud_root,
          "--state",
          context.cloud_state,
          "--url",
          context.cloud_url
        ],
        env: env,
        stderr_to_stdout: true
      )

    %{output: output, status: status}
  end

  def fingerprint(root) do
    # Given: produce an already-validated target marker using the runtime's
    # actual fingerprint, rather than reimplementing it in the fixture.
    script = Path.join([:code.priv_dir(:code_my_spec), "dev_boxes", "codex_cloud.py"])

    program =
      "import importlib.util,pathlib,sys; spec=importlib.util.spec_from_file_location('cloud',sys.argv[1]); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module); print(module.fingerprint(pathlib.Path(sys.argv[2])))"

    {output, 0} = System.cmd("python3", ["-B", "-c", program, script, root])
    String.trim(output)
  end

  def ready_validation(context) do
    write_json(Path.join(context.cloud_state, "validation.json"), %{
      root: context.cloud_root,
      status: "passed",
      fingerprint: fingerprint(context.cloud_root)
    })
  end

  def database_boundary(context) do
    bin = Path.join(context.cloud_state, "fake-database-bin")
    File.mkdir_p!(bin)
    # External OS/database boundary, never the cloud runtime itself. No shared
    # postgres user is altered and no real database persistence is claimed.
    for executable <- ~w(psql) do
      file = Path.join(bin, executable)
      File.write!(file, "#!/bin/sh\nexit 0\n")
      File.chmod!(file, 0o700)
    end

    Map.put(context, :cloud_env, [
      {"PATH", bin <> ":" <> System.get_env("PATH")},
      {"CMS_POSTGRES_MODE", "existing"}
    ])
  end

  def boundary_state(context, changes),
    do: Agent.update(context.cloud_observer, &Map.merge(&1, changes))

  def cloud_requests(context), do: Agent.get(context.cloud_observer, &Enum.reverse(&1.requests))
  def write_json(path, data), do: File.write!(path, Jason.encode!(data))
end

defmodule CodeMySpecSpex.CodexCloudBoundary do
  @moduledoc false
  import Plug.Conn
  def init(observer), do: observer

  def call(conn, observer) do
    {:ok, body, conn} = read_body(conn)

    request = %{
      path: conn.request_path,
      body: if(body == "", do: %{}, else: Jason.decode!(body)),
      headers: conn.req_headers
    }

    Agent.update(observer, &Map.update!(&1, :requests, fn requests -> [request | requests] end))
    state = Agent.get(observer, & &1)

    case conn.request_path do
      "/health" ->
        json(conn, %{
          status: "ok",
          device_id: state.device_id,
          projects: [
            %{
              id: state.id,
              working_copy_id: state.id,
              root: state.root,
              connected: state.connected,
              watching: state.watching,
              onboarded: state.onboarded
            }
          ]
        })

      "/mcp" ->
        mcp(conn, request.body, observer)

      _ ->
        if String.ends_with?(conn.request_path, "/hooks/session-start") do
          session = request.body["session_id"]
          agent = "agent-#{session}"
          Agent.update(observer, &put_in(&1, [:agents, agent], session))
          json(conn, %{agent_id: agent, session_id: session})
        else
          send_resp(conn, 404, "unknown boundary route")
        end
    end
  end

  defp mcp(conn, %{"method" => "initialize"} = body, _observer) do
    session = "mcp-#{get_req_header(conn, "x-agent-id") |> List.first()}"

    conn
    |> put_resp_header("mcp-session-id", session)
    |> json(%{
      jsonrpc: "2.0",
      id: body["id"],
      result: %{
        protocolVersion: "2024-11-05",
        capabilities: %{tools: %{}},
        serverInfo: %{name: "external-harness-fixture", version: "1"}
      }
    })
  end

  defp mcp(conn, %{"method" => "notifications/initialized"}, observer) do
    session = get_req_header(conn, "mcp-session-id") |> List.first()

    Agent.update(
      observer,
      &Map.update!(&1, :initialized, fn sessions -> MapSet.put(sessions, session) end)
    )

    send_resp(conn, 202, "")
  end

  defp mcp(conn, %{"method" => "tools/list"} = body, observer) do
    session = get_req_header(conn, "mcp-session-id") |> List.first()

    if Agent.get(observer, &MapSet.member?(&1.initialized, session)) do
      tools =
        Enum.map(
          ~w(start_task evaluate_task run_script tool_docs),
          &%{name: &1, description: &1, inputSchema: %{type: "object"}}
        )

      json(conn, %{jsonrpc: "2.0", id: body["id"], result: %{tools: tools}})
    else
      conn |> put_status(409) |> json(%{error: "Complete the initialized notification first"})
    end
  end

  defp mcp(conn, _, _), do: send_resp(conn, 400, "unsupported fixture request")

  defp json(conn, data),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(conn.status || 200, Jason.encode!(data))
end
