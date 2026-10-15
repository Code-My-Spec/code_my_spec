defmodule CodeMySpec.Workspaces.PreviewTunnel do
  @moduledoc """
  A named Cloudflare tunnel per working copy, so a preview reaches an app we
  are not running.

  `PreviewAddress` covers an app *we* host; a tunnel covers one we cannot
  dial (a laptop behind a router). `cloudflared` runs beside the app and dials
  out, so nothing has to reach in.

  The address stays on our zone and prefix: the frame-src policy
  (`PreviewAddress.csp_origin/0`) and the same-site session cookie both
  depend on it.

  **One tunnel per machine.** Cloudflare hands a request to whichever connector
  answers, so every connector must reach every route — true on one machine,
  false across two. The tunnel belongs to the device (`Devices.tunnel/1`);
  each copy on it gets a route. A copy with no device keeps a per-copy tunnel.

  **The secret is returned once**, at creation, so it is generated here and
  stored encrypted. A stored credential wins over anything Cloudflare reports:
  a tunnel we can name but not speak for is worth less than none.

  Routes live in Cloudflare (`config_src: "cloudflare"`), edited through the
  API under `TunnelIngressLock`, so one copy's address changing never restarts
  the connector carrying the others. A machine's existing tunnel can be
  recorded as its machine tunnel rather than replaced, so its hostnames' DNS
  never moves. See knowledge/promotion, "Previews".
  """

  require Logger

  alias CodeMySpec.Devices
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy
  alias CodeMySpec.Workspaces.PreviewAddress
  alias CodeMySpec.Workspaces.TunnelIngressLock

  @api "https://api.cloudflare.com/client/v4"

  @typedoc """
  What `ClientUtils.CloudflareTunnel` needs to run in named mode. Key names
  match its options so no translation step can drift.
  """
  @type credentials :: %{
          hostname: String.t(),
          tunnel_id: String.t(),
          account_tag: String.t(),
          tunnel_secret: String.t(),
          embedder: String.t()
        }

  @doc """
  The origin allowed to frame a preview — this deployment's own.

  Returned with the credentials so no app hardcodes it: a wrong embedder fails
  silently (the frame renders blank). May be a space-separated list
  (`frame-ancestors` syntax), e.g. both `localhost:4000` and the dev domain.
  """
  @spec embedder() :: String.t()
  def embedder do
    case config()[:embedder] do
      value when is_binary(value) and value != "" -> value
      _ -> CodeMySpec.PublicUrl.base()
    end
  end

  @doc """
  This account's Cloudflare tag, or `nil` if unconfigured.

  Public because `credentials()` needs it wherever they are assembled without
  reaching Cloudflare — see `stored_credentials/1`.
  """
  @spec account_tag() :: String.t() | nil
  def account_tag do
    case account_id() do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  @doc """
  This copy's own tunnel credentials, exactly as already stored — never
  provisions, never reaches Cloudflare.

  Safe to ask on every app restart, unlike `ensure/1`. Answers for any copy
  holding a tunnel id and secret; whether to run a connector for it is the
  caller's decision.
  """
  @spec stored_credentials(WorkingCopy.t()) :: {:ok, credentials()} | :error
  def stored_credentials(
        %WorkingCopy{
          preview_tunnel_id: id,
          preview_tunnel_secret: secret
        } = copy
      )
      when is_binary(id) and id != "" and is_binary(secret) and secret != "" do
    {:ok,
     %{
       hostname: PreviewAddress.host(copy.id),
       tunnel_id: id,
       tunnel_secret: secret,
       account_tag: account_tag() || "",
       embedder: embedder()
     }}
  end

  def stored_credentials(%WorkingCopy{}), do: :error

  @doc """
  The tunnel a copy's harness should run: its machine's, once the machine
  holds one, else a main copy's own stored tunnel. Read-only, like
  `stored_credentials/1`.

  Every copy on a machine is handed the same tunnel, and the harness keeps one
  connector per tunnel, so a machine runs one however many copies it carries.
  """
  @spec machine_credentials(WorkingCopy.t()) :: {:ok, credentials()} | :error
  def machine_credentials(%WorkingCopy{device_id: device_id} = copy) do
    case Devices.tunnel(device_id) do
      {:ok, %{tunnel_id: id, tunnel_secret: secret}} ->
        {:ok,
         %{
           hostname: PreviewAddress.host(copy.id),
           tunnel_id: id,
           tunnel_secret: secret,
           account_tag: account_tag() || "",
           embedder: embedder()
         }}

      :error ->
        if copy.main, do: stored_credentials(copy), else: :error
    end
  end

  @doc """
  Give a working copy its address on its machine's tunnel, making the tunnel
  exist if the machine has none.

  Adds the copy's route (when it has an `app_url`) and a DNS record pointing
  its address at the tunnel, records both on the working copy, and returns
  what the checkout needs to run it. Main is eligible before its app serves;
  any other copy once it has an `app_url`.

  Idempotent: route and record are re-asserted, not assumed. A tunnel the copy
  held before is deleted once no copy names it.
  """
  @spec ensure(WorkingCopy.t()) :: {:ok, credentials()} | {:error, term()}
  def ensure(%WorkingCopy{} = copy) do
    with :ok <- eligible(copy),
         {:ok, account} <- account_id(),
         {:ok, tunnel} <- machine_tunnel(copy, account),
         host = PreviewAddress.host(copy.id),
         :ok <- route(account, tunnel.tunnel_id, host, copy),
         :ok <- point(host, tunnel.tunnel_id),
         {:ok, _copy} <- record(copy, host, tunnel) do
      retire_replaced(copy.preview_tunnel_id, tunnel.tunnel_id, account)
      {:ok, Map.merge(tunnel, %{hostname: host, account_tag: account, embedder: embedder()})}
    end
  end

  # Main is eligible before its app first serves (onboarding asks for its
  # address up front); any other copy once it has an app to point at.
  defp eligible(%WorkingCopy{main: true}), do: :ok
  defp eligible(%WorkingCopy{app_url: url}) when is_binary(url) and url != "", do: :ok
  defp eligible(%WorkingCopy{}), do: {:error, :not_the_main_copy}

  # A route needs somewhere to send traffic. Main asked for its address at
  # onboarding has no app yet; it gets its route when it is shared again with
  # an app serving.
  defp route(account, tunnel_id, host, %WorkingCopy{app_url: url})
       when is_binary(url) and url != "",
       do: add_ingress(account, tunnel_id, host, url)

  defp route(_account, _tunnel_id, _host, %WorkingCopy{}), do: :ok

  # The machine's tunnel, or a new one recorded on the machine. A copy that
  # names no machine keeps the per-copy tunnel it always had.
  defp machine_tunnel(%WorkingCopy{device_id: device_id}, account) when is_binary(device_id) do
    case Devices.tunnel(device_id) do
      {:ok, tunnel} ->
        {:ok, tunnel}

      :error ->
        with {:ok, tunnel} <- create("machine-" <> device_id, account),
             {:ok, _device} <- Devices.record_tunnel(device_id, tunnel) do
          {:ok, tunnel}
        end
    end
  end

  defp machine_tunnel(%WorkingCopy{} = copy, account), do: tunnel_for(copy, account)

  # The tunnel a copy held before, deleted once no copy names it. Best-effort:
  # a failed delete must not take the copy's new address down.
  defp retire_replaced(nil, _current, _account), do: :ok
  defp retire_replaced(same, same, _account), do: :ok

  defp retire_replaced(previous, _current, account) do
    if WorkingCopies.tunnel_in_use?(previous) do
      :ok
    else
      case delete_tunnel(account, previous) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[PreviewTunnel] could not delete replaced tunnel #{previous}: #{inspect(reason)}"
          )

          :ok
      end
    end
  end

  defp delete_tunnel(account, tunnel_id) do
    with {:ok, token} <- token() do
      case delete("#{@api}/accounts/#{account}/cfd_tunnel/#{tunnel_id}", token) do
        {:ok, %{"success" => true}} -> :ok
        {:ok, body} -> {:error, {:cloudflare, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # A stored credential wins over anything Cloudflare would say (see moduledoc).
  defp tunnel_for(%WorkingCopy{preview_tunnel_id: id, preview_tunnel_secret: secret}, _account)
       when is_binary(id) and id != "" and is_binary(secret) and secret != "" do
    {:ok, %{tunnel_id: id, tunnel_secret: secret}}
  end

  defp tunnel_for(%WorkingCopy{} = copy, account), do: create("preview-" <> copy.id, account)

  # 32 bytes, base64, generated here rather than left to Cloudflare: the
  # secret is what the harness's connector authenticates with, and Cloudflare
  # never hands it back after creation.
  #
  # `config_src: "cloudflare"` — the tunnel's routes live in Cloudflare and are
  # edited through the API (`add_ingress/4`), so a copy gaining or losing an
  # address never restarts the connector carrying every other one.
  defp create(name, account) do
    secret = 32 |> :crypto.strong_rand_bytes() |> Base.encode64()

    body = %{name: name, tunnel_secret: secret, config_src: "cloudflare"}

    case post("#{@api}/accounts/#{account}/cfd_tunnel", body) do
      {:ok, %{"result" => %{"id" => id}}} ->
        {:ok, %{tunnel_id: id, tunnel_secret: secret}}

      {:ok, body} ->
        {:error, {:cloudflare, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `proxied: true` is required: an unproxied CNAME to `cfargotunnel.com` does
  # not resolve.
  defp point(host, tunnel_id) do
    with {:ok, token} <- token(),
         {:ok, zone} <- zone_id() do
      target = tunnel_id <> ".cfargotunnel.com"
      body = %{type: "CNAME", name: host, content: target, proxied: true, ttl: 1}

      "#{@api}/zones/#{zone}/dns_records"
      |> post(body, token)
      |> interpret_record(%{host: host, target: target, zone: zone, token: token})
    end
  end

  @doc """
  Drop this copy's own ingress rule from the tunnel it was sharing, and clear
  its recorded address.

  For offboarding, not an ordinary stop: an idle app keeps its route and
  record (serving a 502) so it need not be re-shared; a copy going away
  should stop resolving. Deletes the route and the DNS record; the tunnel
  itself stays.

  A no-op on a copy holding no tunnel credential.
  """
  @spec release(WorkingCopy.t()) :: :ok | {:error, term()}
  def release(%WorkingCopy{preview_tunnel_id: id, preview_tunnel_secret: secret} = copy)
      when is_binary(id) and id != "" and is_binary(secret) and secret != "" do
    host = PreviewAddress.host(copy.id)

    with {:ok, account} <- account_id(),
         :ok <- remove_ingress(account, id, host),
         :ok <- delete_dns_record(host) do
      copy
      |> WorkingCopies.clear_preview_tunnel()
      |> case do
        {:ok, _copy} -> :ok
        error -> error
      end
    end
  end

  def release(%WorkingCopy{}), do: :ok

  # The CNAME `point/2` wrote, looked up by name (its id is not stored).
  defp delete_dns_record(host) do
    with {:ok, token} <- token(),
         {:ok, zone} <- zone_id() do
      "#{@api}/zones/#{zone}/dns_records?name=#{host}"
      |> get(token)
      |> delete_found_record(zone, token)
    end
  end

  defp delete_found_record({:ok, %{"result" => [%{"id" => id} | _]}}, zone, token) do
    case delete("#{@api}/zones/#{zone}/dns_records/#{id}", token) do
      {:ok, %{"success" => true}} -> :ok
      {:ok, body} -> {:error, {:cloudflare, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Nothing to delete is not a failure (released twice, or removed by hand).
  defp delete_found_record({:ok, %{"result" => []}}, _zone, _token), do: :ok
  defp delete_found_record({:ok, body}, _zone, _token), do: {:error, {:cloudflare, body}}
  defp delete_found_record({:error, reason}, _zone, _token), do: {:error, reason}

  # ── Remote ingress ──
  #
  # Locked on `tunnel_id`: copies on one device edit the same rule list, and an
  # unlocked GET-modify-PUT would silently discard a concurrent addition.

  defp add_ingress(account, tunnel_id, host, service) do
    TunnelIngressLock.with_lock(tunnel_id, fn ->
      with {:ok, ingress} <- get_ingress(account, tunnel_id) do
        ingress
        |> Enum.reject(&(&1["hostname"] == host))
        |> Kernel.++([%{"hostname" => host, "service" => service}])
        |> put_ingress(account, tunnel_id)
      end
    end)
  end

  defp remove_ingress(account, tunnel_id, host) do
    TunnelIngressLock.with_lock(tunnel_id, fn ->
      with {:ok, ingress} <- get_ingress(account, tunnel_id) do
        ingress
        |> Enum.reject(&(&1["hostname"] == host))
        |> put_ingress(account, tunnel_id)
      end
    end)
  end

  defp get_ingress(account, tunnel_id) do
    case get_configuration(account, tunnel_id) do
      {:ok, %{"result" => %{"config" => config}}} ->
        {:ok, (config || %{}) |> Map.get("ingress", []) |> Enum.reject(&is_nil(&1["hostname"]))}

      {:ok, body} ->
        {:error, {:cloudflare, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Every named rule, then exactly one catch-all last (`cloudflared` refuses a
  # final rule naming a host). `get_ingress/2` strips the old catch-all.
  defp put_ingress(named, account, tunnel_id) do
    case put_configuration(account, tunnel_id, named ++ [%{"service" => "http_status:404"}]) do
      {:ok, %{"success" => true}} -> :ok
      {:ok, body} -> {:error, {:cloudflare, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_configuration(account, tunnel_id) do
    with {:ok, token} <- token() do
      get("#{@api}/accounts/#{account}/cfd_tunnel/#{tunnel_id}/configurations", token)
    end
  end

  defp put_configuration(account, tunnel_id, ingress) do
    with {:ok, token} <- token() do
      "#{@api}/accounts/#{account}/cfd_tunnel/#{tunnel_id}/configurations"
      |> put(%{config: %{ingress: ingress}}, token)
    end
  end

  defp get(url, token) do
    [url: url, headers: [{"authorization", "Bearer " <> token}], retry: false]
    |> Keyword.merge(req_options())
    |> Req.get()
    |> body_of()
  end

  defp patch(url, body, token) do
    [
      url: url,
      headers: [{"authorization", "Bearer " <> token}],
      json: body,
      retry: false
    ]
    |> Keyword.merge(req_options())
    |> Req.patch()
    |> body_of()
  end

  defp put(url, body, token) do
    [
      url: url,
      headers: [{"authorization", "Bearer " <> token}],
      json: body,
      retry: false
    ]
    |> Keyword.merge(req_options())
    |> Req.put()
    |> body_of()
  end

  defp delete(url, token) do
    [url: url, headers: [{"authorization", "Bearer " <> token}], retry: false]
    |> Keyword.merge(req_options())
    |> Req.delete()
    |> body_of()
  end

  # Success first: Cloudflare sends `"errors": []` on a successful response.
  defp interpret_record({:ok, %{"success" => true}}, _host), do: :ok

  # "Name taken" (81053/81057) is not success on its own: the record may aim
  # at a tunnel that no longer exists (Cloudflare 530). Look, and repoint it
  # unless it already targets this tunnel.
  defp interpret_record({:ok, %{"errors" => errors}}, ctx) when is_list(errors) do
    if Enum.any?(errors, &(&1["code"] in [81_053, 81_057])) do
      repoint(ctx)
    else
      Logger.warning("[PreviewTunnel] #{ctx.host} could not be pointed: #{inspect(errors)}")
      {:error, {:cloudflare, errors}}
    end
  end

  defp interpret_record({:ok, _body}, _ctx), do: :ok
  defp interpret_record({:error, reason}, _ctx), do: {:error, reason}

  # Aim the record that already exists at this tunnel. A no-op when it is
  # already correct, which is what the second and every later call sees.
  defp repoint(%{host: host, target: target, zone: zone, token: token}) do
    case get("#{@api}/zones/#{zone}/dns_records?name=#{host}", token) do
      {:ok, %{"result" => [%{"content" => ^target} | _]}} ->
        :ok

      {:ok, %{"result" => [%{"id" => id} = record | _]}} ->
        Logger.info(
          "[PreviewTunnel] #{host} pointed at #{record["content"]}, repointing to #{target}"
        )

        "#{@api}/zones/#{zone}/dns_records/#{id}"
        |> patch(%{type: "CNAME", name: host, content: target, proxied: true, ttl: 1}, token)
        |> case do
          {:ok, %{"success" => true}} -> :ok
          {:ok, body} -> {:error, {:cloudflare, body}}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _body} ->
        {:error, {:cloudflare, :record_taken_but_not_found}}

      {:error, reason} ->
        {:error, reason}
    end
  end

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

  # Our own credential, not the customer's, as in `PreviewAddress`.
  defp token do
    present(config()[:token] || app_cloudflare()[:api_token], :no_cloudflare_token)
  end

  defp zone_id do
    present(config()[:zone_id] || preview_address_config()[:zone_id], :no_zone_id)
  end

  # A tunnel is created against an account (a DNS record against a zone).
  defp account_id do
    present(config()[:account_id] || app_cloudflare()[:account_id], :no_cloudflare_account_id)
  end

  defp present(value, reason) when value in [nil, ""], do: {:error, reason}
  defp present(value, _reason), do: {:ok, value}

  # Pinned in test config so the suite cannot reach Cloudflare.
  defp req_options, do: config()[:req_options] || []

  defp app_cloudflare,
    do: Application.get_env(:code_my_spec, CodeMySpec.Content.CloudflareClient, [])

  defp preview_address_config,
    do: Application.get_env(:code_my_spec, PreviewAddress, [])

  defp config, do: Application.get_env(:code_my_spec, __MODULE__, [])
end
