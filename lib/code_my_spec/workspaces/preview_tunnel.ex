defmodule CodeMySpec.Workspaces.PreviewTunnel do
  @moduledoc """
  A named Cloudflare tunnel per working copy, so a preview reaches an app we
  are not running.

  `PreviewAddress` is the other half of this and covers the case where *we*
  host the app: it points `preview-{id}` at our own listener, which proxies to
  a container on our machine. That only works while the app is somewhere our
  proxy can dial. A checkout on a developer's laptop, behind a router, on a
  network we have never heard of, is not.

  A tunnel inverts the connection. `cloudflared` runs inside the app's own
  process tree and dials *out* to Cloudflare, so the address resolves to an
  edge that already holds an open connection back to the app. Nothing has to
  reach in, and nothing about where the app runs has to be known here.

  ## Why the address is still ours

  It would be simpler to let each app pick its own hostname, and every part of
  the surrounding system would break. `PreviewProxy` recognises a preview by the
  `preview-` prefix on our zone; `PreviewAddress.csp_origin/0` derives the
  frame-src policy from the same base domain, so an address outside it is
  refused by the browser and the pane renders blank; and the same-site property
  that keeps Safari from dropping the framed app's session cookie holds only
  while the preview shares a registrable domain with the page framing it.

  So: our zone, our record, our prefix — and a tunnel underneath instead of a
  proxy.

  ## The secret is returned once

  Cloudflare generates the tunnel and hands back its secret at creation and
  never again. There is no endpoint that re-reads it. That makes it unlike
  every other credential here: it cannot be re-fetched on demand, so it is
  stored on the working copy, encrypted, and a copy that has one is never asked
  to make a second.

  Losing it does not corrupt anything — it strands a tunnel that can only be
  deleted and replaced. `ensure/1` is therefore idempotent on the *stored*
  credential rather than on what Cloudflare reports, because "a tunnel with
  this name exists" is not the same as "we can still speak for it".
  """

  require Logger

  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy
  alias CodeMySpec.Workspaces.PreviewAddress

  @api "https://api.cloudflare.com/client/v4"

  @typedoc """
  What `ClientUtils.CloudflareTunnel` needs to run in named mode. The key names
  match its options deliberately: this is handed to a checkout to put in its
  config, and a translation step between here and there is somewhere for the
  two to drift apart.
  """
  @type credentials :: %{
          hostname: String.t(),
          tunnel_id: String.t(),
          account_tag: String.t(),
          tunnel_secret: String.t()
        }

  @doc """
  The tunnel serving this working copy's preview, making it exist if it does
  not.

  Returns everything the checkout needs to run it, and records the address on
  the working copy so the panel has something to frame.

  Idempotent: a copy that already holds a tunnel gets the same one back, and
  the DNS record is re-asserted rather than assumed — a record deleted by hand
  in the dashboard should heal on the next call rather than stay broken until
  somebody notices the frame is blank.
  """
  @spec ensure(WorkingCopy.t()) :: {:ok, credentials()} | {:error, term()}
  def ensure(%WorkingCopy{main: false}), do: {:error, :not_the_main_copy}

  def ensure(%WorkingCopy{} = copy) do
    # Checked here as well as in `record_preview_tunnel/2`, and the order is the
    # whole point. Refusing only at the write would create the tunnel and the
    # DNS record first and reject them afterwards — leaving a real tunnel in the
    # account that nothing holds the secret for and no code path will ever
    # mention again. The write's refusal guards the row; this one guards the
    # account.
    with {:ok, account} <- account_id(),
         {:ok, tunnel} <- tunnel_for(copy, account),
         host = PreviewAddress.host(copy.id),
         :ok <- point(host, tunnel.tunnel_id),
         {:ok, _copy} <- record(copy, host, tunnel) do
      {:ok, Map.merge(tunnel, %{hostname: host, account_tag: account})}
    end
  end

  # A stored credential wins over anything Cloudflare would say. See the
  # moduledoc: the API can confirm a tunnel exists and cannot give us back the
  # secret, so a tunnel we can name but not speak for is worth less than none.
  defp tunnel_for(%WorkingCopy{preview_tunnel_id: id, preview_tunnel_secret: secret}, _account)
       when is_binary(id) and id != "" and is_binary(secret) and secret != "" do
    {:ok, %{tunnel_id: id, tunnel_secret: secret}}
  end

  defp tunnel_for(%WorkingCopy{} = copy, account), do: create(copy, account)

  # 32 bytes, base64, generated here rather than left to Cloudflare. Supplying
  # it is what makes `config_src: "local"` possible — the tunnel is configured
  # by the credentials file the checkout holds, not by a dashboard record we
  # would then have to keep in step with the app's own port.
  defp create(%WorkingCopy{} = copy, account) do
    secret = 32 |> :crypto.strong_rand_bytes() |> Base.encode64()

    body = %{
      name: "preview-" <> copy.id,
      tunnel_secret: secret,
      config_src: "local"
    }

    case post("#{@api}/accounts/#{account}/cfd_tunnel", body) do
      {:ok, %{"result" => %{"id" => id}}} ->
        {:ok, %{tunnel_id: id, tunnel_secret: secret}}

      {:ok, body} ->
        {:error, {:cloudflare, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The CNAME every named tunnel is reached through. `proxied: true` is not
  # optional here the way it is for an ordinary record: an unproxied CNAME to
  # `cfargotunnel.com` does not resolve at all, because the target only exists
  # inside Cloudflare's edge.
  defp point(host, tunnel_id) do
    with {:ok, token} <- token(),
         {:ok, zone} <- zone_id() do
      body = %{
        type: "CNAME",
        name: host,
        content: tunnel_id <> ".cfargotunnel.com",
        proxied: true,
        ttl: 1
      }

      "#{@api}/zones/#{zone}/dns_records"
      |> post(body, token)
      |> interpret_record(host)
    end
  end

  # An existing record is success. The address is stable for the life of the
  # working copy, so every call after the first finds what the first one wrote —
  # 81053 and 81057 are the two ways Cloudflare says so.
  defp interpret_record({:ok, %{"errors" => errors}}, host) when is_list(errors) do
    if Enum.any?(errors, &(&1["code"] in [81_053, 81_057])) do
      :ok
    else
      Logger.warning("[PreviewTunnel] #{host} could not be pointed: #{inspect(errors)}")
      {:error, {:cloudflare, errors}}
    end
  end

  defp interpret_record({:ok, _body}, _host), do: :ok
  defp interpret_record({:error, reason}, _host), do: {:error, reason}

  defp record(copy, host, tunnel) do
    WorkingCopies.record_preview_tunnel(copy, %{
      preview_url: PreviewAddress.url(copy.id),
      preview_tunnel_id: tunnel.tunnel_id,
      preview_tunnel_secret: tunnel.tunnel_secret,
      hostname: host
    })
  end

  defp post(url, body, token \\ nil) do
    with {:ok, token} <- if(token, do: {:ok, token}, else: token()) do
      [
        url: url,
        headers: [{"authorization", "Bearer " <> token}],
        json: body,
        retry: false,
        receive_timeout: 10_000
      ]
      |> Keyword.merge(req_options())
      |> Req.post()
      |> body_of()
    end
  end

  defp body_of({:ok, %Req.Response{body: body}}) when is_map(body), do: {:ok, body}
  defp body_of({:ok, %Req.Response{status: status, body: body}}), do: {:error, {status, body}}
  defp body_of({:error, reason}), do: {:error, reason}

  # Our own credential, not the customer's — same reasoning as
  # `PreviewAddress.put_record/1`. This zone is ours, and a visitor who has
  # never connected Cloudflare still gets a preview.
  defp token do
    present(config()[:token] || app_cloudflare()[:api_token], :no_cloudflare_token)
  end

  defp zone_id do
    present(config()[:zone_id] || preview_address_config()[:zone_id], :no_zone_id)
  end

  # The one value `PreviewAddress` never needed: a DNS record is written against
  # a zone, a tunnel is created against an account.
  defp account_id do
    present(config()[:account_id] || app_cloudflare()[:account_id], :no_cloudflare_account_id)
  end

  defp present(value, reason) when value in [nil, ""], do: {:error, reason}
  defp present(value, _reason), do: {:ok, value}

  # Pinned in test config so the suite cannot reach Cloudflare. An unpinned
  # plug plus a real token in the environment is a live call, which this
  # project has shipped once already.
  defp req_options, do: config()[:req_options] || []

  defp app_cloudflare,
    do: Application.get_env(:code_my_spec, CodeMySpec.Content.CloudflareClient, [])

  defp preview_address_config,
    do: Application.get_env(:code_my_spec, PreviewAddress, [])

  defp config, do: Application.get_env(:code_my_spec, __MODULE__, [])
end
