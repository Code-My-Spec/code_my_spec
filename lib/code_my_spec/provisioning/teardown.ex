defmodule CodeMySpec.Provisioning.Teardown do
  @moduledoc """
  Removes what setup created — and only what setup recorded creating.

  ## Why this is its own module

  `Provisioning` deliberately exposes nothing that destroys, and a test asserts
  that. The original reasoning stands: a routine that can destroy is a routine
  nobody runs unattended, and `run/3` is meant to be run unattended. So the
  ability exists, and it is somewhere you have to go on purpose rather than
  something reachable by a typo next to `run/3`.

  ## It destroys resources, not names

  Every function here works from the `resources` recorded on a persisted
  `Step` — the bucket URL, the server name, the DNS record id that setup
  actually wrote down. Nothing matches by pattern or by convention.

  That constraint is the safety property. A teardown that searched for
  `*-prod` buckets would find production; one that can only remove what a step
  recorded can only remove what that step made. It also means a resource
  created outside setup is invisible here, which is the correct answer rather
  than a limitation.

  ## Removal is verified, not assumed

  Each function re-reads from the provider afterwards and reports what is
  still there. Providers accept a delete and take their time about it —
  Hetzner detaches a firewall only once the server is really gone, and Ceph
  answers `DELETE /bucket` with a 409 for about half a minute after the last
  object goes. A teardown that returned on the first acknowledgement would
  leave resources behind that nobody is billing anybody's attention for.
  """

  alias CodeMySpec.Provisioning.Wait

  require Logger

  alias CodeMySpec.Provisioning.{
    Cloudflare,
    EnvironmentRepository,
    Hetzner,
    Resend,
    Sequence,
    StepRepository,
    Storage
  }

  alias CodeMySpec.Users.Scope

  @type outcome :: {:ok, [map()]} | {:error, term()}

  @doc """
  Remove everything a step recorded, and confirm it is gone.

  For a step that runs independently per environment (`Sequence.scope/1` ==
  `:environment`), `opts[:environment]` names which environment's row —
  required, since tearing down "every environment of this key" by default is
  exactly the silent-broad-action this module's other functions are written
  to refuse. A project-wide step ignores it.

  Returns `{:ok, removed}` when nothing remains, or `{:error, {:left_behind,
  remaining}}` naming what survived. The error case is the one worth having:
  silence here means somebody pays for a resource nobody remembers.
  """
  @spec step(Scope.t(), atom(), keyword()) :: outcome()
  def step(%Scope{} = scope, key, opts \\ []) do
    environment =
      case Sequence.scope(key) do
        :project -> nil
        :environment -> Keyword.get(opts, :environment)
      end

    case StepRepository.get(scope, key, environment) do
      nil ->
        {:ok, []}

      %{resources: resources} ->
        outcomes = Enum.map(resources, &resource(scope, &1, opts))

        case Enum.filter(outcomes, &match?({:error, _}, &1)) do
          [] ->
            forget(scope, key, environment)
            # Only what was removed. A skipped adoption is still standing, and
            # counting it here is how a teardown reports work it did not do.
            {:ok, for({:ok, r} <- outcomes, do: r)}

          failures ->
            {:error, {:left_behind, Enum.map(failures, fn {:error, r} -> r end)}}
        end
    end
  end

  # A torn-down step is not a done step, and until this existed it stayed one.
  # Teardown removed the provider resources and never wrote to the row, so the
  # step kept `state: done` and every resource it had recorded — and `verify/3`
  # reads those.
  #
  # What that cost: the drill's `inbound_proof` survived two teardowns, and on
  # the rebuilt environment `inbound` reported done in 0.2s by adopting a proof
  # earned nine hours earlier against servers that no longer existed. It
  # overrode a real delivery failure from ten minutes before. The proof of an
  # environment cannot outlive the environment (1040172a).
  #
  # Only on full success. A step that left something behind is not undone, and
  # forgetting what it still owns is how a leak becomes invisible.
  defp forget(scope, key, environment) do
    StepRepository.upsert(scope, key, environment, %{state: :not_started, resources: []})
  end

  @doc """
  Remove an environment and everything provisioning made for it.

  ## The order is the safety property

  The DNS record goes first, before the server is released. Hetzner recycles
  public IPv4 addresses between customers, so a record left pointing at a
  released address resolves to whoever is given it next — a subdomain of the
  customer's own domain, under their proxy and TLS config, answering from a
  machine they do not own. Releasing the address first opens that window;
  removing the record first closes it. This is the standard subdomain-takeover
  shape and it arrives by doing nothing rather than by doing something wrong.

  ## It reports what it could not remove

  Returns `{:ok, removed}` when everything named is gone, or
  `{:error, {:left_behind, remaining}, removed}`. The row is deleted either
  way: an environment nobody can see is worse than one whose leftovers are
  named, because the row is the only thing that still knows the host and the
  server to go looking for. What survived is in the error so the caller can
  say so.
  """
  @spec environment(Scope.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, {:left_behind, [map()]}, [map()]}
  def environment(%Scope{} = scope, name, opts \\ []) do
    # Injectable for the same reason `run_step/3` takes `:verify` and
    # `:execute`: the ordering is the claim worth testing, and proving it
    # should not cost a real server and a real DNS record.
    teardown = Keyword.get(opts, :teardown, &__MODULE__.resource/2)

    case EnvironmentRepository.get(scope, name) do
      nil ->
        {:ok, []}

      environment ->
        outcomes = Enum.map(environment_resources(environment), &teardown.(scope, &1))
        EnvironmentRepository.delete(scope, name)
        forget_environment(scope, name)

        removed = for {:ok, r} <- outcomes, do: r
        left = for {:error, r} <- outcomes, do: r
        _skipped = for {:skipped, r} <- outcomes, do: r

        case left do
          [] -> {:ok, removed}
          _ -> {:error, {:left_behind, left}, removed}
        end
    end
  end

  # A resource belonging to an environment that no longer exists is not a
  # resource anybody owns.
  #
  # Deleting the row left every step still claiming that environment's server,
  # database, registry and DNS record — and permanently, because only `step/3`
  # calls `forget/2` and only on full success. Nothing else ever revisits what
  # a step recorded.
  #
  # What that cost is criterion 7969, "Sam reads back what he now owns": the
  # page listed `qa-fixture-project-uat`, `-qa2` and `-prod` as owned when one
  # existed, and a `dns_record` for a name that returned nothing from the
  # zone's own nameservers — with no "(not found)" annotation on any of it, so
  # nothing distinguished the two servers that were gone from the one that was
  # not (92445d6f). Two of the three were not in any provider console, which is
  # exactly what that criterion promises they will be.
  #
  # Matched on the `environment=` the identifiers already carry, tokenised
  # rather than by substring: `environment=uat` must not take `environment=uat2`
  # with it. A resource with no marker is left alone — it belongs to the
  # project rather than to one environment, like the shared firewall, network
  # and ssh key, and those outlive any single environment.
  defp forget_environment(scope, name) do
    for step <- StepRepository.list(scope) do
      forget_environment_step(scope, step, name)
    end

    :ok
  end

  # A step's own row for the environment being removed goes with it outright
  # — no more resources to have belonged to it once the row itself is gone.
  # This is the shape a per-environment step's rows always had once this
  # schema landed (058d20ed's era predates it): the resource list on a row
  # never spans two environments, so there is nothing left to filter.
  defp forget_environment_step(scope, %{environment: environment, key: key}, name)
       when environment == name do
    StepRepository.delete(scope, key, environment)
  end

  # A project-wide step (server, dns, ...) keeps one row across every
  # environment, tagging which resources belong to which — this is the
  # filtering `forget_environment/2` always did, unchanged.
  defp forget_environment_step(scope, %{environment: nil} = step, name) do
    kept = Enum.reject(step.resources, &belongs_to_environment?(&1, name))

    if length(kept) < length(step.resources) do
      StepRepository.upsert(scope, step.key, nil, %{
        resources: Enum.map(kept, &Map.from_struct/1)
      })
    end
  end

  # Another environment's own row — nothing here belongs to the one being
  # removed.
  defp forget_environment_step(_scope, _step, _name), do: :ok

  defp belongs_to_environment?(%{identifier: identifier}, name) when is_binary(identifier) do
    "environment=#{name}" in String.split(identifier)
  end

  defp belongs_to_environment?(_resource, _name), do: false

  # Ordered, not merely listed. `Teardown.resource/3` is called down this list
  # in sequence, so the DNS record has to come before the server.
  defp environment_resources(environment) do
    dns =
      case environment.host do
        host when is_binary(host) and host != "" ->
          [%{kind: "dns_record", location: "cloudflare/#{host}", origin: "created"}]

        _ ->
          []
      end

    server =
      case environment.server_name do
        name when is_binary(name) and name != "" ->
          [%{kind: "server", location: "hetzner/#{name}", origin: "created"}]

        _ ->
          []
      end

    dns ++ server
  end

  @doc """
  Remove one recorded resource.

  Unknown kinds are reported rather than ignored. A resource this does not
  know how to remove is one that will be left behind, and saying so is the
  difference between an incomplete teardown and a silent leak.
  """
  @spec resource(Scope.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def resource(scope, resource, opts \\ [])

  # Adopted, not created. Setup found this and reused it; removing it destroys
  # something the user had before setup ever ran.
  #
  # This is not hypothetical. Teardown deleted a real, long-standing Resend
  # sending domain that `ensure_domain` had merely adopted, and because
  # Resend fixes a domain's capabilities at creation, the recreate that
  # followed silently dropped inbound mail for it. "Only remove what the step
  # recorded" was not a sufficient safety property — a step records what it
  # adopted too.
  #
  # Skipped is its own outcome, not a quiet success. Reporting it as `{:ok, r}`
  # is what let the drill's teardown say "14/14, everything recorded came down"
  # in 9.5 seconds while a `dns_record cloudflare/uat.spex-drill.legwork.ca
  # (adopted)` was never touched — the server really was released, the record
  # really was still live, and the summary could not tell those apart because
  # the two outcomes had the same shape (167394ad).
  #
  # With one exception, and it is the reason that drill mattered. A DNS record
  # aimed at a server this project owns is not something Sam had before setup
  # ran — it is a record setup pointed at a machine, and when that machine is
  # released the name resolves to whoever Hetzner hands the address to next.
  # Sparing it does not preserve something of Sam's; it manufactures the
  # subdomain takeover `environment/3`'s ordering exists to prevent, and then
  # the next build's apex guard reads the record it should have removed as a
  # live site and refuses to repoint it (7f999888).
  def resource(%Scope{} = scope, %{origin: "adopted"} = r, opts) do
    case aimed_at_our_server(scope, r, opts) do
      {:ok, address} ->
        Logger.warning(
          "[Teardown] #{r.location} is recorded adopted, but points at #{address} — a server " <>
            "this project owns. Removing it rather than leaving the name pointing at an " <>
            "address the provider will give to somebody else."
        )

        resource(scope, %{r | origin: "created"}, opts)

      :none ->
        {:skipped, r}
    end
  end

  # Four operations behind one catch-all, which is three too few to debug.
  # Registry buckets survived teardown twice and the only evidence was
  # `{:error, r}` — indistinguishable between credentials that would not
  # resolve, a bucket that would not empty, a delete that was refused, and a
  # delete that succeeded but did not show up in the confirming list. Each
  # stage now says which it was; the outcome is unchanged.
  def resource(%Scope{} = scope, %{kind: "bucket", location: location} = r, opts) do
    bucket = bucket_from(location)

    with {:ok, credentials} <- stage(:credentials, bucket, storage_credentials(scope, opts)),
         :ok <- stage(:empty, bucket, empty_bucket(bucket, credentials, opts)),
         :ok <- stage(:delete, bucket, Storage.delete_bucket(bucket, credentials, opts)) do
      confirm(r, await_gone(bucket, credentials, opts))
    else
      _ -> {:error, r}
    end
  end

  def resource(%Scope{} = scope, %{kind: "server", location: location} = r, _opts) do
    name = after_slash(location)

    with {:ok, %{"id" => id}} <- Hetzner.find_server(scope, name),
         {:ok, _} <- Hetzner.delete_server(scope, id) do
      # Deletion is asynchronous, so "accepted" is not "gone".
      confirm(r, absent?(fn -> Hetzner.find_server(scope, name) end))
    else
      {:error, :not_found} -> {:ok, r}
      _ -> {:error, r}
    end
  end

  # Removed after the servers on it, for the same reason a firewall is: Hetzner
  # refuses to delete a network with something still attached, and the servers
  # may be mid-deletion when this runs. "Attached" is a state that clears
  # itself moments later, so it is worth waiting for rather than reporting.
  def resource(%Scope{} = scope, %{kind: "network", location: location} = r, _opts) do
    name = after_slash(location)

    with {:ok, %{"id" => id}} <- Hetzner.find_network(scope, name),
         {:ok, _} <- Hetzner.delete_network(scope, id) do
      confirm(r, absent?(fn -> Hetzner.find_network(scope, name) end))
    else
      {:error, :not_found} -> {:ok, r}
      _ -> retry_network(scope, name, r)
    end
  end

  def resource(%Scope{} = scope, %{kind: "firewall", location: location} = r, _opts) do
    name = after_slash(location)

    with {:ok, %{"id" => id}} <- Hetzner.find_firewall(scope, name),
         {:ok, _} <- Hetzner.delete_firewall(scope, id) do
      confirm(r, absent?(fn -> Hetzner.find_firewall(scope, name) end))
    else
      {:error, :not_found} -> {:ok, r}
      # A firewall still attached to a live server will not delete, and the
      # server may be mid-deletion. Retrying is the whole reason this waits.
      _ -> retry_firewall(scope, name, r)
    end
  end

  def resource(%Scope{} = scope, %{kind: "ssh_key", identifier: fingerprint} = r, _opts)
      when is_binary(fingerprint) do
    with {:ok, %{"id" => id}} <- Hetzner.find_ssh_key_by_fingerprint(scope, fingerprint),
         {:ok, _} <- Hetzner.delete_ssh_key(scope, id) do
      confirm(r, absent?(fn -> Hetzner.find_ssh_key_by_fingerprint(scope, fingerprint) end))
    else
      {:error, :not_found} -> {:ok, r}
      _ -> {:error, r}
    end
  end

  # The DNS step records one resource per domain but writes a record for the
  # apex *and* one for each hostname under it, so teardown removes everything
  # in the zone at or beneath that name. Without this clause `dns_record` was
  # an unknown kind: every spex that wrote DNS reported "left behind" and left
  # real records pointing at a server that had already been deleted.
  def resource(%Scope{} = scope, %{kind: "dns_record", location: location} = r, opts) do
    name = after_slash(location)

    with {:ok, %{"id" => zone_id} = zone} <- Cloudflare.find_zone(scope, name),
         {:ok, records} <- Cloudflare.list_dns_records(scope, zone_id) do
      doomed = doomed?(scope, name, zone["name"], opts)

      records
      |> Enum.filter(doomed)
      |> Enum.each(&Cloudflare.delete_dns_record(scope, zone_id, &1["id"]))

      confirm(r, absent?(fn -> any_record_left(scope, zone_id, doomed) end))
    else
      {:error, :not_found} -> {:ok, r}
      _ -> {:error, r}
    end
  end

  def resource(%Scope{} = scope, %{kind: kind, location: location} = r, _opts)
      when kind in ["receiving_domain", "sending_domain"] do
    name = after_slash(location)

    with {:ok, %{"id" => id}} <- Resend.find_domain(scope, name),
         {:ok, _} <- Resend.delete_domain(scope, id) do
      confirm(r, absent?(fn -> Resend.find_domain(scope, name) end))
    else
      {:error, :not_found} -> {:ok, r}
      _ -> {:error, r}
    end
  end

  def resource(%Scope{} = scope, %{kind: "webhook", location: endpoint} = r, _opts) do
    with {:ok, hooks} <- Resend.list_webhooks(scope),
         %{"id" => id} <- Enum.find(hooks, &(&1["endpoint"] == endpoint)) do
      Resend.delete_webhook(scope, id)

      {:ok, remaining} = Resend.list_webhooks(scope)
      confirm(r, not Enum.any?(remaining, &(&1["endpoint"] == endpoint)))
    else
      nil -> {:ok, r}
      _ -> {:error, r}
    end
  end

  # `sending_record` belongs here because that is what it is — a Cloudflare
  # record, written by the email step so Resend has something to verify
  # against. Without this clause it fell to the catch-all below, which logs and
  # leaves it: DKIM and SPF records stranded on the user's live domain after
  # the sending domain they belonged to was removed.
  def resource(%Scope{} = scope, %{kind: kind, location: location} = r, opts)
      when kind in ["dns_record", "mx_record", "sending_record"] do
    name = after_slash(location)
    zone_name = Keyword.get(opts, :zone) || registrable(name)

    with {:ok, %{"id" => zone_id}} <- Cloudflare.find_zone(scope, zone_name),
         {:ok, records} <- Cloudflare.list_dns_records(scope, zone_id) do
      matching = Enum.filter(records, &(&1["name"] == name))

      for %{"id" => id} <- matching, do: Cloudflare.delete_dns_record(scope, zone_id, id)

      {:ok, remaining} = Cloudflare.list_dns_records(scope, zone_id)
      confirm(r, not Enum.any?(remaining, &(&1["name"] == name)))
    else
      _ -> {:error, r}
    end
  end

  # A registered domain is never removed. Registration costs money and is not
  # refundable, and "stop managing it" is what turning the option off means —
  # the one place the original setup-only rule still holds outright.
  def resource(_scope, %{kind: "domain"} = r, _opts), do: {:ok, r}

  # Nothing provider-side to remove: these live in the project's own repo or
  # in our encrypted store, and both are removed with the project.
  #
  # `age_key_delivery` is not a resource at all — it records that a key was
  # handed to a process, which is a fact about a run rather than a thing that
  # exists somewhere. Without it here every teardown that followed a deploy
  # reported a leak it could never resolve, which is the noise that makes a
  # real "left behind" easy to skip past.
  # `inbound_proof`, `widget_proof`, `widget_render` and `verification` join
  # them for the same reason: each records that a check was made and what it
  # said. There is nothing at a provider to delete, and having no rule at all
  # meant `inbound_proof` reported as left behind on every teardown that had
  # earned one — noise in the report, and worse, it survived into the next
  # environment and satisfied `verify/3` there (1040172a).
  def resource(_scope, %{kind: kind} = r, _opts)
      when kind in ~w(age_key age_key_delivery callback_credential commit certificate retention
                      restore_proof content deployment monitor dump repository dns_verification
                      inbound_proof widget_proof widget_render verification) do
    {:ok, r}
  end

  def resource(_scope, r, _opts) do
    Logger.error("[Teardown] no rule for #{inspect(r)} — it will be left behind")
    {:error, r}
  end

  ## Internals

  # Which records this teardown may remove, as a predicate.
  #
  # Below the apex it is the subtree, unchanged: the dns step writes a record
  # for the hostname and one for each name beneath it, and removing the lot is
  # what the clause above exists for.
  #
  # **At the apex the subtree is the entire zone**, and that is not a corner
  # case — `prod`'s host *is* the bare domain, because `assign_hosts/2` gives it
  # one. So removing a prod environment deleted every record the customer had:
  # apex, every subdomain, MX, DKIM, SPF. Measured, on a real domain during QA
  # of story 849 — astralbi.com went to zero records, and recovering it took a
  # hand-rebuilt apex and a separate bug fix before the mail records could be
  # republished (ab6029c5).
  #
  # `at_or_under?/2` is not wrong; it is being asked the wrong question. Its
  # label-boundary check stops teardown reaching *outside* the name it was
  # given, and nothing stopped it reaching everything inside — which, for a
  # zone apex, is everything.
  #
  # So at the apex: the exact name only, and only where the record points at an
  # address this project owns. That is the record setup aimed at a machine it is
  # releasing, which is the one that must go or the name resolves to whoever
  # gets the address next. Everything else at the apex belonged to the customer
  # before setup ran. It is also what the dns step's own apex guard already
  # promises the user — it refuses to repoint a resolving apex and says
  # "remove the `prod` environment to leave the apex alone", and that sentence
  # was false in the most expensive possible way.
  defp doomed?(scope, name, zone_name, opts) do
    if apex?(name, zone_name) do
      ours = project_addresses(scope, opts)
      &(&1["name"] == name and &1["content"] in ours)
    else
      &at_or_under?(&1["name"], name)
    end
  end

  defp apex?(name, zone_name), do: is_binary(zone_name) and name == zone_name

  defp project_addresses(scope, opts) do
    scope
    |> project_environments(opts)
    |> Enum.map(& &1.ip)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  # Whether an adopted DNS record is one setup pointed at a machine of ours.
  #
  # Narrow on purpose. "Ignore origin for DNS records" would be the easy
  # version and it breaks domains setup did not build: an apex a customer
  # already had, pointing at Cloudflare's proxy or at a site hosted somewhere
  # else, is exactly the resource the adopted rule exists to spare.
  #
  # Matched on the environment's host, because that is the name setup assigns
  # and therefore the name setup owns. `assign_hosts/2` hands `uat` the name
  # `uat.example.com`; a record there is the dns step's record whatever its
  # content happens to be today.
  #
  # It was matched on the recorded address first, and that was wrong — QA on
  # story 851 caught it on the run that was meant to confirm it. The dns step
  # records `identifier: "5.161.239.73 environment=uat"`, but on a rebuild the
  # identifier keeps the address from the run before: the uat box really was at
  # 49.12.189.154, in the environment row and in Hetzner and in `dig`, while
  # its recorded resource still said 5.161.239.73. So the comparison that was
  # supposed to catch the takeover missed the one live instance of it. The
  # address is kept as a second trigger — when it is current it is direct
  # evidence — but it can no longer be the only one (filed separately).
  #
  # The apex is the case worth stating. `prod`'s host is the domain itself, so
  # a host match would reach a record Sam definitely had first — but the dns
  # step cannot record a resource there without passing the apex guard, which
  # pauses rather than writes whenever the name already resolves to something
  # else. A recorded apex record means setup was given that name deliberately.
  #
  # An environment row that is already gone reads as `:none` and the record is
  # spared, which is today's behaviour. `environment/3` builds its own list
  # with `origin: "created"` and does not come through here at all.
  defp aimed_at_our_server(scope, %{kind: "dns_record", location: location} = r, opts) do
    environments = project_environments(scope, opts)
    host = after_slash(location)

    cond do
      Enum.any?(environments, &(&1.host == host)) ->
        {:ok, host}

      recorded_address(r) in current_addresses(environments) ->
        {:ok, recorded_address(r)}

      true ->
        :none
    end
  end

  defp aimed_at_our_server(_scope, _resource, _opts), do: :none

  defp current_addresses(environments) do
    environments |> Enum.map(& &1.ip) |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp recorded_address(%{identifier: identifier}) when is_binary(identifier) do
    case String.split(identifier, " ", parts: 2) do
      [address | _] -> if address =~ ~r/^\d+\.\d+\.\d+\.\d+$/, do: address
      _ -> nil
    end
  end

  defp recorded_address(_resource), do: nil

  # Injectable for the same reason `environment/3` takes `:teardown`: the
  # decision is the claim worth testing, and proving it should not cost a real
  # server and a real DNS record.
  defp project_environments(scope, opts) do
    case Keyword.fetch(opts, :project_environments) do
      {:ok, environments} -> environments
      :error -> EnvironmentRepository.list_existing(scope)
    end
  end

  defp confirm(resource, true), do: {:ok, resource}
  defp confirm(resource, false), do: {:error, resource}

  # Providers accept a delete and finish it later, so "gone" is a poll rather
  # than a return value.
  defp absent?(lookup, attempts \\ 10) do
    case lookup.() do
      {:error, :not_found} ->
        true

      _ when attempts > 1 ->
        Wait.sleep(2_000)
        absent?(lookup, attempts - 1)

      _ ->
        false
    end
  end

  # Has to outlast the servers it is attached to. Hetzner will not delete a
  # firewall while a server still references it, and server deletion is
  # asynchronous — `absent?/2` waits up to 20s for one to disappear. Retrying
  # for 10s meant the firewall gave up first on every real run, and the criterion
  # 8156 recording left one behind each time: six lookups, five refused deletes,
  # then honestly reported as left behind.
  #
  # 15 attempts at 2s is 30s, comfortably past the servers' own window.
  defp retry_firewall(scope, name, r, attempts \\ 15) do
    case Hetzner.find_firewall(scope, name) do
      {:error, :not_found} ->
        {:ok, r}

      {:ok, %{"id" => id}} when attempts > 1 ->
        deleted_firewall(scope, name, id, r, attempts)

      _ ->
        {:error, r}
    end
  end

  defp retry_network(scope, name, r, attempts \\ 15) do
    case Hetzner.find_network(scope, name) do
      {:error, :not_found} ->
        {:ok, r}

      {:ok, %{"id" => id}} when attempts > 1 ->
        deleted_network(scope, name, id, r, attempts)

      _ ->
        {:error, r}
    end
  end

  # Accepted is not gone, the same distinction the server clause draws.
  # Returning ok on the API's say-so reported a teardown that had not happened,
  # which is the one thing this module exists to prevent.
  # Shaped like the `find_*` calls `absent?/1` polls elsewhere: `:not_found`
  # means gone, anything else means keep waiting. A `case` nested inside the
  # `confirm` call said the same thing three levels deep.
  defp any_record_left(scope, zone_id, doomed) do
    case Cloudflare.list_dns_records(scope, zone_id) do
      {:ok, remaining} -> still_present(remaining, doomed)
      other -> other
    end
  end

  # Confirmed against the same predicate that chose what to delete. Asking
  # `at_or_under?` here instead would never confirm an apex teardown: the
  # records deliberately left standing are all "under" the apex, so a teardown
  # that did exactly the right thing would report itself failed.
  defp still_present(remaining, doomed) do
    if Enum.any?(remaining, doomed),
      do: {:ok, :present},
      else: {:error, :not_found}
  end

  defp deleted_firewall(scope, name, id, r, attempts) do
    case Hetzner.delete_firewall(scope, id) do
      {:ok, _} -> confirm(r, absent?(fn -> Hetzner.find_firewall(scope, name) end))
      _ -> Wait.sleep(2_000) && retry_firewall(scope, name, r, attempts - 1)
    end
  end

  defp deleted_network(scope, name, id, r, attempts) do
    case Hetzner.delete_network(scope, id) do
      {:ok, _} -> confirm(r, absent?(fn -> Hetzner.find_network(scope, name) end))
      _ -> Wait.sleep(2_000) && retry_network(scope, name, r, attempts - 1)
    end
  end

  defp empty_bucket(bucket, credentials, opts) do
    case Storage.list_dumps(bucket, credentials, Keyword.put(opts, :prefix, "")) do
      {:ok, objects} ->
        Storage.delete_objects(bucket, Enum.map(objects, & &1.key), credentials, opts)
        :ok

      _ ->
        :ok
    end
  end

  defp storage_credentials(scope, opts) do
    case Keyword.get(opts, :credentials) || Storage.credentials(scope, opts) do
      :none -> {:error, :no_credentials}
      {:ok, credentials} -> {:ok, credentials}
      credentials when is_list(credentials) -> {:ok, credentials}
    end
  end

  defp stage(name, bucket, result) do
    case result do
      {:ok, _} = ok ->
        ok

      :ok ->
        :ok

      other ->
        Logger.warning("[Teardown] #{name} failed for bucket #{bucket}: #{inspect(other)}")
        other
    end
  end

  # Ceph keeps listing a deleted bucket for a moment, so reading the listing
  # once reported FAILED for deletes that had in fact worked — the leak audit
  # said the same buckets were gone seconds later.
  defp await_gone(bucket, credentials, opts, attempts \\ 10) do
    case Storage.list_buckets(credentials, opts) do
      {:ok, remaining} ->
        cond do
          bucket not in remaining ->
            true

          attempts > 1 ->
            Wait.sleep(Keyword.get(opts, :readiness_interval_ms, 500))
            await_gone(bucket, credentials, opts, attempts - 1)

          true ->
            Logger.warning(
              "[Teardown] deleted #{bucket} and it is still listed — the delete was accepted " <>
                "and did not take effect"
            )

            false
        end

      other ->
        stage(:list, bucket, other)
        false
    end
  end

  defp bucket_from(location), do: location |> String.split("/") |> List.last()

  # `spex.astralbi.com` and `app.spex.astralbi.com` are the step's own records;
  # `notspex.astralbi.com` is somebody else's. Matching on a label boundary is
  # what keeps teardown from reaching outside what the step wrote.
  defp at_or_under?(record_name, name) when is_binary(record_name) and is_binary(name) do
    record_name == name or String.ends_with?(record_name, "." <> name)
  end

  defp at_or_under?(_, _), do: false

  defp after_slash(location) do
    case String.split(location, "/", parts: 2) do
      [_prefix, rest] -> rest
      [only] -> only
    end
  end

  # `mail.example.com` lives in zone `example.com`. Naive on purpose: a
  # multi-label public suffix would need a real list, and every domain setup
  # manages is one it registered or adopted, so the caller can pass `:zone`.
  defp registrable(name) do
    name |> String.split(".") |> Enum.take(-2) |> Enum.join(".")
  end
end
