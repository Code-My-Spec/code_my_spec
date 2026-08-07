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

  alias CodeMySpec.Provisioning.{Cloudflare, Hetzner, Resend, Storage, StepRepository}
  alias CodeMySpec.Users.Scope

  @type outcome :: {:ok, [map()]} | {:error, term()}

  @doc """
  Remove everything a step recorded, and confirm it is gone.

  Returns `{:ok, removed}` when nothing remains, or `{:error, {:left_behind,
  remaining}}` naming what survived. The error case is the one worth having:
  silence here means somebody pays for a resource nobody remembers.
  """
  @spec step(Scope.t(), atom(), keyword()) :: outcome()
  def step(%Scope{} = scope, key, opts \\ []) do
    case StepRepository.get(scope, key) do
      nil ->
        {:ok, []}

      %{resources: resources} ->
        removed = Enum.map(resources, &resource(scope, &1, opts))

        case Enum.filter(removed, &match?({:error, _}, &1)) do
          [] -> {:ok, Enum.map(removed, fn {:ok, r} -> r end)}
          failures -> {:error, {:left_behind, Enum.map(failures, fn {:error, r} -> r end)}}
        end
    end
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
  def resource(_scope, %{origin: "adopted"} = r, _opts), do: {:ok, r}

  def resource(%Scope{} = scope, %{kind: "bucket", location: location} = r, opts) do
    with {:ok, credentials} <- storage_credentials(scope, opts),
         bucket <- bucket_from(location),
         :ok <- empty_bucket(bucket, credentials, opts),
         :ok <- Storage.delete_bucket(bucket, credentials, opts),
         {:ok, remaining} <- Storage.list_buckets(credentials, opts) do
      confirm(r, bucket not in remaining)
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
  def resource(%Scope{} = scope, %{kind: "dns_record", location: location} = r, _opts) do
    name = after_slash(location)

    with {:ok, %{"id" => zone_id}} <- Cloudflare.find_zone(scope, name),
         {:ok, records} <- Cloudflare.list_dns_records(scope, zone_id) do
      records
      |> Enum.filter(&at_or_under?(&1["name"], name))
      |> Enum.each(&Cloudflare.delete_dns_record(scope, zone_id, &1["id"]))

      confirm(
        r,
        absent?(fn ->
          case Cloudflare.list_dns_records(scope, zone_id) do
            {:ok, remaining} ->
              if Enum.any?(remaining, &at_or_under?(&1["name"], name)),
                do: {:ok, :present},
                else: {:error, :not_found}

            other ->
              other
          end
        end)
      )
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
  def resource(_scope, %{kind: kind} = r, _opts)
      when kind in ~w(age_key callback_credential commit certificate retention restore_proof
                      content deployment monitor dump repository dns_verification) do
    {:ok, r}
  end

  def resource(_scope, r, _opts) do
    Logger.error("[Teardown] no rule for #{inspect(r)} — it will be left behind")
    {:error, r}
  end

  ## Internals

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

  defp retry_firewall(scope, name, r, attempts \\ 5) do
    case Hetzner.find_firewall(scope, name) do
      {:error, :not_found} ->
        {:ok, r}

      {:ok, %{"id" => id}} when attempts > 1 ->
        case Hetzner.delete_firewall(scope, id) do
          {:ok, _} -> {:ok, r}
          _ -> Wait.sleep(2_000) && retry_firewall(scope, name, r, attempts - 1)
        end

      _ ->
        {:error, r}
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
