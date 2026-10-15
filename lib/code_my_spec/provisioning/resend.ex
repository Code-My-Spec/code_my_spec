defmodule CodeMySpec.Provisioning.Resend do
  @moduledoc """
  Mail in both directions through the user's own Resend account.

  Hand-written Req client. Credentials come from the delegated OAuth grant in
  `CodeMySpec.Integrations` (see `CodeMySpec.Integrations.Providers.Resend`),
  falling back to a configured API key so cassette recording can run without a
  user scope.

  - **One sending domain per environment** (`sending_domain/2`): production
    sends from the bare domain, others from `<env>.<domain>`, so test mail is
    never mistaken for real and UAT reputation cannot touch production.
  - **Sending never touches the apex MX.** Resend returns outbound records
    (DKIM, `send` MX/TXT) and, when receiving is enabled, an inbound apex MX
    from one endpoint. `sending_records/2` / `inbound_records/2` split them.
  - **Verification is triggered and polled**, and a give-up names the
    records Resend rejected rather than "timed out".

  See knowledge/provisioning, "Resend".
  """

  alias CodeMySpec.Provisioning.Wait

  require Logger

  alias CodeMySpec.Integrations
  alias CodeMySpec.Users.Scope

  @api_base "https://api.resend.com"
  @default_region "us-east-1"

  # Usually seconds, but resolvers negative-cache, so the ceiling is generous.
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
  it — the UAT domain ends with the production one.

  ## Examples

      iex> CodeMySpec.Provisioning.Resend.sending_domain("example.com", "prod")
      "example.com"

      iex> CodeMySpec.Provisioning.Resend.sending_domain("example.com", "uat")
      "uat.example.com"
  """
  @spec sending_domain(String.t(), String.t()) :: String.t()
  # The base domain, not the sending host: Resend publishes `send.<domain>`
  # and `resend._domainkey.<domain>` itself.
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
    payload =
      %{name: name, region: Keyword.get(opts, :region, @default_region)}
      |> maybe_put(:capabilities, Keyword.get(opts, :capabilities))

    request(scope, :post, "/domains", json: payload)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
        # Marked adopted so teardown leaves it alone. A domain the inbound step
        # created receiving-only gets sending turned on by PATCH — never
        # delete-and-recreate, which rotates DKIM.
        with {:ok, domain} <- ensure_sending_enabled(scope, domain) do
          {:ok, Map.put(domain, "__adopted__", true)}
        end

      {:error, :not_found} ->
        # Sending only: a receiving-enabled domain reports an apex MX, and this
        # step publishes whatever records the domain reports — onto an apex
        # that may already receive mail elsewhere. `ensure_receiving_domain/3`
        # turns receiving on when an inbox is asked for.
        create_domain(
          scope,
          name,
          Keyword.put_new(opts, :capabilities, %{sending: "enabled"})
        )

      {:error, _} = error ->
        error
    end
  end

  # `capabilities` PATCHes as a whole object, so the domain's own receiving
  # flag is read back and kept. A domain that already sends is not PATCHed.
  defp ensure_sending_enabled(scope, domain) do
    if sending?(domain) do
      {:ok, domain}
    else
      receiving = if receiving?(domain), do: "enabled", else: "disabled"

      with {:ok, _} <-
             request(scope, :patch, "/domains/#{domain["id"]}",
               json: %{capabilities: %{sending: "enabled", receiving: receiving}}
             ) do
        get_domain(scope, domain["id"])
      end
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

  Named here so the sending setup can see what it must not disturb.
  """
  @spec inbound_records([body()], String.t()) :: [body()]
  def inbound_records(records, domain) do
    Enum.filter(records, &apex_name?(&1["name"] || "", domain))
  end

  @doc """
  Whether the outbound records leave the apex alone.

  Always true today. Asserting it keeps the apex safe if the provider ever
  changes what it asks for.
  """
  @spec sending_avoids_apex?([body()], String.t()) :: boolean()
  def sending_avoids_apex?(records, domain) do
    records
    |> sending_records(domain)
    |> Enum.all?(&(not apex_name?(&1["name"] || "", domain)))
  end

  # "At the domain itself". Names come back relative to the **zone**: for
  # `c8033.astralbi.com` in zone `astralbi.com` the apex MX is `c8033`. A
  # domain that is its zone gets `""` or `@`. `send.c8033` stays non-apex.
  defp apex_name?(name, domain) do
    name in ["@", "", domain] or
      (is_binary(name) and name != "" and is_binary(domain) and
         String.starts_with?(domain, name <> "."))
  end

  @doc """
  Ensure a domain exists with receiving enabled.

  Receiving is turned on here, when an inbox is asked for, by
  `PATCH /domains/:id` with `capabilities` (the API accepts it, contrary to
  the docs). Never delete-and-recreate: that rotates the DKIM key of a domain
  that may be sending production mail.

  A domain this creates is `sending: "disabled"`: requesting sending makes
  Resend expect DKIM and the `send.` records, which only the outbound step
  publishes, and the domain then sits `pending` and bounces inbound mail. A
  domain found already sending is left that way.
  """
  @spec ensure_receiving_domain(Scope.t(), String.t(), keyword()) ::
          {:ok, body()} | {:error, term()}
  def ensure_receiving_domain(%Scope{} = scope, name, opts \\ []) do
    case find_domain(scope, name) do
      {:ok, domain} ->
        if receiving?(domain), do: {:ok, domain}, else: enable_receiving(scope, domain, name)

      {:error, :not_found} ->
        create_domain(
          scope,
          name,
          Keyword.put(opts, :capabilities, %{sending: "disabled", receiving: "enabled"})
        )

      {:error, _} = error ->
        error
    end
  end

  # An error rather than a raise, so the step can pause with dashboard
  # instructions. Confirmed with a GET: the PATCH's own body carries no
  # capabilities. Sending is carried through as-is, never forced on.
  defp enable_receiving(%Scope{} = scope, domain, name) do
    id = domain["id"]
    sending = if sending?(domain), do: "enabled", else: "disabled"

    with {:ok, _} <-
           request(scope, :patch, "/domains/#{id}",
             json: %{capabilities: %{sending: sending, receiving: "enabled"}}
           ),
         {:ok, updated} <- get_domain(scope, id),
         true <- receiving?(updated) do
      Logger.info("[Resend] enabled receiving on #{name}")
      {:ok, updated}
    else
      _ -> {:error, {:receiving_disabled, name}}
    end
  end

  @doc "Whether a domain accepts inbound mail."
  @spec receiving?(body()) :: boolean()
  def receiving?(%{"capabilities" => %{"receiving" => "enabled"}}), do: true
  def receiving?(_), do: false

  @doc "Whether a domain can send."
  @spec sending?(body()) :: boolean()
  def sending?(%{"capabilities" => %{"sending" => "enabled"}}), do: true
  def sending?(_), do: false

  @doc "Every webhook on the account."
  @spec list_webhooks(Scope.t()) :: {:ok, [body()]} | error()
  def list_webhooks(%Scope{} = scope) do
    with {:ok, %{"data" => webhooks}} <- request(scope, :get, "/webhooks") do
      {:ok, webhooks}
    end
  end

  @doc """
  Ensure an enabled webhook delivers `email.received` to `endpoint`.

  Resend keeps disabled webhooks in the list, and a disabled one looks
  configured but delivers nothing — so a found disabled webhook is
  re-enabled, not counted as done.
  """
  @spec ensure_webhook(Scope.t(), String.t(), keyword()) :: {:ok, body()} | error()
  def ensure_webhook(%Scope{} = scope, endpoint, opts \\ []) do
    events = Keyword.get(opts, :events, ["email.received"])

    with {:ok, webhooks} <- list_webhooks(scope) do
      case Enum.find(webhooks, &(&1["endpoint"] == endpoint)) do
        nil ->
          request(scope, :post, "/webhooks", json: %{endpoint: endpoint, events: events})

        %{"status" => "enabled"} = webhook ->
          {:ok, webhook}

        %{"id" => id} = webhook ->
          case update_webhook_status(scope, id, "enabled") do
            {:ok, updated} -> {:ok, Map.merge(webhook, updated)}
            {:error, reason} -> {:error, {:webhook_disabled, endpoint, reason}}
          end
      end
    end
  end

  @doc """
  The MX records a receiving domain needs published.

  A receiving domain returns two MX records: `record: "SPF"` on `send`
  (outbound bounce handling) and `record: "Receiving"` at the apex. `type`
  alone cannot tell them apart; publishing the SPF one at the apex breaks
  both directions. Resend only delivers when its MX is the lowest priority
  for the name, so the priority is not advisory.
  """
  @spec mx_records(body()) :: [body()]
  def mx_records(domain) do
    domain
    |> records()
    |> Enum.filter(fn record ->
      String.upcase(to_string(record["type"] || "")) == "MX" and
        to_string(record["record"]) == "Receiving"
    end)
  end

  @doc """
  Set a webhook's status.

  Public because `ensure_webhook/3` needs it, and a live test has to be able
  to create the disabled case.
  """
  @spec update_webhook_status(Scope.t(), String.t(), String.t()) :: {:ok, body()} | error()
  def update_webhook_status(%Scope{} = scope, id, status) do
    request(scope, :patch, "/webhooks/#{id}", json: %{status: status})
  end

  @doc """
  The address a probe sends from for an environment.

  The message has to come from the project's own sending domain; a probe
  that fell back to a platform address would prove nothing.
  """
  @spec probe_from(Scope.t(), String.t()) :: String.t() | nil
  def probe_from(%Scope{active_project: %{domain: base}}, environment)
      when is_binary(base) and base != "" do
    "setup@" <> sending_domain(base, environment)
  end

  def probe_from(_scope, _environment), do: nil

  @doc """
  Send a real message and report what the provider accepted.

  A domain can verify and still refuse to send, so outbound is proven by a
  message leaving. `delivered@resend.dev` is Resend's own sink address.
  """
  @spec send_probe(Scope.t(), String.t(), keyword()) :: {:ok, map()} | error()
  def send_probe(%Scope{} = scope, to, opts \\ []) do
    environment = Keyword.get(opts, :environment, "prod")

    # An explicit `:from` overrides the project's address: the inbound proof
    # must not depend on the domain being verified for sending.
    case Keyword.get(opts, :from) || probe_from(scope, environment) do
      nil ->
        {:error, :no_domain}

      from ->
        payload = %{
          from: from,
          to: [to],
          subject: Keyword.get(opts, :subject, "CodeMySpec setup probe"),
          text: Keyword.get(opts, :text, "Setup sent this to prove the domain can send.")
        }

        with {:ok, %{"id" => id}} <- request(scope, :post, "/emails", json: payload) do
          {:ok, %{id: id, from: from, to: to}}
        end
    end
  end

  @doc """
  Wait until the domain's **inbound** records report verified.

  Not `poll_until_verified/3`: a receiving-only domain stays `pending`
  forever on sending records this step must not publish, while the apex MX —
  the only record that matters for receiving — can be verified.
  """
  @spec await_inbound_verified(Scope.t(), String.t(), String.t(), keyword()) ::
          {:ok, [body()]} | {:error, :never_verified} | error()
  def await_inbound_verified(%Scope{} = scope, domain_id, domain_name, opts \\ []) do
    attempts = Keyword.get(opts, :attempts, 60)
    interval = Keyword.get(opts, :interval_ms, 5_000)

    Enum.reduce_while(1..attempts, {:error, :never_verified}, fn attempt, acc ->
      with {:ok, body} <- get_domain(scope, domain_id),
           inbound <- inbound_records(records(body["data"] || body), domain_name),
           true <- inbound != [] and Enum.all?(inbound, &(&1["status"] == "verified")) do
        {:halt, {:ok, inbound}}
      else
        _ ->
          # Asking is what makes Resend look.
          verify_domain(scope, domain_id)
          if attempt < attempts, do: Wait.sleep(interval)
          {:cont, acc}
      end
    end)
  end

  @doc """
  Messages the account has received, newest first.

  `GET /emails/receiving`: proves inbound without the customer's site being
  deployed, since the message Resend accepted is readable here either way.
  """
  @spec list_received(Scope.t(), keyword()) :: {:ok, [body()]} | error()
  def list_received(%Scope{} = scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    case request(scope, :get, "/emails/receiving?limit=#{limit}") do
      {:ok, %{"data" => data}} when is_list(data) -> {:ok, data}
      {:ok, data} when is_list(data) -> {:ok, data}
      {:ok, _other} -> {:ok, []}
      other -> other
    end
  end

  @doc """
  Take `address` off the account's suppression list, if it is on it.

  A bounce puts its recipient on this list account-wide, and later sends to
  it are dropped as `suppressed`. The inbound step probes a fixed address, so
  one early bounce (before receiving verified) would make it fail forever.
  Absent is success.
  """
  @spec clear_suppression(Scope.t(), String.t()) :: :ok | error()
  def clear_suppression(%Scope{} = scope, address) when is_binary(address) do
    with {:ok, suppressions} <- list_suppressions(scope) do
      suppressions
      |> Enum.filter(&(String.downcase(&1["email"] || "") == String.downcase(address)))
      |> Enum.reduce(:ok, fn %{"id" => id}, acc ->
        case request(scope, :delete, "/suppressions/#{id}") do
          {:ok, _} ->
            Logger.info("[Resend] cleared suppression for #{address}")
            acc

          {:error, _} = error ->
            error
        end
      end)
    end
  end

  @doc "Every address the account is currently refusing to deliver to."
  @spec list_suppressions(Scope.t()) :: {:ok, [body()]} | error()
  def list_suppressions(%Scope{} = scope) do
    case request(scope, :get, "/suppressions") do
      {:ok, %{"data" => data}} when is_list(data) -> {:ok, data}
      {:ok, data} when is_list(data) -> {:ok, data}
      {:ok, _other} -> {:ok, []}
      other -> other
    end
  end

  @doc """
  One received message, with its contents.

  `GET /emails/receiving/:id`. The list endpoint returns `text`/`html` as nil,
  so a message's contents can only be read here.
  """
  @spec get_received(Scope.t(), String.t()) :: {:ok, body()} | error()
  def get_received(%Scope{} = scope, id) when is_binary(id) do
    case request(scope, :get, "/emails/receiving/#{id}") do
      {:ok, %{"data" => data}} when is_map(data) -> {:ok, data}
      {:ok, data} when is_map(data) -> {:ok, data}
      other -> other
    end
  end

  @doc """
  Wait for a message matching `match?` to appear among the received mail.

  Delivery is asynchronous, so this polls. Returns `{:ok, message}` or
  `{:error, :never_arrived}` — configuration that looks right while mail goes
  nowhere is the failure mode the inbound step reports.
  """
  @spec await_received(Scope.t(), (body() -> boolean()), keyword()) ::
          {:ok, body()} | {:error, :never_arrived} | error()
  def await_received(%Scope{} = scope, match?, opts \\ []) do
    # Five minutes by default: a just-published MX has to propagate.
    attempts = Keyword.get(opts, :attempts, 60)
    interval = Keyword.get(opts, :interval_ms, 5_000)

    # `:settle_ms` waits before the first read, so the request count does not
    # depend on how long the mail took — sequential cassettes need the same
    # requests on record and replay. Waits are no-ops on replay.
    case Keyword.get(opts, :settle_ms) do
      nil -> :ok
      ms -> Wait.sleep(ms)
    end

    Enum.reduce_while(1..attempts, {:error, :never_arrived}, fn attempt, acc ->
      keep_waiting_unless_found(scope, match?, attempt, attempts, interval, acc)
    end)
  end

  # One poll. Issues exactly the requests the inline version did, in order:
  # a sequential cassette depends on it.
  defp keep_waiting_unless_found(scope, match?, attempt, attempts, interval, acc) do
    case list_received(scope, limit: 100) do
      {:ok, messages} ->
        case Enum.find(messages, match?) do
          nil -> wait_and_continue(attempt, attempts, interval, acc)
          message -> {:halt, {:ok, message}}
        end

      # A failed read is not a failed delivery. Keep waiting.
      _ ->
        wait_and_continue(attempt, attempts, interval, acc)
    end
  end

  defp wait_and_continue(attempt, attempts, interval, acc) do
    if attempt < attempts, do: Wait.sleep(interval)
    {:cont, acc}
  end

  @doc "Delete a domain. Teardown only — setup never destroys."
  @spec delete_domain(Scope.t(), String.t()) :: {:ok, body()} | error()
  def delete_domain(%Scope{} = scope, id), do: request(scope, :delete, "/domains/#{id}")

  @doc "Delete a webhook. Teardown only — setup never destroys."
  @spec delete_webhook(Scope.t(), String.t()) :: {:ok, body()} | error()
  def delete_webhook(%Scope{} = scope, id), do: request(scope, :delete, "/webhooks/#{id}")

  # Resend has looked at these and rejected them; anything else is not
  # finished checking.
  @rejected ~w(failed failure temporary_failure)
  @settled ~w(verified success) ++ @rejected

  @doc """
  Records the provider has looked at and rejected.

  What a give-up reports instead of "verification timed out" — usually a
  typoed DKIM TXT. Rejected, not merely unverified: correct records Resend
  has not finished checking must not be reported as wrong.
  """
  @spec faulted_records(body()) :: [body()]
  def faulted_records(domain) do
    domain
    |> records()
    |> Enum.filter(&(&1["status"] in @rejected))
  end

  @doc """
  Records the provider has not finished checking.

  Distinct from `faulted_records/1` because the two need opposite responses:
  a rejected record needs fixing, a pending one needs waiting.
  """
  @spec pending_records(body()) :: [body()]
  def pending_records(domain) do
    domain
    |> records()
    |> Enum.reject(&(&1["status"] in @settled))
  end

  ## Verification

  @doc """
  Poll until the provider reports the domain verified.

  Returns `{:ok, %{domain: domain, attempts: n, verified_at: dt}}`,
  `{:error, {:unverified, faulted}}` naming rejected records, or
  `{:error, {:still_verifying, pending}}` when nothing was rejected yet.

  `opts`: `:attempts` (default #{@default_attempts}), `:interval_ms`
  (default #{@default_interval_ms}), and `:sleep` for tests.
  """
  @spec poll_until_verified(Scope.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, {:unverified, [body()]}} | error()
  def poll_until_verified(%Scope{} = scope, domain_id, opts \\ []) do
    max = Keyword.get(opts, :attempts, @default_attempts)
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    sleep = Keyword.get(opts, :sleep, &Wait.sleep/1)

    # Trigger a check first: Resend does not re-check a pending domain on its
    # own. Ignored result: it answers 400 for an already-verified domain.
    _ = verify_domain(scope, domain_id)

    poll(scope, domain_id, 1, max, interval, sleep)
  end

  defp poll(scope, domain_id, attempt, max, interval, sleep) do
    case get_domain(scope, domain_id) do
      {:ok, %{"status" => "verified"} = domain} ->
        {:ok, %{domain: domain, attempts: attempt, verified_at: DateTime.utc_now()}}

      # Fix-something vs wait: all-pending has nothing wrong with it yet.
      {:ok, domain} when attempt >= max ->
        case faulted_records(domain) do
          [] -> {:error, {:still_verifying, pending_records(domain)}}
          faulted -> {:error, {:unverified, faulted}}
        end

      {:ok, _domain} ->
        sleep.(interval)

        # Re-trigger every fifth attempt, since DNS can become visible later.
        if rem(attempt, 5) == 0, do: verify_domain(scope, domain_id)

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

  # Resend allows ten requests a second; a run must not fail on a 429.
  @rate_limit_attempts 5
  @rate_limit_backoff_ms 1_100

  @doc """
  Make an arbitrary authenticated Resend API call.

  Public so `CodeMySpec.McpServers.Devops.Tools.ProviderRequest` can make ad
  hoc calls for an agent without the token ever leaving this process.
  """
  @spec request(Scope.t(), atom(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def request(scope, method, path, opts \\ []) do
    case access_token(scope) do
      {:ok, token} ->
        send_request(token, method, path, opts, @rate_limit_attempts)

      :error ->
        {:error, :resend_not_connected}

      # An unusable grant surfaces ("reconnect Resend"); it never falls back.
      {:error, _reason} = unusable ->
        unusable
    end
  end

  defp send_request(token, method, path, opts, attempts_left) do
    response =
      [
        method: method,
        url: @api_base <> path,
        # Ours is the only retry; Req's own 429 retry stacked under it.
        retry: false,
        headers: [
          {"authorization", "Bearer #{token}"},
          {"content-type", "application/json"}
        ]
      ]
      |> Keyword.merge(opts)
      |> Keyword.merge(plug_opt())
      |> Req.request()

    case response do
      {:ok, %Req.Response{status: 429}} when attempts_left > 1 ->
        Wait.sleep(@rate_limit_backoff_ms)
        send_request(token, method, path, opts, attempts_left - 1)

      other ->
        handle_response(other)
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:resend_error, status, body}}

  defp handle_response({:error, reason}), do: {:error, reason}

  # `fetch_access_token/2`, which refreshes under a lock: Resend tokens live
  # fifteen minutes and the refresh token rotates on every use, so concurrent
  # refreshes can cost the user the whole grant.
  defp access_token(%Scope{} = scope) do
    case Integrations.fetch_access_token(scope, :resend) do
      {:ok, token} when is_binary(token) and token != "" ->
        {:ok, token}

      # No integration at all: the environment is the intended source, which
      # is how the CLI and tests supply a credential.
      {:error, :not_found} ->
        configured_key()

      # Connected but unusable: surface it. Falling back to the configured key
      # would quietly use a different account's credential.
      {:error, reason} ->
        {:error, {:resend_token_unusable, reason}}
    end
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
