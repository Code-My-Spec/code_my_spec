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

  alias CodeMySpec.Provisioning.Wait

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
  # Resend publishes its own record set *under* the domain it is given: the
  # bounce MX and SPF land on `send.<domain>`, DKIM on
  # `resend._domainkey.<domain>`. So the domain handed over here is the base,
  # not the sending host — prefixing it with `send.` produces
  # `send.send.<domain>` and leaves the real records nowhere the spex looks.
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
        # Marked adopted so teardown leaves it alone. Setup found this domain;
        # it did not make it, and removing something a user already had is not
        # cleanup — it is destruction. Resend's capabilities are creation-only,
        # so a delete-and-recreate silently drops inbound mail.
        {:ok, Map.put(domain, "__adopted__", true)}

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

  # "At the domain itself", in either spelling Resend uses.
  #
  # Names come back relative to the **zone**, not to the domain they belong to.
  # For a receiving domain of `c8033.astralbi.com` in zone `astralbi.com` the
  # apex MX arrives as `c8033`, so comparing against the full domain found
  # nothing: `inbound_records/2` returned an empty list, and anything waiting
  # on the inbound records waited forever on a record that was already
  # verified. Observed against a real run.
  #
  # A domain that *is* its zone gets `""` or `@` instead, which is why those
  # were the only cases here before — every domain tested was an apex.
  #
  # `send.c8033` and `resend._domainkey.c8033` stay non-apex: the domain does
  # not begin with either followed by a dot.
  defp apex_name?(name, domain) do
    name in ["@", "", domain] or
      (is_binary(name) and name != "" and is_binary(domain) and
         String.starts_with?(domain, name <> "."))
  end

  @doc """
  Ensure a domain exists with receiving enabled.

  ## Capabilities are set at creation and cannot be changed

  `POST /domains` takes `capabilities: %{sending:, receiving:}` and defaults
  receiving to `"disabled"`. `PATCH /domains/:id` exposes tracking and TLS and
  nothing else — there is no field to turn receiving on afterwards.

  So a domain that already exists with receiving disabled cannot be upgraded
  through the API, and this says so rather than reporting success and leaving
  mail silently undelivered. Deleting and recreating it is not something setup
  will do on its own: the domain may be sending production mail, and
  recreating it rotates the DKIM key.
  """
  @spec ensure_receiving_domain(Scope.t(), String.t(), keyword()) ::
          {:ok, body()} | {:error, term()}
  def ensure_receiving_domain(%Scope{} = scope, name, opts \\ []) do
    case find_domain(scope, name) do
      {:ok, domain} ->
        if receiving?(domain) do
          {:ok, domain}
        else
          {:error, {:receiving_disabled, name}}
        end

      {:error, :not_found} ->
        create_domain(
          scope,
          name,
          Keyword.put(opts, :capabilities, %{sending: "enabled", receiving: "enabled"})
        )

      {:error, _} = error ->
        error
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

  ## Existing-but-disabled is the case that matters

  Resend keeps disabled webhooks in the list, and a disabled one looks
  configured from every angle except the only one that counts: nothing is
  delivered. This account already had exactly that — a `dev.codemyspec.com`
  webhook, subscribed to the right event, disabled. Creating-if-absent would
  have found it, called the step done, and delivered nothing.
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

  ## Filtering on type alone is wrong, and quietly so

  A receiving domain returns **two** MX records, and only one of them is for
  receiving:

      %{"record" => "SPF",       "name" => "send", "value" => "feedback-smtp...amazonses.com"}
      %{"record" => "Receiving", "name" => "",     "value" => "inbound-smtp...amazonaws.com"}

  The first is the bounce/SPF record that belongs on `send.<domain>` and is
  part of *sending*. Publishing it at the apex as though it were the inbound
  MX breaks receiving and sending at once — which is the exact failure
  criterion 8032 exists to prevent. `record` is what distinguishes them;
  `type` does not.

  Resend also will not deliver unless its MX is the **lowest** priority for
  the name, so the priority it hands back is not advisory either.
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

  Public because `ensure_webhook/3` needs it, and because a live test has to
  be able to *create* the disabled case in order to prove the step handles it.
  """
  @spec update_webhook_status(Scope.t(), String.t(), String.t()) :: {:ok, body()} | error()
  def update_webhook_status(%Scope{} = scope, id, status) do
    request(scope, :patch, "/webhooks/#{id}", json: %{status: status})
  end

  @doc """
  The address a probe sends from for an environment.

  Named rather than inlined because criterion 8021 asserts on it: the message
  has to come from Sam's own sending domain, and a probe that quietly fell
  back to a platform address would pass a test that means nothing.
  """
  @spec probe_from(Scope.t(), String.t()) :: String.t() | nil
  def probe_from(%Scope{active_project: %{domain: base}}, environment)
      when is_binary(base) and base != "" do
    "setup@" <> sending_domain(base, environment)
  end

  def probe_from(_scope, _environment), do: nil

  @doc """
  Send a real message and report what the provider accepted.

  Story 969 is proven by a message leaving, not by a domain reading
  "verified" — a domain can verify and still refuse to send if the sending
  identity is wrong, and that failure only shows up on the send.

  `delivered@resend.dev` is Resend's own sink address, so a probe costs
  nothing and lands nowhere real.
  """
  @spec send_probe(Scope.t(), String.t(), keyword()) :: {:ok, map()} | error()
  def send_probe(%Scope{} = scope, to, opts \\ []) do
    environment = Keyword.get(opts, :environment, "prod")

    # An explicit `:from` overrides the project's own sending address. The
    # inbound proof needs it: sending from the domain being configured requires
    # that domain to be verified *for sending*, which is the outbound story's
    # job — so proving an inbox would have depended on outbound already
    # working, and failed with a 403 that says nothing about receiving.
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

  Not `poll_until_verified/3`, which waits on the domain as a whole. A domain
  set up for receiving only sits at `status: "pending"` forever, because its
  sending records — DKIM, and the SPF/MX pair on `send.` — are the outbound
  story's to publish and this step must not touch them (criterion 8029). The
  apex MX can be verified while the domain is pending, and for receiving that
  is the only record that decides anything.

  Waiting on the whole domain meant an inbound setup could never finish: the
  records it owns were right, and it polled for five minutes on records it had
  deliberately left alone.
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
          # Asking is what makes Resend look; without it the records sit
          # unchecked and the poll waits on something nobody triggered.
          verify_domain(scope, domain_id)
          if attempt < attempts, do: Wait.sleep(interval)
          {:cont, acc}
      end
    end)
  end

  @doc """
  Messages the account has received, newest first.

  `GET /emails/receiving`. This is what makes an inbound setup provable without
  the customer's own site being deployed: the webhook posts to their domain,
  which may serve something else entirely or nothing at all, but the message
  Resend accepted is readable here either way.
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
  One received message, with its contents.

  `GET /emails/receiving/:id`. The list endpoint carries metadata only — `text`
  and `html` come back nil there — so "the app can act on this message" cannot
  be answered from it. The same shape as `/domains`, which omits `records`
  until you read a single domain, and the same trap: a caller reading the list
  concludes the body is empty when it simply was not sent.
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

  Delivery is not instant and it is not synchronous with the send — SMTP,
  Resend's own ingestion and the receiving domain's MX all sit in between — so
  this polls rather than reading once and concluding.

  Returns `{:ok, message}` or `{:error, :never_arrived}`. Never arriving is the
  answer the inbound step needs, not an exception: it means the configuration
  looks right and mail still goes nowhere, which is the whole failure mode.
  """
  @spec await_received(Scope.t(), (body() -> boolean()), keyword()) ::
          {:ok, body()} | {:error, :never_arrived} | error()
  def await_received(%Scope{} = scope, match?, opts \\ []) do
    # Five minutes by default, matching what the sending step allows for
    # verification. A receiving domain's MX has just been published, and mail
    # does not route until it propagates — a minute is long enough to conclude
    # "never arrived" about a setup that is merely young.
    attempts = Keyword.get(opts, :attempts, 60)
    interval = Keyword.get(opts, :interval_ms, 5_000)

    # Waited out before the first read rather than between reads, so the number
    # of requests does not depend on how long the mail took.
    #
    # That count is the whole difficulty with recording this. A cassette is
    # matched sequentially — one interaction consumed per request — so a poll
    # that runs eight times while recording and three times on replay puts
    # every later request on the wrong interaction, and story 974 recorded 4/4
    # and replayed 0/4 with thirteen misses. Settling first and reading once
    # makes both sides issue the same requests in the same order.
    #
    # Under a cassette the sleep is a no-op (`:provisioning_waits` is `:none`
    # on replay), so this costs nothing there and buys the recording its time.
    case Keyword.get(opts, :settle_ms) do
      nil -> :ok
      ms -> Wait.sleep(ms)
    end

    Enum.reduce_while(1..attempts, {:error, :never_arrived}, fn attempt, acc ->
      case list_received(scope, limit: 100) do
        {:ok, messages} ->
          case Enum.find(messages, match?) do
            nil ->
              if attempt < attempts, do: Wait.sleep(interval)
              {:cont, acc}

            message ->
              {:halt, {:ok, message}}
          end

        # A read that fails is not a delivery that failed. Keep waiting; the
        # caller learns from the final answer rather than from one bad request.
        _ ->
          if attempt < attempts, do: Wait.sleep(interval)
          {:cont, acc}
      end
    end)
  end

  @doc "Delete a domain. Teardown only — setup never destroys."
  @spec delete_domain(Scope.t(), String.t()) :: {:ok, body()} | error()
  def delete_domain(%Scope{} = scope, id), do: request(scope, :delete, "/domains/#{id}")

  @doc "Delete a webhook. Teardown only — setup never destroys."
  @spec delete_webhook(Scope.t(), String.t()) :: {:ok, body()} | error()
  def delete_webhook(%Scope{} = scope, id), do: request(scope, :delete, "/webhooks/#{id}")

  # Resend has actually looked at these and rejected them. Anything else it
  # has simply not finished checking.
  @rejected ~w(failed failure temporary_failure)
  @settled ~w(verified success) ++ @rejected

  @doc """
  Records the provider has looked at and rejected.

  This is what a give-up reports instead of "verification timed out" — the
  usual cause is a typoed DKIM TXT, and naming the record turns a diffing
  exercise into a fix (criterion 8027).

  Rejected, not merely unverified. Treating every not-yet-verified record as
  faulted inverted the criterion it was written for: a drill published three
  correct records, Resend had not finished checking them inside the 60s poll,
  and setup reported "these records are not as Resend expects" naming all
  three. They verified on their own minutes later. Sending Sam to diff a
  record set that is already right is worse than saying nothing — it is the
  hand-diffing exercise 8027 exists to prevent, aimed at the wrong end.
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
    sleep = Keyword.get(opts, :sleep, &Wait.sleep/1)

    # Ask Resend to look before waiting to see whether it has. It does not
    # re-check a pending domain on its own — verification happens when you
    # trigger it — so polling alone waits out the whole window and then
    # reports a domain unverified whose records were correct the entire time.
    # The result is deliberately ignored: it answers 400 for a domain already
    # verified, which is not a failure of anything.
    _ = verify_domain(scope, domain_id)

    poll(scope, domain_id, 1, max, interval, sleep)
  end

  defp poll(scope, domain_id, attempt, max, interval, sleep) do
    case get_domain(scope, domain_id) do
      {:ok, %{"status" => "verified"} = domain} ->
        {:ok, %{domain: domain, attempts: attempt, verified_at: DateTime.utc_now()}}

      # Which of the two the caller gets decides whether Sam is sent to fix
      # something or to wait. A domain whose records are all still pending has
      # nothing wrong with it yet.
      {:ok, domain} when attempt >= max ->
        case faulted_records(domain) do
          [] -> {:error, {:still_verifying, pending_records(domain)}}
          faulted -> {:error, {:unverified, faulted}}
        end

      {:ok, _domain} ->
        sleep.(interval)

        # Re-trigger periodically rather than every attempt: DNS that was not
        # yet visible on the first check becomes visible later, and a poll
        # that never asks again would miss it.
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

  # Resend allows ten requests a second. Verifying a sending domain per
  # environment polls well past that, and a setup run that dies on a 429 has
  # failed for a reason that has nothing to do with the user's configuration —
  # it just asked too quickly. Backing off is the difference between a
  # provisioning routine and a race.
  @rate_limit_attempts 5
  @rate_limit_backoff_ms 1_100

  defp request(scope, method, path, opts \\ []) do
    case access_token(scope) do
      {:ok, token} ->
        send_request(token, method, path, opts, @rate_limit_attempts)

      :error ->
        {:error, :resend_not_connected}

      # `access_token/1` deliberately surfaces an unusable grant rather than
      # falling through to the environment's key — its comment says so. It had
      # nowhere to surface *to*: this case matched only `{:ok, _}` and
      # `:error`, so a grant that needed reauthorizing raised CaseClauseError
      # from inside a poll, and the spex reported a case clause instead of
      # "reconnect Resend".
      {:error, _reason} = unusable ->
        unusable
    end
  end

  defp send_request(token, method, path, opts, attempts_left) do
    response =
      [
        method: method,
        url: @api_base <> path,
        # Ours is the only retry. Req retries 429 by default, which stacked
        # underneath this loop: every attempt here was silently three attempts
        # and 7s of backoff, so `@rate_limit_attempts` meant nothing and the
        # test suite spent most of its runtime asleep.
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

  # `fetch_access_token/2` rather than reading the stored value: Resend's
  # access tokens live fifteen minutes, so the stored one is dead more often
  # than not. It refreshes under a lock, which matters here more than for any
  # other provider — Resend rotates the refresh token on every use, and two
  # concurrent refreshes can cost the user the whole grant.
  defp access_token(%Scope{} = scope) do
    case Integrations.fetch_access_token(scope, :resend) do
      {:ok, token} when is_binary(token) and token != "" ->
        {:ok, token}

      # No integration at all: the environment is the intended source, which
      # is how the CLI and tests supply a credential.
      {:error, :not_found} ->
        configured_key()

      # Connected but unusable — expired past renewal, or the provider refused
      # the refresh. Falling through to the environment here would quietly use
      # a different account's credential and report success, so the reason has
      # to surface instead.
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
