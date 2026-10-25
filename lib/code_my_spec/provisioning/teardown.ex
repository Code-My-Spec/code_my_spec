defmodule CodeMySpec.Provisioning.Teardown do
  @moduledoc """
  Removes what setup created — and only what setup recorded creating.

  - **Its own module**, because `Provisioning` exposes nothing that destroys:
    the ability has to be reached on purpose.
  - **Resources, not names.** Every function works from the `resources` a
    persisted `Step` recorded; nothing matches by pattern. A resource created
    outside setup is invisible here, which is correct.
  - **Adopted resources are spared**, except a DNS record aimed at a server
    this project owns.
  - **Removal is verified**: each delete is confirmed by re-reading the
    provider, since providers accept a delete and finish it later.

  See knowledge/provisioning, "Teardown".
  """

  alias CodeMySpec.Provisioning.Wait

  require Logger

  alias CodeMySpec.AppInstances
  alias CodeMySpec.Environments
  alias CodeMySpec.Provisioning.{Cloudflare, Hetzner, Resend, Storage}
  alias CodeMySpec.ProvisioningPlan.{Sequence, StepRepository}
  alias CodeMySpec.Repo

  alias CodeMySpec.Users.Scope

  @type outcome :: {:ok, [map()]} | {:error, term()}

  @doc """
  Remove everything a step recorded, and confirm it is gone.

  For a per-environment step (`Sequence.scope/1 == :environment`),
  `opts[:environment]` names which environment's row; nothing defaults to
  every environment. A project-wide step ignores it.

  Returns `{:ok, removed}` when nothing remains, or `{:error, {:left_behind,
  remaining}}` naming what survived. On full success the row is reset to
  `:not_started` with no resources.
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
            # Only what was removed; a skipped adoption is still standing.
            {:ok, for({:ok, r} <- outcomes, do: r)}

          failures ->
            {:error, {:left_behind, Enum.map(failures, fn {:error, r} -> r end)}}
        end
    end
  end

  # A torn-down step is not done: reset it so `verify/3` cannot satisfy itself
  # from a proof recorded against servers that no longer exist. Only on full
  # success — forgetting what a step still owns hides a leak.
  defp forget(scope, key, environment) do
    StepRepository.upsert(scope, key, environment, %{state: :not_started, resources: []})
  end

  @doc """
  Remove an environment and everything provisioning made for it.

  The DNS record goes before the server: Hetzner recycles public IPv4
  addresses, so a record left pointing at a released address is a subdomain
  takeover.

  Returns `{:ok, removed}`, or `{:error, {:left_behind, remaining}, removed}`.
  Without attached runtime receipts, legacy removal reports leftovers and
  removes the plan row. With deployment receipts, the row and receipts remain
  until provider removal is confirmed. Harness-backed instances must first be
  disposed of separately; this path never sends them lifecycle commands.
  """
  @spec environment(Scope.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:error, term(), [map()]}
  def environment(%Scope{} = scope, name, opts \\ []) do
    # Injectable so the ordering can be tested without a real server and DNS
    # record.
    teardown = Keyword.get(opts, :teardown, &__MODULE__.resource/2)

    case Environments.get(scope, name) do
      nil ->
        {:ok, []}

      %{management: :harness} ->
        {:error, :not_provisioned_environment}

      environment ->
        remove_environment(scope, environment, teardown)
    end
  end

  defp remove_environment(scope, environment, teardown) do
    instances = AppInstances.list_for_environment(scope, environment.id)
    resources = environment_resources(environment)

    cond do
      Enum.any?(instances, &(not deployment_receipt?(&1, environment))) ->
        {:error, :environment_in_use}

      instances != [] and not Enum.any?(resources, &(&1.kind == "server")) ->
        {:error, :deployment_removal_unconfirmed}

      true ->
        outcomes = Enum.map(resources, &teardown.(scope, &1))
        finish_environment_removal(scope, environment, instances, outcomes)
    end
  end

  defp deployment_receipt?(instance, environment) do
    instance.persistent and not instance.default and is_nil(instance.working_copy_id) and
      instance.device_id == environment.device_id and is_nil(instance.source_root)
  end

  defp finish_environment_removal(scope, environment, instances, outcomes) do
    removed = for {:ok, resource} <- outcomes, do: resource
    left = for {status, resource} <- outcomes, status in [:error, :skipped], do: resource

    if instances != [] and left != [] do
      {:error, {:left_behind, left}, removed}
    else
      case delete_environment_records(scope, environment, instances) do
        :ok -> removal_result(outcomes, removed)
        {:error, reason} -> {:error, reason, removed}
      end
    end
  end

  defp removal_result(outcomes, removed) do
    case for({:error, resource} <- outcomes, do: resource) do
      [] -> {:ok, removed}
      left -> {:error, {:left_behind, left}, removed}
    end
  end

  defp delete_environment_records(scope, environment, instances) do
    result =
      Repo.transaction(fn ->
        Repo.lock!("deployment-instance:#{environment.id}")
        Enum.each(instances, &delete_deployment_receipt(scope, &1))

        case Environments.delete(scope, environment.name) do
          :ok -> forget_environment(scope, environment.name)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_deployment_receipt(scope, instance) do
    with :ok <- unchanged_deployment_receipt(scope, instance),
         {:ok, stopped} <- AppInstances.record_status(scope, instance, %{status: "down"}),
         {:ok, _} <- AppInstances.delete(scope, stopped) do
      :ok
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp unchanged_deployment_receipt(scope, instance) do
    fields = [
      :environment_id,
      :checked_at,
      :deployment_image,
      :commit,
      :serving_commit,
      :device_id,
      :working_copy_id,
      :source_root,
      :persistent,
      :default
    ]

    case AppInstances.get(scope, instance.id) do
      nil ->
        {:error, :deployment_receipt_changed}

      current ->
        if Map.take(current, fields) == Map.take(instance, fields),
          do: :ok,
          else: {:error, :deployment_receipt_changed}
    end
  end

  # Forget every step's resources that belong to the removed environment.
  # Matched on the `environment=<name>` token in the identifier (so `uat`
  # never takes `uat2`). Resources without a marker belong to the project
  # (firewall, network, ssh key) and are kept.
  defp forget_environment(scope, name) do
    for step <- StepRepository.list(scope) do
      forget_environment_step(scope, step, name)
    end

    :ok
  end

  # A per-environment step's row for this environment goes outright.
  defp forget_environment_step(scope, %{environment: environment, key: key}, name)
       when environment == name do
    StepRepository.delete(scope, key, environment)
  end

  # A project-wide step keeps one row across environments; drop only the
  # resources tagged with this one.
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

  # Ordered: `resource/3` is applied in sequence, DNS record before server.
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

  Returns `{:ok, r}`, `{:skipped, r}` (adopted, left standing) or
  `{:error, r}`. Unknown kinds are an error: a resource this cannot remove
  will be left behind, and saying so is the difference from a silent leak.
  """
  @spec resource(Scope.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def resource(scope, resource, opts \\ [])

  # Adopted, not created: skipped, as its own outcome so a summary cannot
  # count it as removed. Exception: a DNS record aimed at a server this
  # project owns is removed, or the name resolves to whoever gets the
  # address next. See knowledge/provisioning, "Teardown".
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

  # Each stage (credentials, empty, delete, confirm) logs its own failure.
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
      # Deletion is asynchronous: accepted is not gone.
      confirm(r, absent?(fn -> Hetzner.find_server(scope, name) end))
    else
      {:error, :not_found} -> {:ok, r}
      _ -> {:error, r}
    end
  end

  # Removed after its servers; Hetzner refuses while anything is attached,
  # which clears moments later, so it retries.
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
      # Attached to a server that may be mid-deletion: retry.
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

  # The DNS step records one resource per domain but writes the apex and each
  # hostname beneath it, so this removes what `doomed?/4` selects.
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

  # `sending_record`: the DKIM/SPF records the email step wrote to Cloudflare.
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

  # A registered domain is never removed: registration is non-refundable, and
  # turning the option off means "stop managing it".
  def resource(_scope, %{kind: "domain"} = r, _opts), do: {:ok, r}

  # Nothing provider-side to remove: repo/encrypted-store artefacts, or
  # records that a check was made (`*_proof`, `verification`,
  # `age_key_delivery`). Listed so they do not read as leaks.
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

  # Which records this teardown may remove. Below the apex: the subtree.
  # At the zone apex (prod's host is the bare domain): only the exact name,
  # and only records pointing at an address this project owns — the subtree
  # of an apex is the customer's whole zone.
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

  # Whether an adopted DNS record is one setup pointed at a machine of ours:
  # its name is an environment's assigned host, or its recorded address is an
  # environment's current IP (recorded addresses can be stale after a
  # rebuild, so the host is the primary test). A record at an apex only exists
  # if setup passed the apex guard. No environment row means `:none`.
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

  # Injectable so the decision can be tested without real servers.
  defp project_environments(scope, opts) do
    case Keyword.fetch(opts, :project_environments) do
      {:ok, environments} -> environments
      :error -> Environments.list_existing_deployment(scope)
    end
  end

  defp confirm(resource, true), do: {:ok, resource}
  defp confirm(resource, false), do: {:error, resource}

  # Providers finish deletes later, so "gone" is a poll.
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

  # Outlasts the servers it is attached to: `absent?/2` waits up to 20s for a
  # server, so this retries for 30s.
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

  # Shaped like the `find_*` lookups `absent?/2` polls: `:not_found` means
  # gone.
  defp any_record_left(scope, zone_id, doomed) do
    case Cloudflare.list_dns_records(scope, zone_id) do
      {:ok, remaining} -> still_present(remaining, doomed)
      other -> other
    end
  end

  # Confirmed against the same predicate that chose what to delete; at the
  # apex, the records deliberately kept are all "under" it.
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

  # Ceph keeps listing a deleted bucket for a moment.
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

  # On a label boundary: `app.spex.example.com` is under `spex.example.com`,
  # `notspex.example.com` is not.
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

  # Naive (last two labels); callers can pass `:zone` for multi-label
  # suffixes.
  defp registrable(name) do
    name |> String.split(".") |> Enum.take(-2) |> Enum.join(".")
  end
end
