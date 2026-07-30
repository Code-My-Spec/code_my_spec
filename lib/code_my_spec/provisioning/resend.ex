defmodule CodeMySpec.Provisioning.Resend do
  @moduledoc """
  Mail in both directions through the user's own Resend account.

  Hand-written Req client. Credentials come from the delegated OAuth grant in
  `CodeMySpec.Integrations` (see `CodeMySpec.Integrations.Providers.Resend`),
  falling back to a configured API key so cassette recording can run without a
  user scope.

  ## One sending domain per environment

  `sending_domain/2` gives production the bare domain and every other
  environment a subdomain of it — `example.com` and `uat.example.com`. Two
  consequences, and both are the point (criterion 8056): test mail can never
  be mistaken for real mail, and a UAT sending-reputation problem cannot touch
  the domain production depends on.

  ## The apex-versus-send split

  Resend returns BOTH kinds of record from one endpoint, and they belong to
  different stories. Confirmed against a live verified domain:

      resend._domainkey  TXT   outbound — DKIM signing
      send               MX    outbound — bounce handling
      send               TXT   outbound — SPF for the send subdomain
      ""                 MX    INBOUND  — apex, present only when Resend
                                          Inbound is configured

  An earlier draft of this module assumed nothing Resend needs lives at the
  apex. That is false: with inbound enabled the set includes an apex MX. So
  the constraint criterion 8029 encodes is not "no apex records exist" — it is
  that the *sending* setup never touches the apex MX, because inbound delivery
  depends on it and story 974 owns it.

  `sending_records/1` and `inbound_records/1` split them, and
  `sending_avoids_apex?/2` asserts the outbound half is apex-free rather than
  trusting it. The project's own knowledge base warns against deleting apex MX
  during a provider migration; this is where that line is held.

  ## Verification is polled, never assumed

  Publishing records and declaring victory leaves an unverified domain and
  mail that 403s on the first send. `poll_until_verified/3` polls and reports
  how many attempts it took, so the step can show its work.

  When it gives up it does not say "verification timed out" — it returns the
  records the provider is still unhappy with, because the usual cause is a
  typoed DKIM TXT and a bare timeout leaves Sam diffing three records by eye
  (criterion 8027).
  """

  require Logger

  alias CodeMySpec.Integrations
  alias CodeMySpec.Users.Scope

  @api_base "https://api.resend.com"
  @default_region "us-east-1"

  # Verification is usually seconds but resolvers negative-cache, so the
  # ceiling is generous. The caller sees the attempt count either way.
  @default_attempts 20
  @default_interval_ms 3_000

  @type body :: map()
  @type error ::
          {:error, :resend_not_connected}
          | {:error, {:resend_error, integer(), term()}}
          | {:error, term()}

  ## Environment split

  @doc """
  The sending domain for an environment.

  Production sends from the bare domain; everything else from a subdomain of
  it. The subdomain-of relationship is load-bearing — criterion 8056 asserts
  the UAT domain ends with the production one.

  ## Examples

      iex> CodeMySpec.Provisioning.Resend.sending_domain("example.com", "prod")
      "example.com"

      iex> CodeMySpec.Provisioning.Resend.sending_domain("example.com", "uat")
      "uat.example.com"
  """
  @spec sending_domain(String.t(), String.t()) :: String.t()
  def sending_domain(domain, "prod"), do: domain
  def sending_domain(domain, "production"), do: domain
  def sending_domain(domain, environment), do: "#{environment}.#{domain}"

  ## Domains

  @doc "Every domain registered in the account."
  @spec list_domains(Scope.t()) :: {:ok, [body()]} | error()
  def list_domains(%Scope{} = scope) do
    case request(scope, :get, "/domains") do
      {:ok, %{"data" => data}} when is_list(data) -> {:ok, data}
      {:ok, _} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  @doc "Find a registered domain by name."
  @spec find_domain(Scope.t(), String.t()) :: {:ok, body()} | {:error, :not_found} | error()
  def find_domain(%Scope{} = scope, name) do
    with {:ok, domains} <- list_domains(scope) do
      case Enum.find(domains, &(&1["name"] == name)) do
        nil -> {:error, :not_found}
        domain -> {:ok, domain}
      end
    end
  end

  @doc "Register a sending domain. Prefer `ensure_domain/3`."
  @spec create_domain(Scope.t(), String.t(), keyword()) :: {:ok, body()} | error()
  def create_domain(%Scope{} = scope, name, opts \\ []) do
    payload = %{name: name, region: Keyword.get(opts, :region, @default_region)}
    request(scope, :post, "/domains", json: payload)
  end

  @doc """
  Return the sending domain, registering it only if absent.

  Idempotent: re-running the email step finds the existing domain rather than
  registering a duplicate.
  """
  @spec ensure_domain(Scope.t(), String.t(), keyword()) :: {:ok, body()} | error()
  def ensure_domain(%Scope{} = scope, name, opts \\ []) do
    case find_domain(scope, name) do
      {:ok, domain} ->
        Logger.info("[Resend] sending domain #{name} already registered — reusing")
        {:ok, domain}

      {:error, :not_found} ->
        create_domain(scope, name, opts)

      {:error, _} = error ->
        error
    end
  end

  @doc "Fetch a domain by id, including its current record statuses."
  @spec get_domain(Scope.t(), String.t()) :: {:ok, body()} | error()
  def get_domain(%Scope{} = scope, id), do: request(scope, :get, "/domains/#{id}")

  @doc "Ask Resend to re-check DNS for a domain."
  @spec verify_domain(Scope.t(), String.t()) :: {:ok, body()} | error()
  def verify_domain(%Scope{} = scope, id), do: request(scope, :post, "/domains/#{id}/verify")

  ## Records

  @doc """
  The DNS records a domain needs published, as returned by the provider.

  Returned rather than derived: the DKIM public key is generated per domain,
  so anything hand-built here would be wrong.
  """
  @spec records(body()) :: [body()]
  def records(%{"records" => records}) when is_list(records), do: records
  def records(_), do: []

  @doc """
  The outbound half of a record set — DKIM and the bounce/SPF records on the
  `send` subdomain. Excludes anything at the apex.
  """
  @spec sending_records([body()], String.t()) :: [body()]
  def sending_records(records, domain) do
    Enum.reject(records, &apex_name?(&1["name"] || "", domain))
  end

  @doc """
  The inbound half — apex MX. Empty unless Resend Inbound is configured.

  Story 974 owns these. Named here so the sending setup can see what it must
  not disturb.
  """
  @spec inbound_records([body()], String.t()) :: [body()]
  def inbound_records(records, domain) do
    Enum.filter(records, &apex_name?(&1["name"] || "", domain))
  end

  @doc """
  Whether the outbound records leave the apex alone.

  Always true today — Resend puts every sending record on `send.<domain>` or
  `resend._domainkey`. Asserting it is how criterion 8029 stays true if the
  provider ever changes what it asks for, rather than discovering it when
  someone's inbound mail stops.
  """
  @spec sending_avoids_apex?([body()], String.t()) :: boolean()
  def sending_avoids_apex?(records, domain) do
    records
    |> sending_records(domain)
    |> Enum.all?(&(not apex_name?(&1["name"] || "", domain)))
  end

  defp apex_name?(name, domain), do: name in ["@", "", domain]

  @doc """
  Records the provider is not satisfied with.

  This is what a give-up reports instead of "verification timed out" — the
  usual cause is a typoed DKIM TXT, and naming the record turns a diffing
  exercise into a fix (criterion 8027).
  """
  @spec faulted_records(body()) :: [body()]
  def faulted_records(domain) do
    domain
    |> records()
    |> Enum.reject(&(&1["status"] in ["verified", "success"]))
  end

  ## Verification

  @doc """
  Poll until the provider reports the domain verified.

  Returns `{:ok, %{domain: domain, attempts: n, verified_at: dt}}`, or
  `{:error, {:unverified, faulted}}` naming the records still at fault.

  `opts`: `:attempts` (default #{@default_attempts}), `:interval_ms`
  (default #{@default_interval_ms}), and `:sleep` for tests.
  """
  @spec poll_until_verified(Scope.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, {:unverified, [body()]}} | error()
  def poll_until_verified(%Scope{} = scope, domain_id, opts \\ []) do
    max = Keyword.get(opts, :attempts, @default_attempts)
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)

    poll(scope, domain_id, 1, max, interval, sleep)
  end

  defp poll(scope, domain_id, attempt, max, interval, sleep) do
    case get_domain(scope, domain_id) do
      {:ok, %{"status" => "verified"} = domain} ->
        {:ok, %{domain: domain, attempts: attempt, verified_at: DateTime.utc_now()}}

      {:ok, domain} when attempt >= max ->
        {:error, {:unverified, faulted_records(domain)}}

      {:ok, _domain} ->
        sleep.(interval)
        poll(scope, domain_id, attempt + 1, max, interval, sleep)

      {:error, _} = error ->
        error
    end
  end

  ## Credential check

  @doc "Whether the grant can reach the account."
  @spec credential_valid?(Scope.t()) :: boolean()
  def credential_valid?(%Scope{} = scope), do: match?({:ok, _}, list_domains(scope))

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

      :error ->
        {:error, :resend_not_connected}
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:resend_error, status, body}}

  defp handle_response({:error, reason}), do: {:error, reason}

  defp access_token(%Scope{} = scope) do
    case Integrations.get_integration(scope, :resend) do
      {:ok, %{access_token: token}} when is_binary(token) and token != "" -> {:ok, token}
      _ -> configured_key()
    end
  rescue
    _ -> configured_key()
  end

  defp configured_key do
    case Application.get_env(:code_my_spec, __MODULE__, [])[:api_key] do
      key when is_binary(key) and key != "" -> {:ok, key}
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
