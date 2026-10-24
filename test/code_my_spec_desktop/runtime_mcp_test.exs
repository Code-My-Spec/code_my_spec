defmodule CodeMySpecDesktop.RuntimeMcpTest.Server do
  use Anubis.Server,
    name: "desktop-runtime-mcp-test",
    version: "1.0.0",
    capabilities: [:tools]
end

defmodule CodeMySpecDesktop.RuntimeMcpTest do
  use ExUnit.Case, async: false

  alias CodeMySpec.McpServers.LocalServer
  alias CodeMySpecDesktop.Application.Runtime
  alias __MODULE__.Server

  test "desktop MCP initializes when global Phoenix endpoint serving is disabled" do
    previous = Application.fetch_env(:phoenix, :serve_endpoints)
    flags = Map.new(["PHX_SERVER", "ANUBIS_MCP_SERVER"], &{&1, System.get_env(&1)})

    on_exit(fn ->
      restore_config(previous)
      Enum.each(flags, &restore_flag/1)
    end)

    Application.put_env(:phoenix, :serve_endpoints, false)
    Enum.each(Map.keys(flags), &System.delete_env/1)

    children =
      Runtime.children([
        {LocalServer, transport: :streamable_http, session_idle_timeout: 14_400_000},
        CodeMySpecWeb.Endpoint
      ])

    assert [
             {LocalServer, opts},
             CodeMySpecWeb.Endpoint,
             CmsHarness.Supervisor,
             CodeMySpecDesktop.ProjectSetup
           ] = children

    assert opts[:session_idle_timeout] == 14_400_000

    # Use a separate server identity so the test cannot restart the application's MCP server.
    start_supervised!({Server, opts})

    listener =
      start_supervised!(
        {Bandit,
         plug: {Anubis.Server.Transport.StreamableHTTP.Plug, server: Server},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    response =
      Req.post!("http://127.0.0.1:#{port}/mcp",
        headers: [{"accept", "application/json, text/event-stream"}],
        json: %{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: %{
            protocolVersion: "2024-11-05",
            capabilities: %{},
            clientInfo: %{name: "desktop-regression", version: "1.0.0"}
          }
        },
        decode_body: false
      )

    assert response.status == 200
    assert response.body =~ "protocolVersion"
    assert response.body =~ "desktop-runtime-mcp-test"
    refute response.body =~ "\"error\""
  end

  defp restore_config(:error), do: Application.delete_env(:phoenix, :serve_endpoints)
  defp restore_config({:ok, value}), do: Application.put_env(:phoenix, :serve_endpoints, value)
  defp restore_flag({key, nil}), do: System.delete_env(key)
  defp restore_flag({key, value}), do: System.put_env(key, value)
end
