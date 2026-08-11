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

  alias CodeMySpec.Provisioning.Cloudflare
  alias CodeMySpec.Users.Scope

  require Logger

  @prefix "preview-"

  @doc """
  The address for this project, guaranteed to resolve, or a reason it does not.

  `{:ok, host}` means the record is there — either it already was, or it has
  just been written. `{:error, reason}` is for the caller to show as "not yet",
  never as "your app is broken": nothing about this says anything about the app.
  """
  @spec ensure(Scope.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure(%Scope{} = scope, project_id) do
    host = host(project_id)

    with {:ok, zone} <- zone(scope),
         {:ok, _record} <- write(scope, zone, host) do
      {:ok, host}
    else
      {:error, reason} ->
        Logger.warning("[PreviewAddress] #{host} could not be pointed anywhere: #{inspect(reason)}")

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

  defp scheme, do: config()[:scheme] || "https"

  defp port_suffix do
    case config()[:port] do
      nil -> ""
      port -> ":" <> to_string(port)
    end
  end

  defp zone(scope) do
    case Cloudflare.find_zone(scope, base_domain()) do
      {:ok, %{"id" => id}} -> {:ok, id}
      other -> other
    end
  end

  # A CNAME to the tunnel rather than an address record: the thing serving a
  # preview moves — a laptop today, the shared host later — and a name that
  # follows it survives that move without a zone edit per project.
  defp write(scope, zone_id, host) do
    Cloudflare.ensure_dns_record(scope, zone_id, host, target(),
      type: "CNAME",
      proxied: true
    )
  end

  defp target do
    config()[:target] ||
      raise "no preview target configured — set :target on #{inspect(__MODULE__)}"
  end

  defp base_domain, do: config()[:base_domain] || "codemyspec.com"

  defp config, do: Application.get_env(:code_my_spec, __MODULE__, [])
end
