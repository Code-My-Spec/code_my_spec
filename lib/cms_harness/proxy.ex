defmodule CmsHarness.Proxy do
  @moduledoc """
  HTTPS egress proxy settings shared by harness HTTP requests and its websocket.

  Routing is decided for each destination, so local endpoints and NO_PROXY
  continue to connect directly. The environment is read at request time for
  Req and at dial time for the websocket.
  """

  @loopback ["localhost", "127.0.0.1", "::1"]

  @doc "Install the request step for this harness process, including onboarding."
  def install! do
    defaults = Req.default_options()
    plugins = Keyword.get(defaults, :plugins, [])
    Req.default_options(Keyword.put(defaults, :plugins, Enum.uniq(plugins ++ [__MODULE__])))
  end

  def attach(request), do: Req.Request.prepend_request_steps(request, harness_proxy: &route/1)

  def route(%Req.Request{url: url} = request) do
    case connect_options(url, System.get_env()) do
      [] ->
        request

      options ->
        existing = Req.Request.get_option(request, :connect_options, [])
        Req.Request.put_option(request, :connect_options, Keyword.merge(existing, options))
    end
  end

  @doc "Mint connect options for a destination and an explicit environment map."
  def connect_options(url, env) when is_binary(url), do: connect_options(URI.parse(url), env)

  def connect_options(%URI{scheme: scheme, host: host}, env)
      when scheme in ["https", "wss"] and is_binary(host) and is_map(env) do
    case proxy_for(host, env) do
      nil -> []
      proxy -> proxy_options(proxy, env)
    end
  end

  def connect_options(_url, _env), do: []

  @doc "Slipstream options for a websocket destination."
  def socket_options(url, env \\ System.get_env()) do
    case connect_options(url, env) do
      [] -> []
      options -> [mint_opts: Keyword.put(options, :protocols, [:http1])]
    end
  end

  defp proxy_for(host, env) do
    host = String.downcase(host)
    bypass = Map.get(env, "NO_PROXY") || Map.get(env, "no_proxy") || ""

    excluded? =
      host in @loopback or
        bypass
        |> String.split(",", trim: true)
        |> Enum.any?(fn entry ->
          suffix = entry |> String.trim() |> String.trim_leading(".") |> String.downcase()
          suffix == "*" or host == suffix or String.ends_with?(host, "." <> suffix)
        end)

    if excluded? do
      nil
    else
      case Map.get(env, "HTTPS_PROXY") || Map.get(env, "https_proxy") do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end
  end

  defp proxy_options(value, env) do
    proxy = URI.parse(value)

    unless proxy.scheme in ["http", "https"] and is_binary(proxy.host) and
             proxy.host != "" and is_nil(proxy.userinfo) do
      raise ArgumentError,
            "HTTPS_PROXY must be an HTTP or HTTPS proxy URL without embedded credentials"
    end

    scheme = if proxy.scheme == "http", do: :http, else: :https
    port = proxy.port || if(scheme == :http, do: 80, else: 443)
    options = [proxy: {scheme, proxy.host, port, []}]

    case Map.get(env, "SSL_CERT_FILE") do
      file when is_binary(file) and file != "" ->
        options ++ [transport_opts: [verify: :verify_peer, cacertfile: String.to_charlist(file)]]

      _ ->
        options
    end
  end
end
