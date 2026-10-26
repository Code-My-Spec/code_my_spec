defmodule CmsHarness.ProxyTest do
  use ExUnit.Case, async: true

  alias CmsHarness.Proxy

  @remote "https://api.codemyspec.com/api/devices/token"

  test "only remote HTTPS destinations use HTTPS_PROXY" do
    env = %{"HTTPS_PROXY" => "http://127.0.0.1:46323"}
    assert [proxy: {:http, "127.0.0.1", 46_323, []}] = Proxy.connect_options(@remote, env)
    assert [] == Proxy.connect_options(@remote, %{})
    assert [] == Proxy.connect_options("http://api.codemyspec.com/health", env)
    assert [] == Proxy.connect_options("https://localhost/health", env)
    assert [] == Proxy.connect_options("https://127.0.0.1/health", env)
    assert [] == Proxy.connect_options("https://[::1]/health", env)
  end

  test "lowercase proxy and NO_PROXY suffixes bypass exact hosts and subdomains" do
    env = %{
      "https_proxy" => "https://proxy.example",
      "no_proxy" => "localhost,.example.com,other.test"
    }

    assert [] == Proxy.connect_options("https://example.com", env)
    assert [] == Proxy.connect_options("https://api.example.com", env)
    assert [] == Proxy.connect_options("https://other.test", env)

    assert [proxy: {:https, "proxy.example", 443, []}] =
             Proxy.connect_options("https://notexample.com", env)

    assert [] == Proxy.connect_options(@remote, Map.put(env, "NO_PROXY", "*"))
  end

  test "CA bundle is used only on proxied connections" do
    env = %{"HTTPS_PROXY" => "http://proxy.example:8080", "SSL_CERT_FILE" => "/tmp/test-ca.pem"}

    assert [
             proxy: {:http, "proxy.example", 8080, []},
             transport_opts: [verify: :verify_peer, cacertfile: ~c"/tmp/test-ca.pem"]
           ] =
             Proxy.connect_options(@remote, env)

    assert [] == Proxy.connect_options(@remote, Map.put(env, "NO_PROXY", "*"))
    assert [proxy: _] = Proxy.connect_options(@remote, Map.delete(env, "SSL_CERT_FILE"))
  end

  test "invalid proxy scheme and credentials raise before a connection" do
    for value <- ["socks5://proxy.example:1080", "http://user:pass@proxy.example"] do
      assert_raise ArgumentError, ~r/HTTPS_PROXY must be an HTTP or HTTPS proxy URL/, fn ->
        Proxy.connect_options(@remote, %{"HTTPS_PROXY" => value})
      end
    end
  end

  test "websocket uses HTTP/1 through the same proxy" do
    env = %{"HTTPS_PROXY" => "http://proxy.example:8080"}

    assert [mint_opts: options] =
             Proxy.socket_options("wss://api.codemyspec.com/socket/websocket", env)

    assert options[:proxy] == {:http, "proxy.example", 8080, []}
    assert options[:protocols] == [:http1]
    assert [] == Proxy.socket_options("ws://api.codemyspec.com/socket/websocket", env)
  end

  test "Req plugin routes a stubbed HTTPS request without opening a socket" do
    request = Req.new(url: @remote, plug: fn conn -> Req.Test.json(conn, %{ok: true}) end)
    assert {:ok, %{status: 200}} = request |> Proxy.attach() |> Req.request()
  end
end
