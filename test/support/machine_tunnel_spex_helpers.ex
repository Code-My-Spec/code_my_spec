defmodule CodeMySpecSpex.MachineTunnelHelpers do
  @moduledoc """
  Story 1117's shared premise: working copies on machines, a Cloudflare that
  remembers what it was told, and the tools a developer uses to turn a copy's
  address on and off.

  Cloudflare is the one system here we do not run, so it is faked — but with
  state, not canned answers. A tunnel created is a tunnel that exists until it
  is deleted; a route written is on that tunnel until it is removed; a DNS
  record points where it was last pointed. "Exactly one tunnel", "dev keeps its
  hostname" and "nothing left behind" are claims about that state, and a stub
  that answered every request the same way could not tell any of them apart
  from their opposite.

  Copies join the server's real harness channel from a named device, and report
  their app serving the way a harness does (`ensure_app_running_result`). The
  address is turned on and off through the agent tools, and read back off the
  Working Copies page, which is where a developer sees it.
  """

  import ExUnit.Assertions
  require Phoenix.ChannelTest
  # `live/2` falls back to `get/2` when the page is not already a LiveView, so
  # it has to be in scope or the call does not compile.
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest
  import CodeMySpecSpex.WorkingCopyHelpers, only: [join_working_copy_socket: 4]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.OffboardWorkingCopy
  alias CodeMySpec.McpServers.Stories.Tools.ShareCopyApp
  alias CodeMySpec.McpServers.Stories.Tools.UnshareCopyApp
  alias CodeMySpec.Workspaces.PreviewTunnel
  alias Req.Test

  @endpoint CodeMySpecWeb.Endpoint

  # ── Cloudflare ──

  @doc """
  Start a fake Cloudflare for this test and route `PreviewTunnel` to it.

  Shared rather than per-process, because the server reaches Cloudflare from
  whichever process acts — a tool call here, a channel process for a harness.
  The spex case is not async, so one test owns it at a time.

  `fail: true` answers every request with Cloudflare's own failure shape.
  """
  def cloudflare(opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          tunnels: %{},
          deleted: [],
          records: %{},
          history: [],
          next: 1,
          fail: Keyword.get(opts, :fail, false)
        }
      end)

    Test.set_req_test_to_shared()
    ExUnit.Callbacks.on_exit(&Test.set_req_test_to_private/0)
    Test.stub(PreviewTunnel, &respond(&1, agent))
    agent
  end

  @doc """
  A tunnel that already exists before the scenario, carrying `routes` —
  `[{hostname, service}]` — with each hostname's DNS record pointing at it.
  The machine's dev tunnel today is exactly this.
  """
  def existing_tunnel(agent, tunnel_id, routes) do
    ingress = for {host, service} <- routes, do: %{"hostname" => host, "service" => service}

    Agent.update(agent, fn state ->
      records =
        Enum.reduce(routes, state.records, fn {host, _}, records ->
          Map.put(records, "record-#{host}", %{
            name: host,
            content: tunnel_id <> ".cfargotunnel.com"
          })
        end)

      tunnel = %{
        name: tunnel_id,
        config_src: "local",
        ingress: ingress ++ [%{"service" => "http_status:404"}]
      }

      %{state | tunnels: Map.put(state.tunnels, tunnel_id, tunnel), records: records}
    end)
  end

  @doc "Every ingress list written to `tunnel_id`, oldest first."
  def ingress_history(agent, tunnel_id),
    do:
      agent
      |> Agent.get(& &1.history)
      |> Enum.filter(&(elem(&1, 0) == tunnel_id))
      |> Enum.map(&elem(&1, 1))
      |> Enum.reverse()

  @doc "From now on, every Cloudflare request fails."
  def cloudflare_fails(agent), do: Agent.update(agent, &%{&1 | fail: true})

  @doc "The tunnels that exist, as `%{id => %{name, config_src, ingress}}`."
  def tunnels(agent), do: Agent.get(agent, & &1.tunnels)

  @doc "Ids of tunnels that were deleted."
  def deleted_tunnels(agent), do: Agent.get(agent, & &1.deleted)

  @doc "Every `{hostname, service}` route a tunnel holds, catch-all excluded."
  def routes(agent, tunnel_id) do
    agent
    |> tunnels()
    |> Map.get(tunnel_id, %{ingress: []})
    |> Map.fetch!(:ingress)
    |> Enum.filter(& &1["hostname"])
    |> Enum.map(&{&1["hostname"], &1["service"]})
  end

  @doc "The tunnel id a hostname's DNS record points at, or nil."
  def dns_tunnel(agent, host) do
    agent
    |> Agent.get(& &1.records)
    |> Map.values()
    |> Enum.find_value(fn record ->
      record.name == host && String.replace_suffix(record.content, ".cfargotunnel.com", "")
    end)
  end

  @doc "The one tunnel carrying `host`, or nil."
  def tunnel_carrying(agent, host) do
    agent
    |> tunnels()
    |> Enum.find_value(fn {id, tunnel} ->
      Enum.any?(tunnel.ingress, &(&1["hostname"] == host)) && id
    end)
  end

  defp respond(conn, agent) do
    if Agent.get(agent, & &1.fail) do
      Test.json(conn, %{
        "success" => false,
        "errors" => [%{"code" => 10_000, "message" => "Cloudflare is unavailable"}],
        "result" => nil
      })
    else
      route(conn.method, api_path(conn.request_path), conn, agent)
    end
  end

  defp route("POST", ["accounts", _, "cfd_tunnel"], conn, agent) do
    body = json_body(conn)

    id =
      Agent.get_and_update(agent, fn state ->
        id = "tunnel-#{state.next}"

        tunnel = %{name: body["name"], config_src: body["config_src"], ingress: []}
        {id, %{state | next: state.next + 1, tunnels: Map.put(state.tunnels, id, tunnel)}}
      end)

    ok(conn, %{"id" => id, "name" => body["name"]})
  end

  defp route("DELETE", ["accounts", _, "cfd_tunnel", id], conn, agent) do
    Agent.update(agent, fn state ->
      %{state | tunnels: Map.delete(state.tunnels, id), deleted: [id | state.deleted]}
    end)

    ok(conn, %{"id" => id})
  end

  defp route("GET", ["accounts", _, "cfd_tunnel", id, "configurations"], conn, agent) do
    ingress = agent |> tunnels() |> Map.get(id, %{ingress: []}) |> Map.fetch!(:ingress)
    ok(conn, %{"config" => %{"ingress" => ingress}})
  end

  defp route("PUT", ["accounts", _, "cfd_tunnel", id, "configurations"], conn, agent) do
    ingress = json_body(conn)["config"]["ingress"]

    Agent.update(agent, fn state ->
      tunnels =
        Map.update(state.tunnels, id, %{name: nil, config_src: nil, ingress: ingress}, fn t ->
          %{t | ingress: ingress}
        end)

      %{state | tunnels: tunnels, history: [{id, ingress} | state.history]}
    end)

    ok(conn, %{})
  end

  defp route("POST", ["zones", _, "dns_records"], conn, agent) do
    body = json_body(conn)

    taken? =
      agent |> Agent.get(& &1.records) |> Enum.any?(fn {_, r} -> r.name == body["name"] end)

    if taken? do
      Test.json(conn, %{
        "success" => false,
        "errors" => [%{"code" => 81_053, "message" => "record already exists"}],
        "result" => nil
      })
    else
      id =
        Agent.get_and_update(agent, fn state ->
          id = "record-#{state.next}"
          record = %{name: body["name"], content: body["content"]}
          {id, %{state | next: state.next + 1, records: Map.put(state.records, id, record)}}
        end)

      ok(conn, %{"id" => id})
    end
  end

  defp route("GET", ["zones", _, "dns_records"], conn, agent) do
    name = Plug.Conn.fetch_query_params(conn).query_params["name"]

    found =
      for {id, record} <- Agent.get(agent, & &1.records), record.name == name do
        %{"id" => id, "name" => record.name, "content" => record.content}
      end

    ok(conn, found)
  end

  defp route("PATCH", ["zones", _, "dns_records", id], conn, agent) do
    content = json_body(conn)["content"]

    Agent.update(agent, fn state ->
      %{state | records: Map.update!(state.records, id, &%{&1 | content: content})}
    end)

    ok(conn, %{"id" => id})
  end

  defp route("DELETE", ["zones", _, "dns_records", id], conn, agent) do
    Agent.update(agent, fn state -> %{state | records: Map.delete(state.records, id)} end)
    ok(conn, %{"id" => id})
  end

  defp route(method, path, conn, _agent) do
    flunk(
      "the fake Cloudflare has no route for #{method} /#{Enum.join(path, "/")}: " <>
        inspect(conn.request_path)
    )
  end

  # Cloudflare's paths start `/client/v4`; routes are written from after it.
  defp api_path(path) do
    case String.split(path, "/", trim: true) do
      ["client", "v4" | rest] -> rest
      other -> other
    end
  end

  defp ok(conn, result),
    do: Test.json(conn, %{"success" => true, "errors" => [], "result" => result})

  defp json_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end

  # ── Copies on machines ──

  @doc """
  A working copy at `root` on `device_id`, joined over the harness channel and
  reporting its app serving at `app_url`. Answers `%{id, socket, device_id,
  app_url}`.
  """
  def serving_copy(context, root, device_id, app_url) do
    {reply, socket} =
      join_working_copy_socket(context, root, Path.basename(root), device_id: device_id)

    ref =
      Phoenix.ChannelTest.push(socket, "ensure_app_running_result", %{
        "ref" => "spex-1117-#{System.unique_integer([:positive])}",
        "status" => "ok",
        "app_status" => "serving",
        "app_url" => app_url
      })

    Phoenix.ChannelTest.assert_reply(ref, :ok)

    %{
      id: reply.working_copy_id,
      socket: socket,
      device_id: device_id,
      app_url: app_url,
      root: root
    }
  end

  @doc "A copy at `root` on `device_id` whose app is not serving."
  def idle_copy(context, root, device_id) do
    {reply, socket} =
      join_working_copy_socket(context, root, Path.basename(root), device_id: device_id)

    %{id: reply.working_copy_id, socket: socket, device_id: device_id, app_url: nil, root: root}
  end

  @doc "The same copy rejoining, the way a restarted harness does. Answers the join reply."
  def rejoin(context, copy) do
    # A restarted harness's old connection is gone before the new one joins;
    # joining beside it is refused, correctly, as a second harness on the copy.
    channel = copy.socket.channel_pid
    monitor = Process.monitor(channel)
    Process.unlink(channel)
    Phoenix.ChannelTest.close(copy.socket)

    receive do
      {:DOWN, ^monitor, :process, ^channel, _reason} -> :ok
    after
      2_000 -> flunk("the copy's old harness connection did not close")
    end

    {reply, socket} =
      join_working_copy_socket(context, copy.root, Path.basename(copy.root),
        device_id: copy.device_id,
        working_copy_id: copy.id
      )

    {reply, %{copy | socket: socket}}
  end

  @doc "The context re-pointed at another project in the same account."
  def in_project(context, project) do
    scope = %{
      context.scope
      | active_project: project,
        active_project_id: project.id,
        active_working_copy_id: nil
    }

    %{context | project: project, scope: scope}
  end

  @doc "The address a tool reply names."
  def address_in(response) do
    text = CodeMySpecSpex.TaskResponseHelpers.response_text(response)
    [url] = Regex.run(~r{https://[^\s]+}, text) || flunk("the reply named no address: " <> text)
    String.trim_trailing(url, ".")
  end

  @doc "The hostname a copy's address has, whatever the tool replied."
  def address_host(copy), do: "preview-#{copy.id}.codemyspec.com"

  @doc "A machine, announced the way its harness announces itself at boot. Answers its device id."
  def machine(context), do: CodeMySpecSpex.Fixtures.device_fixture(context.scope).id

  # ── The developer's tools ──

  @doc "Turn a copy's address on, as that copy's agent asks to share its app."
  def turn_on(context, copy), do: tool(ShareCopyApp, %{}, as_copy(context, copy))

  @doc "Turn a copy's address off."
  def turn_off(context, copy), do: tool(UnshareCopyApp, %{}, as_copy(context, copy))

  @doc "Offboard a copy, as an operator does."
  def offboard(context, copy),
    do: tool(OffboardWorkingCopy, %{working_copy_id: copy.id}, context.scope)

  defp as_copy(context, copy), do: %{context.scope | active_working_copy_id: copy.id}

  defp tool(module, params, scope) do
    {:reply, response, _frame} = module.execute(params, %Frame{assigns: %{current_scope: scope}})
    response
  end

  @doc "The public address the Working Copies page shows for a copy, or nil when it shows none."
  def shown_address(context, copy) do
    {:ok, _view, html} = live(context.conn, "/app/projects/#{context.project.id}/working-copies")

    html
    |> Floki.parse_document!()
    |> Floki.find("[data-test='working-copy-preview']")
    |> Enum.map(&(&1 |> Floki.attribute("href") |> List.first()))
    |> Enum.find(&(&1 && String.contains?(&1, copy.id)))
  end

  @doc "The host a URL names."
  def host(url), do: URI.parse(url).host
end
