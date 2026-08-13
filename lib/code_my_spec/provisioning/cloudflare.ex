defmodule CodeMySpec.Provisioning.Cloudflare do
  @moduledoc """
  Domain and DNS against the user's own Cloudflare account.

  Hand-written Req client. Credentials come from the delegated OAuth grant in
  `CodeMySpec.Integrations` (see
  `CodeMySpec.Integrations.Providers.Cloudflare`), falling back to a
  configured API token so cassette recording can run without a user scope.

  ## Registration is the one gate in the epic

  Everything else in setup runs unattended. Registration does not:
  `register_domain/4` requires `confirmed: true` and returns
  `{:error, :confirmation_required}` otherwise. Registrations are
  non-refundable, so an automatic purchase of a name Sam merely typed is money
  he cannot get back (criterion 7990). The guard lives here rather than only
  in the LiveView so no other caller can bypass it.

  ## Three ways a domain step ends, and only one is a failure

  - registered through the API,
  - **adopted** — Sam already owns it, which is an ordinary way in rather than
    an error path (criterion 8052),
  - **paused** with a dashboard errand — the Registrar API is in beta and
    covers only a subset of TLDs, and a missing billing prerequisite is
    likewise not something an API call can fix. Criterion 7993 requires a
    detour, not a wall, and 7994 requires the reason be named rather than
    guessed at.

  `classify_registration_error/1` is what turns a provider error into that
  distinction, and it is deliberately conservative: anything it does not
  recognise stays a hard error rather than being silently downgraded to a
  pause that would tell Sam to go do something undefined.

  ## Records are unproxied, and that is not a preference

  `create_dns_record/5` defaults `proxied: false`. A proxied record terminates
  the HTTP-01 challenge at Cloudflare's edge, so the proxy on Sam's box never
  sees it and certificate issuance hangs with DNS that looks correct
  (criterion 7996). Passing `proxied: true` is possible but never what the
  certificate path wants.

  ## The account id problem

  Zone creation needs an account id and there is no `account.read` scope. The
  id is read off the zone list instead — every zone carries its account. A
  brand-new Cloudflare account with no zones therefore cannot self-serve a
  zone create, which is a real limit of the delegated grant rather than a bug
  here; `account_id/1` returns `{:error, :no_account_visible}` so a caller can
  say so plainly.
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

  ## What Cloudflare will actually tell us

  Verified against the live API rather than the docs: the registrar returns
  full detail — `available`, `can_register`, `current_registrar`, expiry — only
  for domains **already associated with the account**. For any other name it
  returns `{name, supported_tld}` and nothing else:

      astralbi.com        -> available=false, current_registrar="Hostinger, UAB"
      sams-new-thing.com  -> %{"name" => ..., "supported_tld" => true}

  So availability and price are not answerable for a name Sam does not
  already hold. `:unknown` says that, rather than an absent `available` field
  being read as `false` — which is what the earlier version did, quietly
  reporting every new name as taken.

  This is why registering a new name is a dashboard errand rather than an API
  call: the API cannot price it, and setup will not ask Sam to confirm a
  purchase whose cost it could not read.
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

  # Absent is not false. A name Cloudflare says nothing about is one it cannot
  # price or sell through the API — a different answer from "taken", and the
  # difference decides whether Sam is offered a purchase or sent to the
  # dashboard.
  defp availability(%{"available" => true}), do: :available
  defp availability(%{"available" => false}), do: :taken
  defp availability(_), do: :unknown

  ## Registration

  @doc """
  Register a domain. Requires an explicit confirmation.

  `opts` must carry `confirmed: true`. Without it this returns
  `{:error, :confirmation_required}` and makes no request — criterion 7990.
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

  Conservative on purpose: an unrecognised failure stays an error. Downgrading
  an unknown failure to a pause would hand Sam a dashboard errand without
  telling him what to actually do there.
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

  This is the adoption path (criterion 8052) and the idempotence check
  (criterion 7991) at once — a retried step finds the domain already there and
  does not buy a second one.
  """
  @spec owned?(Scope.t(), String.t()) :: {:ok, boolean()} | error()
  def owned?(%Scope{} = scope, name) when is_binary(name) do
    # A domain is an ordinary way in if the account either registered it *or*
    # manages its DNS. The registrar list alone is too narrow: a domain bought
    # elsewhere but run as a Cloudflare zone is one setup can adopt and write
    # records to, and treating it as unknown would send Sam to buy a name he
    # already controls.
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
      # A zone is a registrable domain, but a project's domain need not be one:
      # `app.example.com` is served from the `example.com` zone, and so is
      # `uat.app.example.com`. Matching only exact names meant any subdomain
      # failed with :not_found — which reads as "the domain is not on this
      # account" when the account holds it perfectly well, one level up.
      #
      # Longest match wins: with both `example.com` and `app.example.com` as
      # zones, a record for `uat.app.example.com` belongs in the more specific
      # one. Matching on a label boundary so `notexample.com` never matches
      # `example.com`.
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

  `GET /accounts` first, the zone list second.

  This used to read the zone list alone, on the belief that there is no
  account-read scope. There is — the endpoint answers 200 for a grant with no
  zone visibility at all — and the zones-only path failed for precisely the
  case setup exists to serve: a Cloudflare account with no zones in it yet.
  The failure surfaced as `:no_account_visible`, which reads like a
  permissions problem and is not one.

  The zone fallback stays because it costs a call only when the first path
  returns nothing, and a grant scoped to one zone rather than the account is a
  configuration somebody has.
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

  `proxied` defaults to false deliberately — see the moduledoc. A proxied
  record breaks HTTP-01 issuance while looking correct in the dashboard.
  """
  @spec create_dns_record(Scope.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, body()} | error()
  def create_dns_record(%Scope{} = scope, zone_id, name, content, opts \\ []) do
    # MX records carry a priority and Cloudflare rejects one without it. It is
    # not cosmetic for inbound mail either: Resend only receives when its MX is
    # the lowest-priority record for the name, so a missing or higher value
    # means mail goes somewhere else and nothing reports a problem.
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
  records on the same name — which for an apex record would break inbound mail
  rather than merely being untidy.
  """
  @spec ensure_dns_record(Scope.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, body()} | error()
  def ensure_dns_record(%Scope{} = scope, zone_id, name, content, opts \\ []) do
    type = Keyword.get(opts, :type, "A")

    # `:records` lets a caller writing several records into one zone list it
    # once instead of once per record. Beyond the saved round-trips this makes
    # the call count a function of how many records are written rather than of
    # how many times the zone happened to be listed, which is what a sequential
    # cassette needs in order to replay the same way it recorded.
    with {:ok, records} <-
           (case Keyword.fetch(opts, :records) do
              {:ok, records} -> {:ok, records}
              :error -> list_dns_records(scope, zone_id)
            end) do
      case Enum.find(records, &(&1["name"] == name and &1["type"] == type)) do
        nil ->
          create_dns_record(scope, zone_id, name, content, opts)

        # For MX, identical content at a different priority is NOT the same
        # record: Resend only receives on the lowest-priority MX, so leaving a
        # higher one in place delivers mail somewhere else silently.
        # Already there and already right. Marked as adopted so teardown leaves
        # it alone — a record that predates setup is the user's, not ours.
        %{"content" => ^content} = existing ->
          if priority_matches?(existing, Keyword.get(opts, :priority)) do
            {:ok, %{"result" => Map.put(existing, "__adopted__", true)}}
          else
            update_dns_record(scope, zone_id, existing["id"], name, content, opts)
          end

        %{"id" => id} ->
          payload =
            %{
              type: type,
              name: name,
              content: content,
              ttl: Keyword.get(opts, :ttl, 60),
              proxied: Keyword.get(opts, :proxied, false)
            }
            |> maybe_put(:priority, Keyword.get(opts, :priority))

          request(scope, :put, "/zones/#{zone_id}/dns_records/#{id}", json: payload)
      end
    end
  end

  @doc """
  Delete a DNS record. Teardown only — setup never destroys.

  Exists so live tests can remove what they published; a test that leaves
  records in a production zone is worse than no test.
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

  defp request(scope, method, path, opts \\ []) do
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

      # Passed through, not crashed. `access_token/1` returns this deliberately
      # — a connected-but-unusable grant must not fall back to the environment
      # and quietly use another account's credential — and this had no clause
      # for it, so a token needing reauthorization arrived as
      #
      #   (CaseClauseError) no case clause matching:
      #     {:error, {:cloudflare_token_unusable, :reauthorize_required}}
      #
      # raised from inside `devops_status`, naming the case statement rather
      # than the credential. Every caller here already handles `{:error, _}`.
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

      # Connected but unusable — expired past renewal, or the provider refused
      # the refresh. Falling through to the environment here would quietly use
      # a different account's credential and report success, so the reason has
      # to surface instead.
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
