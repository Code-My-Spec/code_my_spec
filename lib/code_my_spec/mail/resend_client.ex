defmodule CodeMySpec.Mail.ResendClient do
  @moduledoc """
  Hand-written Req client for the Resend Domains API (no API-wrapper lib —
  see `priv/knowledge/resend/api.md` and project MEMORY).

  Covers the three calls the in-app domain-onboarding flow needs:

    * `create_domain/2` — `POST /domains` to register a sending domain and get
      back the DKIM/SPF DNS records to publish.
    * `get_domain/1` — `GET /domains/{id}` to read the current status + records.
    * `verify_domain/1` — `POST /domains/{id}/verify` to ask Resend to re-check
      DNS after the operator has added the records.

  Auth comes from `RESEND_API_KEY`, wired in `config/runtime.exs` for every env
  under this module's config key. When no key is configured the client returns
  `{:error, :resend_not_configured}` so callers can surface a clear message
  rather than crashing.

  Tests inject `api_key`/`plug` via
  `Application.put_env(:code_my_spec, __MODULE__, api_key: …, plug: …)` so HTTP
  can be stubbed without hitting Resend.
  """

  require Logger

  @api_base "https://api.resend.com"
  @default_region "us-east-1"

  @type body :: map()
  @type error ::
          {:error, :resend_not_configured}
          | {:error, {:resend_error, integer(), term()}}
          | {:error, term()}

  @spec create_domain(String.t(), String.t()) :: {:ok, body()} | error()
  def create_domain(name, region \\ @default_region) when is_binary(name) do
    request(:post, "/domains", json: %{name: name, region: region})
  end

  @spec get_domain(String.t()) :: {:ok, body()} | error()
  def get_domain(id) when is_binary(id) do
    request(:get, "/domains/#{id}", [])
  end

  @spec verify_domain(String.t()) :: {:ok, body()} | error()
  def verify_domain(id) when is_binary(id) do
    request(:post, "/domains/#{id}/verify", [])
  end

  @spec list_domains() :: {:ok, [map()]} | error()
  def list_domains do
    case request(:get, "/domains", []) do
      {:ok, %{"data" => data}} when is_list(data) -> {:ok, data}
      {:ok, _body} -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  @doc "Find an already-registered domain by name, or `:not_found`."
  @spec find_domain_by_name(String.t()) :: {:ok, map()} | :not_found | error()
  def find_domain_by_name(name) when is_binary(name) do
    with {:ok, domains} <- list_domains() do
      case Enum.find(domains, &(&1["name"] == name)) do
        nil -> :not_found
        domain -> {:ok, domain}
      end
    end
  end

  # Private Helpers

  defp request(method, path, opts) do
    case api_key() do
      key when is_binary(key) and key != "" ->
        req_opts =
          [
            method: method,
            url: @api_base <> path,
            headers: [
              {"authorization", "Bearer #{key}"},
              {"content-type", "application/json"}
            ]
          ]
          |> Keyword.merge(opts)
          |> Keyword.merge(plug_opt())

        case Req.request(req_opts) do
          {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
            {:ok, body}

          {:ok, %Req.Response{status: status, body: body}} ->
            {:error, {:resend_error, status, body}}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :resend_not_configured}
    end
  end

  defp api_key do
    :code_my_spec
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:api_key)
  end

  defp plug_opt do
    case Application.get_env(:code_my_spec, __MODULE__, []) |> Keyword.get(:plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
