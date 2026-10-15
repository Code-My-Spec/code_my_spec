defmodule CodeMySpec.Workspaces.PreviewAddress do
  @moduledoc """
  Makes sure a project's preview address resolves, once, before it is shown.

  Not part of booting (a DNS failure must not read as a broken app) and not
  part of creating a project (most are never previewed). Written the first
  time a preview is asked for; keyed to the project, it outlives every
  container, so a shared link keeps working.

  Our zone, with our credential — not the customer's (`Provisioning` writes
  records on domains customers own).
  """

  require Logger

  @prefix "preview-"

  # The two OAuth providers a generated app is most likely to offer out of
  # the box. Not an exhaustive list — `:extra_frame_origins` config extends
  # it per deploy without needing a code change for the next provider.
  @default_extra_frame_origins ["accounts.google.com", "github.com"]

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

  # Where the address already resolves without us (dev on `.localhost`) there
  # is no record to write; the contract — it resolves — already holds.
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

  The app asserts its own `frame-ancestors` (`ClientUtils.PreviewFraming`);
  nothing rewrites the header in the tunnel. The address must be same-site
  with the page framing it: a third-party frame loses the app's session
  cookie, and with it CSRF and the LiveView connect, in every browser.

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

  @doc """
  Bare domains a previewed app's own OAuth flows may send the iframe to,
  beyond its own preview origin — for display (the project form, the preview
  panel) rather than the CSP header itself. See `csp_extra_frame_origins/1`
  for the header value these become.

  Per project: `nil` (never customized) falls back to the
  `:extra_frame_origins` config, defaulting to accounts.google.com and
  github.com. A project's own list (possibly `[]`) is used exactly.
  """
  @spec extra_frame_origins(CodeMySpec.Projects.Project.t() | nil) :: [String.t()]
  def extra_frame_origins(project \\ nil)

  def extra_frame_origins(%{preview_extra_frame_origins: origins}) when is_list(origins),
    do: origins

  def extra_frame_origins(_project) do
    config()
    |> Keyword.get(:extra_frame_origins, @default_extra_frame_origins)
  end

  @doc """
  CSP `frame-src` origins a previewed app is allowed to navigate the iframe
  to, beyond its own preview origin.

  A previewed app's OAuth sign-in navigates the iframe to the provider's
  domain; without these, CSP refuses it silently. Per project — see
  `extra_frame_origins/1`.
  """
  @spec csp_extra_frame_origins(CodeMySpec.Projects.Project.t() | nil) :: [String.t()]
  def csp_extra_frame_origins(project \\ nil) do
    project
    |> extra_frame_origins()
    |> Enum.map(&("https://" <> &1))
  end

  # On by default; `manage_dns: false` where previews resolve some other way,
  # so no records are written into a zone this machine does not own.
  defp manage_dns?, do: Keyword.get(config(), :manage_dns, true)

  defp scheme, do: config()[:scheme] || "https"

  defp port_suffix do
    case config()[:port] do
      nil -> ""
      port -> ":" <> to_string(port)
    end
  end

  # Our own credential, never a visitor's scope: a visitor who never connected
  # Cloudflare must still get a preview address. A CNAME to the tunnel, so the
  # serving host can move without a zone edit per project.
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

  # An existing record is success: the address is stable across containers.
  defp interpret({:ok, %Req.Response{status: status}}) when status in 200..299,
    do: {:ok, :written}

  # 81053 is "a record with that host already exists", the ordinary case from
  # the second preview on. 81057 is accepted too.
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

  # The same Cloudflare token `Content.CloudflareClient` uses, read from
  # config — never `System.get_env`: envs/ files load into config, not the
  # process environment.
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
