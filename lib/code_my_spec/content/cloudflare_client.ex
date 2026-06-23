defmodule CodeMySpec.Content.CloudflareClient do
  @moduledoc """
  Hand-written Req client for purging specific URLs from the Cloudflare edge
  cache after a replaced image is re-uploaded (story 712, criterion 6273).

  The Cloudflare API token lives in the local CLI env — never the SaaS. In
  tests a `Req.Test` plug (configured under this module's app env) intercepts
  the POST; in production it hits the real zone purge endpoint.

  Config (`Application.get_env(:code_my_spec, #{inspect(__MODULE__)})`):
    * `:plug` — a `{Req.Test, name}` plug (tests only)
    * `:api_token`, `:zone_id` — real Cloudflare credentials
  """

  @doc """
  Purge `urls` from the Cloudflare cache. No-op for an empty list. Returns
  `:ok` on a 2xx, `{:error, _}` otherwise.
  """
  @spec purge([String.t()]) :: :ok | {:error, term()}
  def purge([]), do: :ok

  def purge(urls) when is_list(urls) do
    config = config()

    [method: :post, url: purge_url(config), json: %{files: urls}]
    |> Req.new()
    |> attach_plug(config)
    |> attach_auth(config)
    |> Req.request()
    |> case do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:cloudflare_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp config, do: Application.get_env(:code_my_spec, __MODULE__, [])

  defp purge_url(config) do
    case config[:zone_id] do
      nil -> "https://api.cloudflare.com/client/v4/zones/zone/purge_cache"
      zone -> "https://api.cloudflare.com/client/v4/zones/#{zone}/purge_cache"
    end
  end

  defp attach_plug(req, config) do
    case config[:plug] do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end

  defp attach_auth(req, config) do
    case config[:api_token] do
      nil -> req
      token -> Req.merge(req, auth: {:bearer, token})
    end
  end
end
