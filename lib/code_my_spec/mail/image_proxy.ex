defmodule CodeMySpec.Mail.ImageProxy do
  @moduledoc """
  Server-side proxy for remote images referenced by inbound email HTML.

  Email bodies link images on arbitrary sender CDNs. Rendering them inline would
  both trip the app's `img-src` CSP and leak the reader's IP / "email opened"
  signal to the sender (tracking pixels). So instead we rewrite every remote
  `<img src>` to a same-origin `/app/mail/image?u=<token>` URL: the browser asks
  our server, our server fetches the bytes and streams them back. CSP stays
  tight, and the sender only ever sees our server.

  The `u` token is HMAC-signed with the endpoint secret (`Phoenix.Token`), so
  the proxy will only fetch URLs we ourselves minted from real email HTML — it
  is not an open proxy. On top of that, `fetch/1` refuses non-HTTP(S) schemes
  and hosts that resolve to private/loopback/link-local space, caps the body
  size, and only serves `image/*` responses.
  """

  @salt "mail-image-proxy"
  @max_age 60 * 60 * 24 * 7
  @max_bytes 10_000_000
  @timeout 6_000

  @doc "Same-origin proxy path for a remote image URL (signed)."
  @spec signed_path(String.t()) :: String.t()
  def signed_path(url) when is_binary(url) do
    token = Phoenix.Token.sign(endpoint(), @salt, url)
    "/app/mail/image?u=" <> URI.encode_www_form(token)
  end

  @doc "Recover the original URL from a proxy token, or `:error`."
  @spec verify(String.t()) :: {:ok, String.t()} | :error
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(endpoint(), @salt, token, max_age: @max_age) do
      {:ok, url} when is_binary(url) -> {:ok, url}
      _ -> :error
    end
  end

  @doc """
  Fetch an image's bytes. Returns `{:ok, content_type, body}` or `{:error, _}`.
  Rejects private hosts, non-image responses, and oversized bodies.
  """
  @spec fetch(String.t()) :: {:ok, String.t(), binary()} | {:error, term()}
  def fetch(url) when is_binary(url) do
    with :ok <- safe_url?(url),
         {:ok, resp} <- request(url),
         :ok <- ok_status(resp),
         {:ok, ct} <- image_content_type(resp),
         :ok <- within_size(resp.body) do
      {:ok, ct, IO.iodata_to_binary(resp.body)}
    end
  end

  # --- fetch internals ---

  defp request(url) do
    opts =
      [
        url: url,
        method: :get,
        max_retries: 0,
        redirect: true,
        max_redirects: 3,
        receive_timeout: @timeout,
        connect_options: [timeout: @timeout],
        decode_body: false
      ]
      |> Keyword.merge(plug_opt())

    Req.request(opts)
  end

  defp ok_status(%{status: status}) when status in 200..299, do: :ok
  defp ok_status(%{status: status}), do: {:error, {:status, status}}

  defp image_content_type(resp) do
    case resp.headers |> header("content-type") |> List.first() do
      ct when is_binary(ct) ->
        base = ct |> String.split(";") |> List.first() |> String.trim() |> String.downcase()
        if String.starts_with?(base, "image/"), do: {:ok, base}, else: {:error, :not_an_image}

      _ ->
        {:error, :no_content_type}
    end
  end

  defp header(headers, key) when is_map(headers), do: Map.get(headers, key, [])

  defp header(headers, key) when is_list(headers) do
    for {k, v} <- headers, String.downcase(k) == key, do: v
  end

  defp within_size(body) do
    if IO.iodata_length(body) <= @max_bytes, do: :ok, else: {:error, :too_large}
  end

  # --- SSRF guard ---

  defp safe_url?(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] -> {:error, :bad_scheme}
      is_nil(uri.host) or uri.host == "" -> {:error, :no_host}
      private_host?(uri.host) -> {:error, :private_host}
      true -> :ok
    end
  end

  # Reject obvious internal targets and any host that resolves into private,
  # loopback or link-local space (blocks `http://10.x`, metadata IPs, and names
  # that point at them).
  defp private_host?(host) do
    host = String.downcase(host)

    cond do
      host in ~w(localhost metadata.google.internal) -> true
      String.ends_with?(host, ".localhost") -> true
      true -> resolves_private?(host)
    end
  end

  defp resolves_private?(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      # An IP literal — check it directly (works offline).
      {:ok, ip} ->
        private_ip?(ip)

      # A hostname — resolve it, unless a test plug is short-circuiting the
      # actual fetch (then there's no real request to protect).
      {:error, _} ->
        resolves_private_hostname?(charlist)
    end
  end

  defp resolves_private_hostname?(charlist) do
    if plug_opt() == [] do
      case :inet.getaddrs(charlist, :inet) do
        {:ok, addrs} -> Enum.any?(addrs, &private_ip?/1)
        # Fail closed on unresolvable hosts.
        {:error, _} -> true
      end
    else
      false
    end
  end

  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b in 16..31, do: true
  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?(_), do: false

  defp endpoint, do: CodeMySpecWeb.Endpoint

  defp plug_opt do
    case Application.get_env(:code_my_spec, __MODULE__, []) |> Keyword.get(:plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
