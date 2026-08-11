defmodule CodeMySpec.Workspaces.PreviewAddress do
  @moduledoc """
  Makes sure a project's preview address resolves, once, before it is shown.

  Deliberately not part of booting. A workspace that cannot start because
  Cloudflare is rate-limiting is an infrastructure failure wearing the costume
  of a broken app, which is exactly the confusion `Workspaces.state/1` exists
  to prevent. Boot brings the container up; this makes the address point at it,
  and the two fail independently.

  Also not part of creating a project. Most projects never get previewed, and a
  record for each of them is zone litter with a lifetime of forever.

  So: the first time a preview is asked for, and never again. The record is
  keyed to the project and outlives every container, which is what makes a link
  someone was sent keep working.

  This is our zone, not the customer's. `Provisioning.Steps.run(:dns, …)` writes
  records on a domain the customer owns, pointing at environments they paid
  for; this writes one on ours, pointing at us. Same API call, different thing.
  """

  require Logger

  @prefix "preview-"

  @doc """
  The address for this project, guaranteed to resolve, or a reason it does not.

  `{:ok, host}` means the record is there — either it already was, or it has
  just been written. `{:error, reason}` is for the caller to show as "not yet",
  never as "your app is broken": nothing about this says anything about the app.
  """
  @spec ensure(String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure(project_id) do
    host = host(project_id)

    ensure_record(manage_dns?(), host)
  end

  # Where the address already resolves without us — dev on `.localhost`, where
  # every label is 127.0.0.1 — there is no record to write and asking for a zone
  # named "localhost" would fail once per preview, loudly and pointlessly. The
  # contract is that the address resolves, and it does.
  defp ensure_record(false, host), do: {:ok, host}

  defp ensure_record(true, host) do
    case put_record(host) do
      {:ok, _} ->
        {:ok, host}

      {:error, reason} ->
        Logger.warning(
          "[PreviewAddress] #{host} could not be pointed anywhere: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  The address a project's preview is at, whether or not it resolves yet.

  One label deep on purpose: a free wildcard certificate covers exactly one,
  so `{id}.preview.codemyspec.com` would need a paid one where this does not.
  """
  @spec host(String.t()) :: String.t()
  def host(project_id), do: @prefix <> project_id <> "." <> base_domain()

  @doc "The prefix that marks a hostname as ours to serve."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc """
  The address to point a browser at, which is not the container's own.

  Framing the container directly does not work and the failure is silent: a
  generated Phoenix app answers `content-security-policy: frame-ancestors
  'self'`, so any other origin is refused and the frame renders blank — which
  reads to the visitor as their app being broken. `PreviewProxy` exists to
  replace that header, and it only sees a request that arrives here.

  It is also the whole point of the address being same-site: framed from a
  genuinely third-party origin, Safari drops the app's session cookie and takes
  its CSRF token and LiveView connect with it.

  Scheme and port are configurable because dev reaches the preview listener
  directly on its own port, while production has an edge in front of it on 443.
  """
  @spec url(String.t()) :: String.t()
  def url(project_id), do: scheme() <> "://" <> host(project_id) <> port_suffix()

  @doc """
  The CSP source expression covering every preview address.

  Our own pages have to be allowed to *frame* a preview, and `'self'` does not
  cover it — a different host is a different origin however closely related.
  Derived from the same configuration the addresses are minted from, so the
  two cannot drift apart and leave a policy that silently blocks the pane.
  """
  @spec csp_origin() :: String.t()
  def csp_origin, do: scheme() <> "://*." <> base_domain() <> port_suffix()

  # Off unless a real zone is configured. A machine that reaches previews some
  # other way should not be writing records into a zone it does not own.
  defp manage_dns?, do: Keyword.get(config(), :manage_dns, true)

  defp scheme, do: config()[:scheme] || "https"

  defp port_suffix do
    case config()[:port] do
      nil -> ""
      port -> ":" <> to_string(port)
    end
  end

  # Our own credential, not the visitor's. `Provisioning.Cloudflare` speaks for
  # the customer — it resolves their integration and writes on domains they own.
  # This record is on *our* zone, pointing at *our* tunnel, and a visitor who
  # has never connected Cloudflare must still get a preview address. Taking a
  # scope here was the bug: it authenticated as whoever happened to be looking,
  # and failed with :cloudflare_not_connected for everyone who had not linked an
  # account they have no reason to have.
  #
  # A CNAME to the tunnel rather than an address record: the thing serving a
  # preview moves — a laptop today, the shared host later — and a name that
  # follows it survives that move without a zone edit per project.
  defp put_record(host) do
    with {:ok, token} <- token(),
         {:ok, zone_id} <- zone_id() do
      Req.post(
        "https://api.cloudflare.com/client/v4/zones/#{zone_id}/dns_records",
        headers: [{"authorization", "Bearer " <> token}],
        json: %{type: "CNAME", name: host, content: target(), proxied: true, ttl: 1},
        retry: false,
        receive_timeout: 10_000
      )
      |> interpret()
    end
  end

  # An existing record is success, not failure: the whole point is that the
  # address is stable across every container, so the second preview finds what
  # the first one wrote.
  defp interpret({:ok, %Req.Response{status: status}}) when status in 200..299,
    do: {:ok, :written}

  # 81053 is "a record with that host already exists", which is the ordinary
  # case from the second preview onward and is exactly what we want — the
  # address is stable across every container, so finding it already written is
  # success. Guessed 81057 first and watched every repeat call log a warning
  # for having worked.
  defp interpret({:ok, %Req.Response{body: %{"errors" => errors}}}) when is_list(errors) do
    if Enum.any?(errors, &(&1["code"] in [81_053, 81_057])) do
      {:ok, :already_there}
    else
      {:error, {:cloudflare, errors}}
    end
  end

  defp interpret({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:cloudflare, status, body}}

  defp interpret({:error, reason}), do: {:error, reason}

  # The account credential already exists and is already configured for this
  # zone — `Content.CloudflareClient` uses it to purge cache on publish. One
  # Cloudflare account, one token, one place it is read from. Reaching for
  # `System.get_env` here returned nil and looked like a missing secret: the
  # envs/ files are Dotenvy, loaded into config, never into the process
  # environment.
  defp token do
    present(config()[:token] || app_cloudflare()[:api_token], :no_cloudflare_token)
  end

  defp zone_id do
    present(config()[:zone_id] || app_cloudflare()[:zone_id], :no_zone_id)
  end

  defp present(value, reason) when value in [nil, ""], do: {:error, reason}
  defp present(value, _reason), do: {:ok, value}

  defp app_cloudflare,
    do: Application.get_env(:code_my_spec, CodeMySpec.Content.CloudflareClient, [])

  defp target do
    config()[:target] ||
      raise "no preview target configured — set :target on #{inspect(__MODULE__)}"
  end

  defp base_domain, do: config()[:base_domain] || "codemyspec.com"

  defp config, do: Application.get_env(:code_my_spec, __MODULE__, [])
end
