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
  the surrounding system would break. `PreviewAddress.csp_origin/0` derives the
  frame-src policy from our base domain, so an address outside it is refused by
  the browser and the pane renders blank; and the same-site property that keeps
  a browser sending the framed app's session cookie holds only while the preview
  shares a registrable domain with the page framing it — which is not a Safari
  quirk, and cost an afternoon on Broken Oaths when dev previews sat on another
  domain.

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

  ## Sharing a tunnel across a device (criteria 1586/1587)

  Every connector attached to a tunnel has to be able to satisfy every one of
  its ingress rules, because Cloudflare has no notion of which connector is
  near which hostname's target — it hands the request to whichever connector
  answers. That is sound for two copies on *one* machine (either one's
  `cloudflared` can dial `http://localhost:<the other's port>` just fine) and
  unsound across two: a connector on a different machine cannot reach a port
  that only exists on the first one. So a copy shares main's tunnel only when
  `WorkingCopies.tunnel_sibling/1` finds one on its own device (1586), and
  gets a plain refusal otherwise (1587) rather than something that looks
  provisioned and silently cannot be reached.

  Sharing adds this copy's hostname to the tunnel's *ingress list* rather than
  running a second `cloudflared`, and only main's connector needs to be
  running at all — see `CmsHarness` main-only tunnel gating (the stray-second-
  connector fix). That list is mutated through Cloudflare's remote tunnel
  configuration endpoint, which `cloudflared` only reads once a tunnel's
  `config_src` is `"cloudflare"` instead of `"local"`. Every tunnel this
  module creates today still has `config_src: "local"` — flipping an
  already-serving tunnel to remote config live is a one-time, watched change,
  not something this module performs on its own. Until that switch happens,
  `add_ingress/4` reaches the API and gets back whatever Cloudflare already
  holds; a copy sharing an unconverted tunnel is recorded correctly and simply
  is not reachable yet.
  """

  require Logger

  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy
  alias CodeMySpec.Workspaces.PreviewAddress
  alias CodeMySpec.Workspaces.TunnelIngressLock

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
          tunnel_secret: String.t(),
          embedder: String.t()
        }

  @doc """
  The origin allowed to frame a preview — this deployment's own.

  Returned with the credentials so no application has to be told it. An app that
  carries a hardcoded embedder can carry the wrong one, and being wrong here is
  silent: the browser refuses the frame, the iframe looks healthy and renders
  nothing, and it reads as the framed app being broken. Broken Oaths lost an
  afternoon to a variant of exactly that.

  The server knows the answer — it is the site doing the framing — so it says
  it rather than every app guessing.

  Several origins are allowed and often needed: dev is reachable both as
  `localhost:4000` and as `dev.codemyspec.com`, and a preview opened from either
  has to be framed by both. `frame-ancestors` takes a space-separated list, so
  this is passed through as written.
  """
  @spec embedder() :: String.t()
  def embedder do
    case config()[:embedder] do
      value when is_binary(value) and value != "" -> value
      _ -> CodeMySpec.PublicUrl.base()
    end
  end

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
  def ensure(%WorkingCopy{main: true} = copy), do: provision(copy)

  # Every other copy is eligible only once it has something of its own to
  # point a preview at (story 1108's `app_url`) — a bare worktree still gets
  # `:not_the_main_copy` below, unchanged from before 1586/1587 existed.
  def ensure(%WorkingCopy{app_url: url} = copy) when is_binary(url) and url != "" do
    case WorkingCopies.tunnel_sibling(copy) do
      {:ok, sibling} -> share(copy, sibling)
      :error -> {:error, :no_tunnel_on_this_device}
    end
  end

  def ensure(%WorkingCopy{}), do: {:error, :not_the_main_copy}

  # Main always creates or reuses a tunnel of its own — unchanged from before
  # 1586/1587, just given a name now that `ensure/1` has a second path.
  defp provision(%WorkingCopy{} = copy) do
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
      {:ok, Map.merge(tunnel, %{hostname: host, account_tag: account, embedder: embedder()})}
    end
  end

  # The device-sharing path (1586): reuse the sibling's tunnel outright — its
  # id and secret, not a new tunnel — and add this copy's own hostname to its
  # ingress rather than running a second `cloudflared`.
  defp share(%WorkingCopy{} = copy, %WorkingCopy{
         preview_tunnel_id: id,
         preview_tunnel_secret: secret
       }) do
    with {:ok, account} <- account_id(),
         host = PreviewAddress.host(copy.id),
         :ok <- add_ingress(account, id, host, copy.app_url),
         :ok <- point(host, id),
         {:ok, _copy} <- record(copy, host, %{tunnel_id: id, tunnel_secret: secret}) do
      {:ok,
       %{tunnel_id: id, tunnel_secret: secret, hostname: host, account_tag: account, embedder: embedder()}}
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

  Offboarding, not an ordinary stop: an app that is merely idle keeps its
  hostname, its ingress rule and its DNS record, serving a 502 until it
  restarts, because a copy meant to come back should not have to be
  re-shared. This is for a copy that is going away — its hostname should
  stop resolving to anything at all, not sit forwarding to a port nothing
  will ever listen on again, or answering NXDOMAIN through a CNAME that
  outlives the row it named.

  A no-op on main, whose tunnel is the project's, not this call's to remove;
  and on a copy that never had one, which offboarding cannot tell apart from
  one whose sharing already failed without doing something destructive to
  find out.
  """
  @spec release(WorkingCopy.t()) :: :ok | {:error, term()}
  def release(%WorkingCopy{main: true}), do: :ok

  def release(%WorkingCopy{preview_tunnel_id: id, preview_tunnel_secret: secret} = copy)
      when is_binary(id) and id != "" and is_binary(secret) and secret != "" do
    host = PreviewAddress.host(copy.id)

    with {:ok, account} <- account_id(),
         :ok <- remove_ingress(account, id, host),
         :ok <- delete_dns_record(host) do
      WorkingCopies.record_preview_tunnel(copy, %{
        preview_url: nil,
        preview_tunnel_id: nil,
        preview_tunnel_secret: nil
      })
      |> case do
        {:ok, _copy} -> :ok
        error -> error
      end
    end
  end

  def release(%WorkingCopy{}), do: :ok

  # The CNAME `point/2` wrote. Looked up by name because that is all a
  # sharing copy was ever given back — nothing here holds the record's own
  # id from when it was created.
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

  # Nothing to delete is not a failure — a copy released twice, or one whose
  # record was already removed by hand, should not block on Cloudflare
  # agreeing there was ever anything there.
  defp delete_found_record({:ok, %{"result" => []}}, _zone, _token), do: :ok
  defp delete_found_record({:ok, body}, _zone, _token), do: {:error, {:cloudflare, body}}
  defp delete_found_record({:error, reason}, _zone, _token), do: {:error, reason}

  # ── Remote ingress (criteria 1586/1587) ──
  #
  # Locked on `tunnel_id`: more than one copy on the same device can add or
  # drop its own rule around the same time, and a GET-modify-PUT with no lock
  # would let a second write silently discard the first's addition. See
  # `TunnelIngressLock`.

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

  # Every named rule, then exactly one catch-all last — `cloudflared` refuses
  # a config whose final rule names a host. `get_ingress/2` already strips
  # whatever catch-all Cloudflare held, so every write re-asserts a fresh one
  # rather than trusting an old one stayed put.
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

  # Success first, and this clause is why. Cloudflare puts `"errors": []` on a
  # *successful* response, so matching the errors key before checking `success`
  # read every successful DNS write as a failure — `{:cloudflare, []}`, an error
  # tuple carrying no errors, which is a shape that should have looked wrong on
  # sight.
  #
  # The unit tests missed it because the stub returned `%{"success" => true,
  # "result" => …}` with no errors key at all, so it fell through to the
  # catch-all below. Real Cloudflare always sends the key. A stub that is
  # tidier than the API it stands in for tests a service that does not exist.
  defp interpret_record({:ok, %{"success" => true}}, _host), do: :ok

  # An existing record is NOT success on its own — it has to point at this
  # tunnel. 81053 and 81057 are Cloudflare saying "that name is taken", which is
  # the ordinary case from the second call onward *and* the case where a
  # previous attempt left a record aimed somewhere else.
  #
  # Treating "taken" as done cost an afternoon. A first attempt created a tunnel
  # and wrote its record, then failed for an unrelated reason; the tunnel was
  # cleaned up and the record was not. Every retry then created a fresh tunnel,
  # got 81053 for the record, reported success — and the address resolved to a
  # tunnel that no longer existed. Cloudflare answers 530, which reads as the
  # origin being down, so the whole diagnosis points at the app.
  #
  # So: taken means go and look, and repoint it if it is aimed at anything but
  # this tunnel.
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
