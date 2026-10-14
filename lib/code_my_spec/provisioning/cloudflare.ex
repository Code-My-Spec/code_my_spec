defmodule CodeMySpec.Provisioning.Cloudflare do
  @moduledoc """
  Domain and DNS against the user's own Cloudflare account.

  Hand-written Req client. Credentials come from the delegated OAuth grant in
  `CodeMySpec.Integrations` (see
  `CodeMySpec.Integrations.Providers.Cloudflare`), falling back to a
  configured API token so cassette recording can run without a user scope.

  - **Registration needs confirmation.** `register_domain/3` requires
    `confirmed: true` and otherwise returns `{:error, :confirmation_required}`
    without a request: registrations are non-refundable. The guard lives here
    so no caller can bypass it.
  - **A domain step ends three ways**: registered, adopted (already owned —
    an ordinary way in), or paused with a dashboard errand (TLD outside the
    Registrar API beta, or no billing method).
    `classify_registration_error/1` downgrades only failures it recognises.
  - **Records are unproxied by default.** A proxied record terminates the
    HTTP-01 challenge at Cloudflare's edge and certificate issuance hangs.
  - **Account id** comes from `GET /accounts`, falling back to the zone list;
    `{:error, :no_account_visible}` when neither shows one.

  See knowledge/provisioning, "Cloudflare".
  """

  require Logger

  alias CodeMySpec.Integrations
  alias CodeMySpec.Users.Scope

  @api_base "https://api.cloudflare.com/client/v4"

  @type body :: map()
  @type error ::
          {:error, :cloudflare_not_connected}
          | {:error, {:cloudflare_error, integer(), term()}}
          | {:error, term()}

  ## Availability and price

  @doc """
  Whether a domain can be registered, and what it costs.

  Returns `{:ok, %{name, supported_tld, availability, price, current_registrar}}`.

  The registrar returns full detail (`available`, `can_register`, price) only
  for domains already associated with the account; for any other name it
  returns only `{name, supported_tld}`. A missing `available` is therefore
  `:unknown`, never `:taken`. Registering a new name is a dashboard errand
  because the API cannot price it.
  """
  @spec check_availability(Scope.t(), String.t()) :: {:ok, map()} | error()
  def check_availability(%Scope{} = scope, name) when is_binary(name) do
    with {:ok, account_id} <- account_id(scope),
         {:ok, body} <-
           request(scope, :get, "/accounts/#{account_id}/registrar/domains/#{name}") do
      {:ok, availability_from(body)}
    end
  end

  defp availability_from(%{"result" => result}) when is_map(result) do
    %{
      name: result["name"],
      supported_tld: result["supported_tld"] == true,
      availability: availability(result),
      price: result["price"],
      currency: result["currency"] || "USD",
      can_register: result["can_register"] == true,
      current_registrar: result["current_registrar"]
    }
  end

  defp availability_from(_),
    do: %{
      name: nil,
      supported_tld: false,
      availability: :unknown,
      price: nil,
      currency: "USD",
      can_register: false,
      current_registrar: nil
    }

  # Absent is not false: "cannot price through the API" sends the user to the
  # dashboard, "taken" does not.
  defp availability(%{"available" => true}), do: :available
  defp availability(%{"available" => false}), do: :taken
  defp availability(_), do: :unknown

  ## Registration

  @doc """
  Register a domain. Requires an explicit confirmation.

  `opts` must carry `confirmed: true`. Without it this returns
  `{:error, :confirmation_required}` and makes no request.
  """
  @spec register_domain(Scope.t(), String.t(), keyword()) ::
          {:ok, body()}
          | {:error, :confirmation_required}
          | {:paused, String.t()}
          | error()
  def register_domain(scope, name, opts \\ [])

  def register_domain(%Scope{} = scope, name, opts) when is_binary(name) do
    case Keyword.get(opts, :confirmed, false) do
      true -> do_register(scope, name, opts)
      _ -> {:error, :confirmation_required}
    end
  end

  defp do_register(scope, name, opts) do
    with {:ok, account_id} <- account_id(scope) do
      payload = %{
        name: name,
        years: Keyword.get(opts, :years, 1),
        privacy: Keyword.get(opts, :privacy, true),
        auto_renew: Keyword.get(opts, :auto_renew, true)
      }

      case request(scope, :post, "/accounts/#{account_id}/registrar/domains", json: payload) do
        {:ok, body} -> {:ok, body}
        {:error, {:cloudflare_error, status, body}} -> classify_registration_error({status, body})
        other -> other
      end
    end
  end

  @doc """
  Turn a registration failure into either a pause with an errand, or a real
  error.

  Conservative on purpose: an unrecognised failure stays an error rather than
  becoming a pause with an undefined errand.
  """
  @spec classify_registration_error({integer(), term()}) :: {:paused, String.t()} | error()
  def classify_registration_error({status, body}) do
    message = provider_message(body)

    cond do
      unsupported_tld?(message) ->
        {:paused,
         "This extension is outside the Cloudflare Registrar API beta. Register " <>
           "#{"the domain"} in the Cloudflare dashboard, then return here and setup " <>
           "will adopt it."}

      billing_missing?(message) ->
        {:paused,
         "Cloudflare has no payment method on file for this account. Add one in " <>
           "the Cloudflare dashboard under Billing, then return here to continue. " <>
           "(Cloudflare said: #{message})"}

      true ->
        {:error, {:cloudflare_error, status, body}}
    end
  end

  defp unsupported_tld?(message) do
    String.match?(message, ~r/(tld|extension).*(not|un)support|not (yet )?available|beta/i)
  end

  defp billing_missing?(message) do
    String.match?(message, ~r/payment|billing|card|invoice/i)
  end

  defp provider_message(%{"errors" => [%{"message" => m} | _]}) when is_binary(m), do: m
  defp provider_message(%{"error" => %{"message" => m}}) when is_binary(m), do: m
  defp provider_message(body) when is_binary(body), do: body
  defp provider_message(body), do: inspect(body)

  @doc """
  Whether a domain is already in the account's registrar list.

  The adoption path and the idempotence check at once — a retried step finds
  the domain already there and does not buy a second one.
  """
  @spec owned?(Scope.t(), String.t()) :: {:ok, boolean()} | error()
  def owned?(%Scope{} = scope, name) when is_binary(name) do
    # Owned means registered here *or* run as a Cloudflare zone: a domain
    # bought elsewhere but served by a zone can be adopted.
    with {:ok, zone_owned} <- zone_owned?(scope, name) do
      if zone_owned do
        {:ok, true}
      else
        with {:ok, domains} <- list_domains(scope) do
          {:ok, Enum.any?(domains, &(&1["name"] == name))}
        end
      end
    end
  end

  defp zone_owned?(scope, name) do
    case find_zone(scope, name) do
      {:ok, _zone} -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      {:error, _} = error -> error
    end
  end

  @doc "Every domain in the account's registrar."
  @spec list_domains(Scope.t()) :: {:ok, [body()]} | error()
  def list_domains(%Scope{} = scope) do
    with {:ok, account_id} <- account_id(scope),
         {:ok, %{"result" => domains}} <-
           request(scope, :get, "/accounts/#{account_id}/registrar/domains") do
      {:ok, List.wrap(domains)}
    end
  end

  @doc """
  Register the domain only if the account does not already hold it.

  The idempotent entry point — prefer it over `register_domain/3` from step
  code, so a retry adopts rather than buys again.
  """
  @spec ensure_domain(Scope.t(), String.t(), keyword()) ::
          {:ok, :adopted} | {:ok, body()} | {:paused, String.t()} | error()
  def ensure_domain(%Scope{} = scope, name, opts \\ []) do
    case owned?(scope, name) do
      {:ok, true} ->
        Logger.info("[Cloudflare] #{name} already in the account — adopting")
        {:ok, :adopted}

      {:ok, false} ->
        register_domain(scope, name, opts)

      {:error, _} = error ->
        error
    end
  end

  ## Zones

  @doc "Zones visible to the grant."
  @spec list_zones(Scope.t()) :: {:ok, [body()]} | error()
  def list_zones(%Scope{} = scope) do
    with {:ok, %{"result" => zones}} <- request(scope, :get, "/zones") do
      {:ok, List.wrap(zones)}
    end
  end

  @doc "Find a zone by name."
  @spec find_zone(Scope.t(), String.t()) :: {:ok, body()} | {:error, :not_found} | error()
  def find_zone(%Scope{} = scope, name) do
    with {:ok, zones} <- list_zones(scope) do
      # Longest zone that covers the name on a label boundary:
      # `uat.app.example.com` lives in `app.example.com` over `example.com`,
      # and `notexample.com` never matches `example.com`.
      zones
      |> Enum.filter(&zone_covers?(&1["name"], name))
      |> Enum.max_by(&String.length(&1["name"]), fn -> nil end)
      |> case do
        nil -> {:error, :not_found}
        zone -> {:ok, zone}
      end
    end
  end

  defp zone_covers?(zone_name, name) when is_binary(zone_name) and is_binary(name) do
    name == zone_name or String.ends_with?(name, "." <> zone_name)
  end

  defp zone_covers?(_, _), do: false

  @doc """
  The account id.

  `GET /accounts` first, the zone list second. The account endpoint answers
  even for a grant with no zones, which is the brand-new-account case setup
  exists to serve; the zone fallback covers a grant scoped to one zone.
  """
  @spec account_id(Scope.t()) :: {:ok, String.t()} | {:error, :no_account_visible} | error()
  def account_id(%Scope{} = scope) do
    case request(scope, :get, "/accounts") do
      {:ok, %{"result" => [%{"id" => id} | _]}} when is_binary(id) -> {:ok, id}
      _ -> account_id_from_zones(scope)
    end
  end

  defp account_id_from_zones(scope) do
    with {:ok, zones} <- list_zones(scope) do
      zones
      |> Enum.find_value(fn zone -> get_in(zone, ["account", "id"]) end)
      |> case do
        nil -> {:error, :no_account_visible}
        id -> {:ok, id}
      end
    end
  end

  ## DNS

  @doc """
  Create a DNS record, unproxied by default.

  `proxied` defaults to false: a proxied record breaks HTTP-01 issuance while
  looking correct in the dashboard.
  """
  @spec create_dns_record(Scope.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, body()} | error()
  def create_dns_record(%Scope{} = scope, zone_id, name, content, opts \\ []) do
    # MX records need a priority (Cloudflare rejects one without), and Resend
    # only receives when its MX is the lowest-priority record for the name.
    payload =
      %{
        type: Keyword.get(opts, :type, "A"),
        name: name,
        content: content,
        ttl: Keyword.get(opts, :ttl, 60),
        proxied: Keyword.get(opts, :proxied, false)
      }
      |> maybe_put(:priority, Keyword.get(opts, :priority))

    request(scope, :post, "/zones/#{zone_id}/dns_records", json: payload)
  end

  defp priority_matches?(_existing, nil), do: true
  defp priority_matches?(existing, priority), do: existing["priority"] == priority

  defp update_dns_record(scope, zone_id, id, name, content, opts) do
    payload =
      %{
        type: Keyword.get(opts, :type, "A"),
        name: name,
        content: content,
        ttl: Keyword.get(opts, :ttl, 60),
        proxied: Keyword.get(opts, :proxied, false)
      }
      |> maybe_put(:priority, Keyword.get(opts, :priority))

    request(scope, :put, "/zones/#{zone_id}/dns_records/#{id}", json: payload)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "DNS records in a zone."
  @spec list_dns_records(Scope.t(), String.t()) :: {:ok, [body()]} | error()
  def list_dns_records(%Scope{} = scope, zone_id) do
    with {:ok, %{"result" => records}} <- request(scope, :get, "/zones/#{zone_id}/dns_records") do
      {:ok, List.wrap(records)}
    end
  end

  @doc """
  Create the record only if an identical name/type pair is absent; update it
  when the content differs.

  Idempotent so a retried DNS step converges rather than stacking duplicate
  records on the same name.
  """
  @spec ensure_dns_record(Scope.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, body()} | error()
  def ensure_dns_record(%Scope{} = scope, zone_id, name, content, opts \\ []) do
    type = Keyword.get(opts, :type, "A")

    with {:ok, records} <- dns_records_for(scope, zone_id, opts) do
      case Enum.find(records, &(&1["name"] == name and &1["type"] == type)) do
        nil ->
          create_dns_record(scope, zone_id, name, content, opts)

        # Same content: adopted (teardown leaves it alone) unless priority or
        # proxy differs, which updates it — for MX a different priority is not
        # the same record.
        %{"content" => ^content} = existing ->
          reconcile_matching_record(scope, zone_id, name, content, opts, existing)

        %{"id" => id} ->
          update_dns_record(scope, zone_id, id, name, content, opts)
      end
    end
  end

  # `:records` lets a caller writing several records into one zone list it
  # once, which also keeps the call count stable for sequential cassettes.
  defp dns_records_for(scope, zone_id, opts) do
    case Keyword.fetch(opts, :records) do
      {:ok, records} -> {:ok, records}
      :error -> list_dns_records(scope, zone_id)
    end
  end

  defp reconcile_matching_record(scope, zone_id, name, content, opts, existing) do
    proxy_matches =
      not Keyword.has_key?(opts, :proxied) or
        existing["proxied"] == Keyword.get(opts, :proxied)

    if priority_matches?(existing, Keyword.get(opts, :priority)) and proxy_matches do
      {:ok, %{"result" => Map.put(existing, "__adopted__", true)}}
    else
      update_dns_record(scope, zone_id, existing["id"], name, content, opts)
    end
  end

  @doc """
  Delete a DNS record. Teardown only — setup never destroys.

  Exists so live tests can remove what they published.
  """
  @spec delete_dns_record(Scope.t(), String.t(), String.t()) :: {:ok, body()} | error()
  def delete_dns_record(%Scope{} = scope, zone_id, record_id) do
    request(scope, :delete, "/zones/#{zone_id}/dns_records/#{record_id}")
  end

  ## Credential check

  @doc "Whether the grant can reach the account."
  @spec credential_valid?(Scope.t()) :: boolean()
  def credential_valid?(%Scope{} = scope), do: match?({:ok, _}, list_zones(scope))

  ## Internals

  @doc """
  Make an arbitrary authenticated Cloudflare API call.

  Public so `CodeMySpec.McpServers.Devops.Tools.ProviderRequest` can make ad
  hoc calls for an agent without the token ever leaving this process.
  """
  @spec request(Scope.t(), atom(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def request(scope, method, path, opts \\ []) do
    case access_token(scope) do
      {:ok, token} ->
        [
          method: method,
          url: @api_base <> path,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/json"}
          ]
        ]
        |> Keyword.merge(opts)
        |> Keyword.merge(plug_opt())
        |> Req.request()
        |> handle_response()

      # Passed through: a connected-but-unusable grant must surface, not fall
      # back to another account's configured token.
      {:error, reason} ->
        {:error, reason}

      :error ->
        {:error, :cloudflare_not_connected}
    end
  end

  # Cloudflare answers 200 with success:false for some failures, so status
  # alone is not enough to decide.
  defp handle_response({:ok, %Req.Response{status: status, body: %{"success" => false} = body}}),
    do: {:error, {:cloudflare_error, status, body}}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:cloudflare_error, status, body}}

  defp handle_response({:error, reason}), do: {:error, reason}

  defp access_token(%Scope{} = scope) do
    case Integrations.fetch_access_token(scope, :cloudflare) do
      {:ok, token} when is_binary(token) and token != "" ->
        {:ok, token}

      # No integration at all: the environment is the intended source, which
      # is how the CLI and tests supply a credential.
      {:error, :not_found} ->
        configured_token()

      # Connected but unusable: surface it. Falling back to the configured
      # token would quietly use a different account's credential.
      {:error, reason} ->
        {:error, {:cloudflare_token_unusable, reason}}
    end
  end

  defp configured_token do
    case Application.get_env(:code_my_spec, __MODULE__, [])[:api_token] do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> :error
    end
  end

  defp plug_opt do
    case Application.get_env(:code_my_spec, __MODULE__, [])[:plug] do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
