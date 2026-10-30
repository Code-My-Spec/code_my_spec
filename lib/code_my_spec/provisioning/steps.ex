defmodule CodeMySpec.Provisioning.Steps do
  @moduledoc """
  Adapts each provider module to the one shape the sequence runs.

  No two providers share a signature; each asks for what it needs. The
  sequencer needs one call per step, so the adapting happens here once rather
  than bending every provider to a common interface.

  ## Two functions

  - `verify/3` asks the provider whether the resource exists **right now**.
    Never reads persisted state. This is what makes a re-run converge and a
    resource deleted behind setup's back get rebuilt.
  - `run/3` does the work.

  A step that cannot be verified returns `{:ok, :absent}`, which means "run
  it". That is the safe default: running an idempotent step twice is
  harmless, whereas skipping one that was never done is a broken foundation.

  ## Steps with no provider

  A key without a `run/3` clause returns `{:error, {:not_implemented, key}}`,
  so it halts visibly rather than reporting done for work that never happened.
  """

  require Logger

  alias CodeMySpec.{LocalScope, WorkingCopies}

  alias CodeMySpec.{
    AccountSecrets,
    AppInstances,
    Conversations,
    Deploys,
    ExecutionContexts,
    Files,
    Projects,
    ProjectSecrets
  }

  alias CodeMySpec.Devices
  alias CodeMySpec.Devices.Device
  alias CodeMySpec.Generators.DeployBoilerplate
  alias CodeMySpec.Provisioning.TelemetryStep
  alias CodeMySpec.Servers
  alias CodeMySpec.TempFile
  alias CodeMySpec.Utils.MapAccess

  alias CodeMySpec.Environments
  alias CodeMySpec.ExecutionContexts.ExecutionContext

  alias CodeMySpec.Provisioning.{
    Backups,
    Builder,
    Builder.Remote,
    Cloudflare,
    ContentPublishing,
    Database,
    Deploy,
    Dns,
    Hetzner,
    HostBaseline,
    Registry,
    Repository,
    Resend,
    Sops,
    Storage,
    Transport,
    Truncate,
    Wait,
    Widget
  }

  alias CodeMySpec.ProvisioningPlan
  alias CodeMySpec.ProvisioningPlan.StepRepository

  alias CodeMySpec.Users.Scope

  # The access key opens every box the account owns, so it lives at the
  # account grain — see `access_public_key/2`.
  @access_key_public "server_ssh_public_key"
  @access_key_private "server_ssh_private_key"

  # Where the backup script and encrypted env land on the environment's box.
  # Fixed rather than per-run: the systemd unit `bin/backup schedule` installs
  # names it as its WorkingDirectory.
  @backup_dir "/opt/cms-backup"

  @type outcome ::
          {:ok, [map()]}
          | {:paused, String.t()}
          # Paused after making something real; `Provisioning.run_and_record/5`
          # records these so a pause does not leak them.
          | {:paused, String.t(), [map()]}
          | {:error, term()}
          # Failed after creating these; `Provisioning.run_and_record/5`
          # records them.
          | {:error, term(), [map()]}

  @type verdict ::
          {:ok, :satisfied, [map()]}
          | {:ok, :absent}
          | {:error, term()}

  ## Verify

  @doc """
  Whether a step's resource exists according to its provider.

  `{:ok, :absent}` means "not there, run it". Anything a provider cannot
  answer for is treated as absent rather than satisfied — a false "satisfied"
  skips real work, a false "absent" merely repeats an idempotent step.
  """
  @spec verify(atom(), Scope.t(), keyword()) :: verdict()
  # Never satisfied from the provider: the claim is a push, not existence.
  # See knowledge/provisioning/steps, "Verify".
  def verify(:repository, %Scope{} = _scope, _opts), do: {:ok, :absent}

  def verify(:server, %Scope{} = scope, opts) do
    name = server_name(scope, opts)
    environments = environments(scope, opts)

    found =
      for environment <- environments,
          server_name = server_name(scope, opts, environment),
          {:ok, server} <- [Hetzner.find_server(scope, server_name)],
          do: reconcile_environment_server(scope, environment, server_name, server)

    # Satisfied only when every environment has its box, its `DATABASE_URL`
    # and a reachable registry — each is something only this step's `run/3`
    # makes. The registry probe (SSH) runs last, once the cheap checks agree.
    # See knowledge/provisioning/steps, "Verify".
    if length(found) == length(environments) and found != [] and
         Enum.all?(environments, &database_secrets_present?(scope, &1)) and
         registries_reachable?(scope, environments, opts) do
      # The shared firewall and ssh_key are this step's too; a satisfied
      # re-run must still report them.
      {:ok, :satisfied,
       found ++
         found_resource(Hetzner.find_firewall(scope, name), &firewall_resource(name, &1)) ++
         found_resource(Hetzner.find_ssh_key(scope, name), &ssh_key_resource(name, &1))}
    else
      {:ok, :absent}
    end
  end

  def verify(:domain, %Scope{} = scope, _opts) do
    case domain(scope) do
      nil ->
        {:ok, :absent}

      name ->
        case Cloudflare.owned?(scope, name) do
          {:ok, true} -> {:ok, :satisfied, [%{kind: "domain", location: "cloudflare/#{name}"}]}
          {:ok, false} -> {:ok, :absent}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Asked of the Cloudflare zone, not a resolver: does each record still point
  # where this project put it. One zone lookup and one record list.
  def verify(:dns, %Scope{} = scope, opts) do
    with domain when is_binary(domain) <- domain(scope),
         {:ok, selected} <- selected_dns_environments(permitted_hosts(scope, domain), opts),
         [_ | _] <- selected do
      pointable =
        Enum.filter(
          selected,
          &(is_binary(&1.ip) and &1.ip != "" and is_binary(&1.host) and &1.host != "")
        )

      if length(pointable) == length(selected),
        do: verify_dns_records(scope, domain, pointable),
        else: {:ok, :absent}
    else
      nil -> {:ok, :absent}
      [] -> {:ok, :absent}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(:email, %Scope{} = scope, opts) do
    case {domain(scope), mail_environments(scope, opts)} do
      {nil, _} -> {:ok, :absent}
      {base, []} -> verify_no_permitted_mail_environments(scope, base)
      {base, environments} -> verify_sending_domains(scope, base, environments)
    end
  end

  def verify(:secrets, %Scope{} = scope, opts) do
    environments = environments(scope, opts)

    # Satisfied only when every environment has a key that still opens its own
    # file and the boot secrets this step mints. `environments != []` because
    # `Enum.all?/2` on zero environments is true.
    # See knowledge/provisioning/steps, "Verify".
    if environments != [] and Enum.all?(environments, &secrets_ready?(scope, &1)) do
      {:ok, :satisfied, Enum.map(environments, &%{kind: "age_key", location: "secrets/#{&1}"})}
    else
      {:ok, :absent}
    end
  end

  def verify(:tls, %Scope{} = scope, opts) do
    case host(scope, opts) do
      nil ->
        {:ok, :absent}

      h ->
        # An HTTPS request that would fail on a bad certificate, through the
        # same injectable probe `run(:tls, …)` uses — verify runs before run.
        probe = Keyword.get(opts, :probe, &Deploy.probe/2)

        case probe.(h, opts) do
          :ok -> {:ok, :satisfied, [%{kind: "certificate", location: "https://#{h}"}]}
          {:error, _} -> {:ok, :absent}
        end
    end
  end

  # Per environment file, not the project-wide `ProjectSecrets` flag `run/3`
  # also writes — that flag only says it succeeded once, for some environment.
  def verify(:callback_credential, %Scope{} = scope, opts) do
    case environments(scope, opts) do
      [] ->
        {:ok, :absent}

      targets ->
        if Enum.all?(targets, &present?(scope, &1, "CMS_REFRESH_SECRET")) do
          {:ok, :satisfied,
           Enum.map(targets, &%{kind: "callback_credential", location: "encrypted_env/#{&1}"})}
        else
          {:ok, :absent}
        end
    end
  end

  def verify(:inbound, %Scope{} = scope, opts) do
    with name when is_binary(name) <- receiving_domain(scope, opts),
         {:ok, domain} <- Resend.find_domain(scope, name),
         true <- Resend.receiving?(domain),
         {:ok, webhooks} <- Resend.list_webhooks(scope),
         %{"status" => "enabled"} <-
           Enum.find(webhooks, &(&1["endpoint"] == webhook_endpoint(scope, opts))) do
      proven_inbound(scope, opts, name, domain)
    else
      # Anything short of a receiving domain plus an enabled webhook is absent.
      _ ->
        {:ok, :absent}
    end
  end

  def verify(:storage, %Scope{} = scope, opts) do
    environments = environments(scope, opts)
    project = project(scope)

    environments
    |> Enum.reduce_while({:ok, :satisfied, []}, &verify_bucket_for(&1, &2, project, scope, opts))
    |> record_content_bucket_for_primary(scope, opts)
  end

  # Everything else is either cheap to re-run or has no read-back that
  # distinguishes done from not-done without doing the work.
  def verify(_key, _scope, _opts), do: {:ok, :absent}

  # Configured is not proven: only a recorded delivery proof for this
  # Resend domain id (not just its name) satisfies this.
  # See knowledge/provisioning/steps, "Inbound".
  defp proven_inbound(scope, opts, name, domain) do
    case delivery_proof(scope, name) do
      nil ->
        {:ok, :absent}

      proof ->
        if proof_current?(proof, domain["id"]) do
          {:ok, :satisfied,
           [
             %{kind: "receiving_domain", location: "resend/#{name}"},
             %{kind: "webhook", location: webhook_endpoint(scope, opts)},
             proof
           ]}
        else
          {:ok, :absent}
        end
    end
  end

  # Each environment's own credentials: Hetzner lists only the buckets the
  # presented key owns, and environments may have separate keys.
  defp verify_bucket_for(environment, {:ok, :satisfied, acc}, project, scope, opts) do
    bucket = Storage.bucket_name(project, environment)
    env_opts = Keyword.put(opts, :environment, environment)

    case Storage.credentials(scope, env_opts) do
      :none -> {:halt, {:ok, :absent}}
      {:ok, credentials} -> verify_bucket_listed(bucket, credentials, env_opts, acc)
    end
  end

  defp verify_bucket_listed(bucket, credentials, env_opts, acc) do
    case Storage.list_buckets(credentials, env_opts) do
      {:ok, existing} ->
        if bucket in existing do
          {:cont, {:ok, :satisfied, acc ++ [bucket_resource(bucket, env_opts)]}}
        else
          {:halt, {:ok, :absent}}
        end

      {:error, reason} ->
        {:halt, {:error, format(reason)}}
    end
  end

  ## Run

  @doc "Execute a step. See the moduledoc for the shape."
  @spec run(atom(), Scope.t(), keyword()) :: outcome()
  def run(:repository, %Scope{} = scope, opts) do
    project = project(scope)

    if is_nil(env(scope)) do
      {:error, no_environment_message()}
    else
      # Adopt only what setup itself recorded; a repository that predates
      # setup is the user's call.
      # See knowledge/provisioning, "Repository".
      adopt? = ours?(project, opts)

      # Adopting also needs the recorded owner/name: an existing repository
      # need not match the default owner or slug.
      opts =
        opts
        |> Keyword.put_new(:adopt, adopt?)
        |> with_recorded_location(project, adopt?)

      scope
      |> Repository.run(env(scope), project, opts)
      |> record_repository(scope)
      |> repository_outcome()
    end
  end

  # Firewall, ssh key, then servers; each is recorded as soon as it exists so
  # a later failure still returns it (teardown works from what was recorded).
  def run(:server, %Scope{} = scope, opts) do
    # The firewall and the ssh key are the project's, shared by every
    # environment; each environment gets its own box.
    name = server_name(scope, opts)

    with :ok <- storage_credentials_ready(scope, opts),
         {:ok, firewall} <- Hetzner.ensure_firewall(scope, name),
         made = [firewall_resource(name, firewall)],
         {:ok, ssh_key} <- made_or_error(ensure_access_key(scope, name), made),
         made = [ssh_key_resource(name, ssh_key) | made],
         opts <-
           opts
           |> Keyword.put(:firewall_ids, [firewall["id"]])
           |> Keyword.put(:ssh_key_ids, [ssh_key["id"]])
           # This box runs every kamal container and the registry, so it
           # needs Docker from first boot.
           |> Keyword.put_new(:image, "docker-ce") do
      ensure_environment_servers(scope, opts, made)
    else
      {:paused, instructions} -> {:paused, instructions}
      {:error, reason, partial} -> {:error, format(reason), partial}
      {:error, reason} -> {:error, format(reason)}
    end
  end

  def run(:domain, %Scope{} = scope, opts) do
    case domain(scope) do
      nil ->
        {:error, "no domain set on the project — set one before running the domain step"}

      name ->
        case Cloudflare.ensure_domain(scope, name, opts) do
          # `origin: "adopted"` keeps teardown from destroying a domain setup
          # found.
          {:ok, :adopted} ->
            {:ok, [%{kind: "domain", location: "cloudflare/#{name}", origin: "adopted"}]}

          {:ok, _body} ->
            {:ok, [%{kind: "domain", location: "cloudflare/#{name}"}]}

          {:paused, instructions} ->
            {:paused, instructions}

          # `opts` never carries `confirmed: true` here, so this always means
          # the account does not hold `name`. Paused: buying it is the user's
          # errand, and resume re-verifies.
          {:error, :confirmation_required} ->
            {:paused, not_owned_message(name)}

          {:error, reason} ->
            {:error, format(reason)}
        end
    end
  end

  def run(:dns, %Scope{} = scope, opts) do
    # The zone lookup is injectable so refusing to move a live apex can be
    # tested without a real zone.
    with name when is_binary(name) <- domain(scope),
         {:ok, zone} <- find_dns_zone(scope, name, opts),
         # `[_ | _]`: an empty list would report done having published
         # nothing. Empty means the devops level filtered out every row.
         {:ok, environments} <- selected_dns_environments(permitted_hosts(scope, name), opts),
         [_ | _] <- environments,
         {:ok, resources} <- dns_records_for(scope, zone, environments, opts) do
      record_client_api_url(scope, environments, opts)
      {:ok, resources}
    else
      nil ->
        {:error, "no domain set on the project"}

      [] ->
        {:error, no_permitted_environments_message(scope)}

      # Passed through: "your apex is live" is a question for the operator,
      # not a failure.
      {:paused, message, partial} ->
        {:paused, message, partial}

      {:paused, message} ->
        {:paused, message}

      {:error, reason, partial} ->
        {:error, format(reason), partial}

      {:error, reason} ->
        {:error, format(reason)}
    end
  end

  def run(:email, %Scope{} = scope, opts) do
    # `base_domain/2` rather than `domain/1`, so a caller's domain override
    # reaches this step like its neighbours.
    case {base_domain(scope, opts), mail_environments(scope, opts)} do
      {nil, _} -> {:error, "no domain set on the project"}
      {base, []} -> run_no_permitted_mail_environments(scope, base)
      {base, environments} -> register_sending_domains(scope, base, environments, opts)
    end
  end

  # Required before the app can boot. Checked before deploying, because a
  # crashed release does not name the missing secret.
  @required_secrets ~w(SECRET_KEY_BASE DATABASE_URL)

  # Every environment the project has, unless the caller names one — the
  # sequence runs each step once.
  def run(:deploy, %Scope{} = scope, opts) do
    case deploy_ready(scope) do
      :ok ->
        case Keyword.fetch(opts, :environment) do
          {:ok, environment} -> deploy_environment(scope, environment, opts)
          :error -> deploy_environments(scope, environments(scope, opts), opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run(:content, %Scope{} = scope, opts) do
    # Resources carry what `ContentPublishing.run/2` proved, shaped like the
    # other proofs: claim in `kind`, subject in `location`, evidence in
    # `identifier`.
    case content_proof_target(scope, opts) do
      {:ok, opts} ->
        s3_delivery = deliver_s3_credentials(scope, opts)

        case publish_content(scope, opts) do
          {:ok, resources} -> {:ok, s3_delivery ++ resources}
          {:error, reason, resources} -> {:error, reason, s3_delivery ++ resources}
        end

      {:nothing_to_publish, message} ->
        {:ok, [%{kind: "content", location: message}]}

      {:not_publishable, missing} ->
        {:paused, not_publishable_message(missing)}
    end
  end

  def run(:widget, %Scope{} = scope, opts) do
    # `Widget.run/3` `fetch!`es both; supplying them here turns a missing
    # domain into an errored step instead of a crashed run.
    project = project(scope)

    with {:ok, site} <-
           require_value(Keyword.get(opts, :site_url) || site_url(scope, opts), "a domain"),
         {:ok, key} <-
           require_value(
             Keyword.get(opts, :deploy_key) || Map.get(project, :deploy_key),
             "a deploy key"
           ) do
      opts =
        opts
        |> Keyword.put(:site_url, site)
        |> Keyword.put(:deploy_key, key)
        # `Widget.message_proof/2` `fetch!`es this.
        |> Keyword.put_new(:lookup, &widget_messages(&1, site))

      # Resources carry `Widget.run/3`'s render check and message proof.
      case Widget.run(scope, env(scope), opts) do
        %{state: :proven} = result ->
          {:ok, Enum.reject([widget_render(result), widget_proof(result)], &is_nil/1)}

        # Installed with no message yet: paused, not errored. Only a visitor's
        # browser can send the proving message; resuming re-checks.
        %{state: :not_proven} = result ->
          {:paused, awaiting_first_message(site), Enum.reject([widget_render(result)], &is_nil/1)}

        %{reason: reason} = result ->
          {:error, reason, Enum.reject([widget_render(result)], &is_nil/1)}
      end
    end
  end

  def run(:secrets, %Scope{} = scope, opts) do
    environments = environments(scope, opts)
    env = env(scope)

    # An empty environment list would report done having minted nothing.
    case {environments, Sops.available?()} do
      {[], _} ->
        {:error, no_permitted_environments_message(scope)}

      {_, false} ->
        {:paused,
         "sops and age are not installed on this machine. Install them " <>
           "(brew install sops age), then resume — setup cannot encrypt secrets without them."}

      {_, true} ->
        generate_keys(scope, env, environments)
    end
  end

  def run(:tls, %Scope{} = scope, opts) do
    # kamal-proxy issues during deploy; this step verifies it happened. The
    # probe is injectable so tests need no live host.
    probe = Keyword.get(opts, :probe, &Deploy.probe/2)

    case tls_targets(scope, opts) do
      :no_domain ->
        {:error, "no domain set on the project — nothing to issue a certificate for"}

      # Distinct from `:no_domain` so the message names the real gap: the
      # devops level filtered out every environment.
      :no_permitted_environments ->
        {:error, no_permitted_environments_message(scope)}

      {:ok, targets} ->
        verify_certificates(scope, targets, probe, opts)
    end
  end

  def run(:callback_credential, %Scope{} = scope, opts) do
    environments = environments(scope, opts)
    env = env(scope)
    secret = Keyword.get(opts, :secret) || random_secret()

    # Written as ciphertext in place; the plaintext never reaches the tree.
    environments
    |> Enum.reduce_while(:ok, fn environment, _acc ->
      # `ensure_age_key` mints the key if the secrets step has not run yet.
      with {:ok, key} <- ensure_age_key(scope, env, environment),
           :ok <- Sops.put_secret(env, environment, "CMS_REFRESH_SECRET", secret, key) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok ->
        ProjectSecrets.put_value(scope, "cms_refresh_secret", secret)

        # Register its digest so /api/token can redeem it.
        CodeMySpec.AppTokens.put_refresh_secret(project(scope), secret)

        {:ok,
         Enum.map(environments, fn e ->
           # Observable form of "the user never handles the credential".
           %{
             kind: "callback_credential",
             location: "encrypted_env/#{e}",
             identifier: "placed_in=encrypted_env manual=false"
           }
         end)}

      {:error, reason} ->
        {:error, format(reason)}
    end
  end

  def run(:inbound, %Scope{} = scope, opts) do
    endpoint = webhook_endpoint(scope, opts)

    with name when is_binary(name) <- receiving_domain(scope, opts),
         # Before any provider call: an address on another domain cannot
         # succeed. A missing address is not checked here — records publish
         # first (MX propagation is slow) and the step pauses afterwards.
         :ok <- probe_address_on_domain(name, opts),
         {:ok, domain} <- Resend.ensure_receiving_domain(scope, name, opts),
         {:ok, webhook} <- Resend.ensure_webhook(scope, endpoint, opts),
         {:ok, secret_resources} <- seed_webhook_secret(scope, webhook),
         {:ok, mx} <- publish_mx(scope, name, domain, opts),
         # Await the inbound records, not the whole domain — a receiving-only
         # domain stays `pending` on sending records this step leaves alone.
         # See knowledge/provisioning/steps, "Inbound".
         {:ok, _inbound} <- Resend.await_inbound_verified(scope, domain["id"], name, opts),
         {:ok, proof} <- prove_delivery(scope, name, domain["id"], opts) do
      {:ok,
       [
         %{kind: "receiving_domain", location: "resend/#{name}"},
         %{kind: "webhook", location: endpoint, identifier: webhook["id"]}
       ] ++ mx ++ secret_resources ++ [proof]}
    else
      nil ->
        {:error, "no domain set on the project — nothing to receive mail at"}

      {:error, {:receiving_disabled, name}} ->
        {:paused,
         "#{name} exists in Resend with receiving disabled, and turning it on was refused. " <>
           "Setup asks for it directly (PATCH /domains/:id accepts capabilities), so this " <>
           "means the provider said no rather than that it cannot be asked. " <>
           "Enable receiving for #{name} in the Resend dashboard, then resume. " <>
           "Setup will not delete and recreate the domain: that rotates its DKIM key " <>
           "and would break sending until DNS caught up."}

      # Paused: nothing to send the probe from is a decision, not a failure.
      {:error, :no_verified_sender} ->
        {:paused,
         "the inbound records are published, but proving delivery means sending a message to " <>
           "this domain and the account has no verified sending domain to send it from. " <>
           "Verify one — the email step does this — then resume."}

      # Paused: Resend accepts mail only at configured addresses and has no
      # API to list them, so the user must name one.
      {:error, :no_probe_address} ->
        {:paused,
         "the inbound records are published. To prove mail actually arrives, setup needs an " <>
           "address on this domain that you already receive at — Resend only accepts mail to " <>
           "addresses configured for the domain, and offers no way to ask which those are, so " <>
           "setup will not guess one. Give it an address and resume."}

      {:error, {:probe_address_elsewhere, to, name}} ->
        {:paused,
         "#{to} is not on #{name}, so delivering to it would prove nothing about this " <>
           "domain's inbox — mail to another domain arrives whether or not this one is " <>
           "configured. Give an address at #{name} and resume."}

      # An existing MX elsewhere would be replaced, not added to. Paused like
      # `apex_repoint/4`: the user's decision.
      {:error, {:competing_mx, record_name, current}} ->
        {:paused,
         "#{record_name} already has an MX record pointing at #{current}, and publishing " <>
           "Resend's here would replace it rather than add alongside it — if mail for this " <>
           "name already routes through #{current}, that redirects or breaks it silently. " <>
           "Confirm to publish anyway, or resolve it at the provider first."}

      # Paused: the likeliest cause is an address Resend silently drops, which
      # only a person can fix. Resuming re-sends and re-checks.
      {:error, :never_arrived} ->
        {:paused,
         "the records are published and Resend is configured, but the message sent to this " <>
           "domain never arrived. Check first that the address it was sent to is configured " <>
           "to receive in Resend — an address the domain does not accept is dropped in " <>
           "silence and looks exactly like this, and Resend offers no way to ask. Otherwise: " <>
           "configuration that looks right is how a receiving setup fails, because the MX, " <>
           "Resend's receiving capability and the webhook all have to be right together and " <>
           "each can look correct alone. Fix whichever it is and resume."}

      {:error, reason} ->
        {:error, format(reason)}
    end
  end

  def run(:storage, %Scope{} = scope, opts) do
    environments = environments(scope, opts)
    project = project(scope)

    environments
    |> Enum.reduce_while({:ok, []}, &ensure_bucket_with_credentials(&1, &2, project, scope, opts))
    |> record_content_bucket_for_primary(scope, opts)
  end

  # Every environment, like `run(:storage, ...)`. A defaulted single
  # environment would report done having backed up only one.
  # See knowledge/provisioning/steps, "Lessons".
  def run(:backups, %Scope{} = scope, opts) do
    environments = environments(scope, opts)
    project = project(scope)

    environments
    |> Enum.reduce_while({:ok, []}, fn environment, {:ok, acc} ->
      bucket = Storage.bucket_name(project, environment)
      # Per environment: environments may have separate Hetzner keys.
      env_opts = Keyword.put(opts, :environment, environment)

      case Storage.credentials(scope, env_opts) do
        :none ->
          {:halt, {:paused, Storage.credentials_instructions(scope.active_project_id)}}

        {:ok, credentials} ->
          back_up_environment(scope, environment, env_opts, bucket, credentials, acc)
      end
    end)
  end

  # One collector per environment: every permitted one, or just the one the
  # caller names.
  def run(:telemetry, %Scope{} = scope, opts) do
    case Keyword.fetch(opts, :environment) do
      {:ok, environment} -> TelemetryStep.run(scope, environment, opts)
      :error -> telemetry_for_environments(scope, environments(scope, opts), opts)
    end
  end

  # Named rather than silently succeeding — see the moduledoc.
  def run(key, _scope, _opts), do: {:error, {:not_implemented, key}}

  # Per-environment credentials, as in `verify_bucket_for/5`.
  defp ensure_bucket_with_credentials(environment, {:ok, acc}, project, scope, opts) do
    env_opts = Keyword.put(opts, :environment, environment)

    case Storage.credentials(scope, env_opts) do
      :none ->
        # Hetzner issues object-storage keys only in the console; pause and
        # re-check on resume.
        {:halt, {:paused, Storage.credentials_instructions(scope.active_project_id)}}

      {:ok, credentials} ->
        ensure_bucket_for(environment, {:ok, acc}, project, credentials, env_opts)
    end
  end

  defp back_up_environment(scope, environment, env_opts, bucket, credentials, acc) do
    # `bin/backup` decrypts the env file itself; sops reads its identity
    # from `SOPS_AGE_KEY`, which `put_age_key/3` supplies.
    environment_opts =
      env_opts
      |> Keyword.put(:bucket, bucket)
      |> Keyword.put(:credentials, credentials)
      |> put_age_key(scope, environment)
      |> put_database_url(scope, environment)
      |> put_restore_admin_url(scope, environment)
      |> Keyword.put_new(:scratch_database, Database.scratch_database(scope, environment))

    with :ok <- require_script(scope, "bin/backup"),
         {:ok, environment_opts} <-
           on_the_environments_box(scope, environment, environment_opts),
         {:ok, resources} <-
           backups_outcome(
             Backups.run(env(scope), environment, environment_opts),
             bucket,
             environment
           ) do
      {:cont, {:ok, acc ++ resources}}
    else
      # What was already dumped is named in the failure. Nothing in the
      # `with` can pause.
      {:error, reason} -> {:halt, {:error, reason, acc}}
    end
  end

  @doc """
  Bring up one account-owned server, ready for any project to link onto:
  the box itself, its private network, plus the shared registry and
  database containers every project's environment will find already
  running when it links here.

  The only path that may reach `Hetzner.create_server/3` — the account-level
  provisioning tool or the servers page, never a project's own devops step
  (`server_creation_gate/3` refuses that path).

  The private network belongs to the box, like the registry and database
  containers; a project's `:server` step only adopts it, never creates one.
  The SSH key is the account's (`Servers.access_key/1`). Firewalls stay
  project-scoped, attached by the project's `:server` step.
  See knowledge/provisioning/steps, "Account servers and networks".
  """
  @spec provision_account_server(Scope.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def provision_account_server(%Scope{} = scope, name, opts \\ []) when is_binary(name) do
    with {:ok, ssh_key_ids} <- Servers.access_key(scope),
         opts = Keyword.put_new(opts, :ssh_key_ids, ssh_key_ids),
         {:ok, server} <- Hetzner.ensure_server(scope, name, opts),
         public when is_binary(public) <- get_in(server, ["public_net", "ipv4", "ip"]),
         {:ok, server, _network} <- ensure_account_network(scope, server),
         {:ok, opts} <- with_builder_ssh(scope, opts),
         run = Keyword.get(opts, :run) || Remote.ssh_runner(%{"ip" => public}, opts),
         :ok <- await_box(run, opts),
         :ok <- HostBaseline.ensure(run),
         box_opts = Keyword.put(opts, :run, run),
         {:ok, _registry} <- Registry.ensure_container(scope, box_opts),
         {:ok, _database} <- Database.ensure_container(scope, box_opts) do
      {:ok, server}
    else
      {:error, reason} -> {:error, format(reason)}
      _ -> {:error, "the server has no address yet"}
    end
  end

  @doc "Repair existing tenant database privileges on an account-owned server."
  @spec repair_database_isolation(Scope.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def repair_database_isolation(%Scope{} = scope, name, opts \\ []) do
    with {:ok, server} <- Hetzner.find_server(scope, name),
         public when is_binary(public) <- get_in(server, ["public_net", "ipv4", "ip"]),
         {:ok, opts} <- with_builder_ssh(scope, opts) do
      run = Keyword.get(opts, :run) || Remote.ssh_runner(%{"ip" => public}, opts)
      Database.repair_existing(scope, Keyword.put(opts, :run, run))
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :server_address_missing}
    end
  end

  # Adopts the box's own network (by id off its `private_net`, never by a
  # guessed name), creating one for its zone only when it has none.
  # `__adopted__` marks the found branch: teardown deletes anything unmarked.
  defp ensure_account_network(scope, server) do
    case existing_network_id(scope, server) do
      {:ok, network_id} ->
        with {:ok, network} <- Hetzner.find_network_by_id(scope, network_id) do
          {:ok, server, Map.put(network, "__adopted__", true)}
        end

      :error ->
        # No re-fetch after attach: nothing here reads the private IP off
        # `server`.
        with {:ok, network} <- create_account_network(scope, server),
             {:ok, _attached} <- Hetzner.attach_to_network(scope, server["id"], network["id"]) do
          {:ok, server, network}
        end
    end
  end

  # `codemyspec-<zone>`: the box may serve several projects. The index comes
  # from every network the account has — Hetzner refuses any overlapping range.
  defp create_account_network(scope, server) do
    zone = server |> get_in(["location", "name"]) |> Hetzner.network_zone()
    index = next_available_network_index(scope)
    Hetzner.ensure_network(scope, "codemyspec-#{zone}", network_zone: zone, network_index: index)
  end

  defp next_available_network_index(scope) do
    used =
      case Hetzner.list_networks(scope) do
        {:ok, networks} ->
          networks |> Enum.map(&network_index_of/1) |> Enum.reject(&is_nil/1) |> MapSet.new()

        _ ->
          MapSet.new()
      end

    Enum.find(0..255, &(not MapSet.member?(used, &1)))
  end

  defp network_index_of(%{"ip_range" => "10.0.0.0/16"}), do: 0

  defp network_index_of(%{"ip_range" => "10." <> rest}) do
    case Integer.parse(rest) do
      {n, ".0.0/16"} -> n
      _ -> nil
    end
  end

  defp network_index_of(_network), do: nil

  # The deployed app's `Content.PullClient` reads the bucket with its own S3
  # credentials (the bucket is not world-readable), so the project row's four
  # S3 values go into each encrypted env. Best-effort: no credentials yet
  # means an earlier step already paused.
  # See knowledge/provisioning/steps, "Content and widget".
  defp deliver_s3_credentials(scope, opts) do
    project = project(scope)
    env = env(scope)

    with true <- not blank?(project.aws_access_key_id),
         environments <- environments(scope, opts),
         true <- environments != [] do
      Enum.flat_map(environments, &put_s3_credentials(scope, env, &1, project))
    else
      _ -> []
    end
  end

  defp put_s3_credentials(scope, env, environment, project) do
    # Bare host: ExAws composes `:host` with a separate `:scheme`.
    host = project.s3_endpoint |> to_string() |> String.replace_leading("https://", "")

    with {:ok, key} <- ensure_age_key(scope, env, environment),
         :ok <-
           Sops.put_secret(
             env,
             environment,
             "HETZNER_S3_ACCESS_KEY_ID",
             project.aws_access_key_id,
             key
           ),
         :ok <-
           Sops.put_secret(
             env,
             environment,
             "HETZNER_S3_SECRET_ACCESS_KEY",
             project.aws_secret_access_key,
             key
           ),
         :ok <- Sops.put_secret(env, environment, "HETZNER_S3_ENDPOINT", host, key),
         :ok <- Sops.put_secret(env, environment, "HETZNER_S3_REGION", project.aws_region, key) do
      [
        %{
          kind: "s3_credential_delivery",
          location: "encrypted_env/#{environment}",
          identifier: "placed_in=encrypted_env manual=false"
        }
      ]
    else
      _ -> []
    end
  end

  # Supplies what `ContentPublishing.verify_render/2` `fetch!`es: `:path`
  # (`/<content_type>/<slug>`, as `cms_gen.content` routes), `:expect` (the
  # title — a 200 alone passes on a styled 404) and `:site_url`
  # (`client_api_url`). No content yet is the normal state of a new app, not
  # a failure.
  defp content_proof_target(%Scope{active_project: project} = scope, opts) do
    with :error <- proof_from_opts(opts),
         :ok <- ContentPublishing.ensure_publishable(scope),
         [_ | _] = rows <- publishable_content(scope) do
      row = hd(rows)
      meta = row.metadata || %{}

      {:ok,
       opts
       |> Keyword.put(:path, "/#{meta["content_type"] || "blog"}/#{meta["slug"]}")
       |> Keyword.put(:site_url, project.client_api_url)
       |> Keyword.put(:expect, meta["title"] || meta["slug"])}
    else
      {:ok, _opts} = supplied -> supplied
      {:error, {:not_publishable, missing}} -> {:not_publishable, missing}
      [] -> {:nothing_to_publish, "no content to publish yet"}
    end
  end

  # A missing `content_bucket` points back at the storage step, which writes
  # it — rather than reporting done with nothing published.
  defp not_publishable_message(missing) do
    "Content publishing needs #{Enum.join(missing, ", ")} before it can run. " <>
      if :content_bucket in missing do
        "content_bucket is written automatically once the storage step finishes " <>
          "provisioning a bucket — resume that step, then this one will re-check."
      else
        "Set it on the project's Content settings, then resume."
      end
  end

  defp proof_from_opts(opts) do
    case {Keyword.get(opts, :path), Keyword.get(opts, :expect)} do
      {path, expect} when is_binary(path) and is_binary(expect) -> {:ok, opts}
      _ -> :error
    end
  end

  # Fully qualified: the aliased `ContentPublishing` is the provisioning one;
  # the snapshot rows belong to the top-level context of the same name.
  defp publishable_content(scope) do
    scope
    |> CodeMySpec.ContentPublishing.list_snapshot()
    |> Enum.filter(
      &(&1.parse_status == :success and (&1.metadata || %{})["slug"] not in [nil, ""])
    )
  end

  defp publish_content(scope, opts) do
    # `:environment` in step opts is the deployment's name, not a file runtime.
    opts = Keyword.put_new_lazy(opts, :runtime, fn -> env(scope) end)

    case ContentPublishing.run(scope, opts) do
      %{state: :rendered} = result ->
        {:ok, [content_proof(result) | content_objects(result)]}

      %{state: state, published: published, reason: reason} ->
        # Uploaded-then-failed-to-render differs from never-uploaded; the
        # objects are kept so the page can say the files are there.
        {:error, reason,
         [content_failure(state, reason, published) | content_objects(%{published: published})]}
    end
  end

  ## Client-facing configuration
  #
  # `content_bucket`, `client_api_url` and `deploy_key` are written by setup,
  # not typed by a user: the content and widget steps refuse without them, and
  # setup already knows all three. `deploy_key` is minted at the secrets step
  # (`seed_deploy_key/2`), before the deploy that carries it.

  # Recorded on both the verify-satisfied and run paths (a standing bucket
  # never reaches `run/3`), and only when unset — a project's own bucket wins.
  defp record_content_bucket_for_primary({:ok, :satisfied, _resources} = outcome, scope, opts) do
    write_content_bucket_for_primary(scope, opts)
    outcome
  end

  defp record_content_bucket_for_primary({:ok, _resources} = outcome, scope, opts) do
    write_content_bucket_for_primary(scope, opts)
    outcome
  end

  defp record_content_bucket_for_primary(other, _scope, _opts), do: other

  # Publishing needs one key pair: the primary environment's own.
  defp write_content_bucket_for_primary(scope, opts) do
    case primary_environment(scope, opts) do
      environment when is_binary(environment) ->
        env_opts = Keyword.put(opts, :environment, environment)

        case Storage.credentials(scope, env_opts) do
          {:ok, credentials} -> write_content_bucket(scope, credentials, opts)
          :none -> :ok
        end

      nil ->
        :ok
    end
  end

  # Bucket, endpoint, region and keys are written together: ExAws with no
  # endpoint defaults to Amazon, and a bucket name at the wrong endpoint fails
  # naming the bucket, not the host.
  # See knowledge/provisioning/steps, "Content and widget".
  defp write_content_bucket(scope, credentials, opts) do
    project = project(scope)
    location = Keyword.get(credentials, :region) || Keyword.get(opts, :location, "fsn1")

    with true <- blank?(Map.get(project, :content_bucket)),
         environment when is_binary(environment) <- primary_environment(scope, opts) do
      Projects.update_project(scope, project, %{
        content_bucket: Storage.bucket_name(project, environment),
        s3_endpoint: "https://#{location}.your-objectstorage.com",
        aws_region: location,
        # The keys that made the bucket. `ProjectSecrets` holds them for
        # provisioning; publishing signs from these (`aws_*` in name only).
        aws_access_key_id: Keyword.get(credentials, :access_key_id),
        aws_secret_access_key: Keyword.get(credentials, :secret_access_key)
      })
    end

    :ok
  end

  # Where the content step fetches a published post back from. Written at the
  # DNS step, which assigns the names; only when unset.
  defp record_client_api_url(scope, environments, opts) do
    project = project(scope)
    primary = primary_environment(scope, opts)

    with true <- blank?(Map.get(project, :client_api_url)),
         %{host: host} when is_binary(host) and host != "" <-
           Enum.find(environments, &(&1.name == primary)) do
      Projects.update_project(scope, project, %{client_api_url: "https://#{host}"})
    end

    :ok
  end

  # The one environment `content_bucket` and `client_api_url` both describe,
  # so a render is proven against objects in the same site's bucket. Prod when
  # present, else the first environment.
  defp primary_environment(scope, opts) do
    environments = environments(scope, opts)

    if "prod" in environments, do: "prod", else: List.first(environments)
  end

  # Production sends mail; nothing else does.
  # See knowledge/provisioning/steps, "Email".
  defp mail_environments(scope, opts) do
    Enum.filter(environments(scope, opts), &(&1 in ["prod", "production"]))
  end

  # Sending domains at Resend for prod rows the devops level no longer
  # permits — left behind when the level narrowed after a run.
  defp mail_orphans(scope, base) do
    # A project that has only ever selected UAT has no sending domain to
    # reconcile. Its owned domain alone is not a reason to query Resend.
    case StepRepository.get(scope, :email) do
      %{resources: resources} when is_list(resources) ->
        if Enum.any?(resources, &(&1.kind == "sending_domain")) do
          for environment <- Environments.deployment_names(scope),
              environment in ["prod", "production"],
              sending = Resend.sending_domain(base, environment),
              match?({:ok, _}, Resend.find_domain(scope, sending)) do
            sending
          end
        else
          []
        end

      _ ->
        []
    end
  end

  # Satisfied only when no orphan exists; an orphan sends this to `run/3`.
  defp verify_no_permitted_mail_environments(scope, base) do
    case mail_orphans(scope, base) do
      [] -> {:ok, :satisfied, []}
      _orphans -> {:ok, :absent}
    end
  end

  # Pauses naming each orphan: it can neither be registered nor ignored.
  defp run_no_permitted_mail_environments(scope, base) do
    case mail_orphans(scope, base) do
      [] ->
        {:ok, []}

      orphans ->
        {:paused,
         "#{Enum.join(orphans, ", ")} already exists at Resend from an earlier run, but " <>
           "this project's devops level no longer permits sending for that environment. " <>
           "Resolve or remove it at the provider before this step can report done."}
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # The key still opens its file, and every secret this step mints is there.
  defp secrets_ready?(scope, environment) do
    key_opens_its_own_file?(scope, environment) and
      match?({:ok, false}, secret_key_base_missing?(scope, env(scope), environment)) and
      Enum.all?(minted_secrets(), &present?(scope, environment, &1))
  end

  # What `generate_keys/3` puts in the encrypted env besides
  # `SECRET_KEY_BASE`. Add every newly minted secret here, or verify will
  # skip the run that writes it.
  # See knowledge/provisioning/steps, "Lessons".
  defp minted_secrets, do: ["DEPLOY_KEY", "CODEMYSPEC_WIDGET_URL"]

  # Absent only when the file opens and the value is not in it; anything
  # unreadable is reported by `key_opens_its_own_file?/2`.
  defp present?(scope, environment, name) do
    with {:ok, private} <- fetch_age_key(scope, environment),
         {:ok, missing} <- Sops.missing_secrets(env(scope), environment, private, [name]) do
      name not in missing
    else
      _ -> true
    end
  end

  # Whether the stored private key produces a recipient the environment's file
  # was encrypted to — derived, since the file records only the public half.
  defp key_opens_its_own_file?(scope, environment) do
    with {:ok, private} <- ProjectSecrets.fetch_value(scope, age_key_name(environment)),
         true <- is_binary(private) and private != "" do
      case Sops.recipients(env(scope), environment) do
        {:ok, [_ | _] = recipients} ->
          recipient?(private, recipients)

        # No readable recipient (e.g. no file yet): not drift, so the key's
        # presence is the answer.
        _ ->
          true
      end
    else
      _ -> false
    end
  end

  defp recipient?(private, recipients) do
    case Sops.public_key(private) do
      {:ok, public} -> public in recipients
      _ -> false
    end
  end

  # The proof a previous run recorded for this domain, read rather than
  # re-sent (verify must not mail anyone). Filtered on the address because
  # the step row outlives the domain. Returned as a plain map:
  # `cast_embed(:resources)` raises on a `%Resource{}` struct.
  defp delivery_proof(scope, domain) when is_binary(domain) do
    case StepRepository.get(scope, :inbound) do
      %{resources: resources} when is_list(resources) ->
        resources
        |> Enum.find(&(&1.kind == "inbound_proof" and proof_on_domain?(&1, domain)))
        |> plain_resource()

      _ ->
        nil
    end
  end

  defp delivery_proof(_scope, _domain), do: nil

  # Anchored on `@`, for the same reason `probe_address_on_domain/2` is: a bare
  # suffix would accept `inbox@evil-<domain>`.
  defp proof_on_domain?(%{location: location}, domain) when is_binary(location),
    do: String.ends_with?(location, "@" <> domain)

  defp proof_on_domain?(_resource, _domain), do: false

  defp plain_resource(nil), do: nil

  defp plain_resource(%CodeMySpec.ProvisioningPlan.Resource{} = resource),
    do: Map.from_struct(resource)

  defp plain_resource(resource), do: resource

  # One target per environment host — a certificate belongs to a host. An
  # injected `:host` stands in for the whole list.
  defp tls_targets(scope, opts) do
    case Keyword.get(opts, :host) do
      host when is_binary(host) and host != "" ->
        {:ok, [%{name: nil, host: host}]}

      _ ->
        tls_targets_from_domain(scope)
    end
  end

  defp tls_targets_from_domain(scope) do
    case domain(scope) do
      nil ->
        :no_domain

      name ->
        case scope |> permitted_hosts(name) |> Enum.filter(&is_binary(&1.host)) do
          [] -> :no_permitted_environments
          targets -> {:ok, targets}
        end
    end
  end

  # Halts on the first environment without a certificate, carrying what was
  # already verified.
  defp verify_certificates(scope, targets, probe, opts) do
    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, verified} ->
      case await_certificate(probe, target.host, opts, tls_attempts(opts)) do
        :ok ->
          {:cont, {:ok, verified ++ certificate_resources(target)}}

        {:error, reason} ->
          {:halt, {:error, certificate_error(scope, target, reason, probe, opts), verified}}
      end
    end)
  end

  # Polls: kamal-proxy requests the certificate when the service comes up, so
  # one timed-out probe means "not yet", not "never".
  defp await_certificate(probe, host, opts, attempts) do
    case probe.(host, opts) do
      :ok ->
        :ok

      {:error, _reason} when attempts > 1 ->
        Wait.sleep(Keyword.get(opts, :tls_interval_ms, 5_000))
        await_certificate(probe, host, opts, attempts - 1)

      # The last reason: what the host did on the final attempt is the diagnosis.
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tls_attempts(opts), do: Keyword.get(opts, :tls_attempts, 20)

  # A successful probe implies https, 200 and a valid chain; recorded so the
  # page can show them.
  defp certificate_resources(target) do
    [
      %{kind: "certificate", location: "https://#{target.host}", identifier: tls_tag(target)},
      %{
        kind: "environment_verification",
        location: target.host,
        identifier: "scheme=https status=200 cert_valid=true" <> tls_tag(target)
      }
    ]
  end

  # Diagnoses while the host still exists (teardown destroys it soon after):
  # port 80, the ACME path, DNS and the proxy log, so the message separates
  # failed issuance from unreachability.
  # See knowledge/provisioning/steps, "TLS".
  defp certificate_error(scope, target, reason, probe, opts) do
    "#{target.host} did not answer over HTTPS with a valid certificate (#{format(reason)}). " <>
      "Issuance needs DNS resolving to the server and the proxy reachable on 80. " <>
      plain_http_observation(target.host, probe, opts) <>
      " " <>
      acme_path_observation(target.host, probe, opts) <>
      " " <>
      dns_observation(target.host, reason, opts) <>
      " " <> proxy_log_observation(scope, target, opts)
  end

  # The proxy's own log, read over SSH and folded into the failure.
  # Injectable, and best-effort: diagnosis must never fail the step.
  defp proxy_log_observation(scope, target, opts) do
    reader = Keyword.get(opts, :proxy_log, &read_proxy_log/3)

    case Map.get(target, :ip) do
      ip when is_binary(ip) and ip != "" -> reader.(scope, ip, opts)
      _ -> "No address is recorded for this environment, so its proxy log could not be read."
    end
  end

  # `kamal-proxy list` adds the proxy's believed state, which a log cannot
  # show for a certificate never requested. `|| true` keeps the log when the
  # subcommand is missing.
  @proxy_log_command "docker logs --tail 200 kamal-proxy 2>&1; " <>
                       "echo '--- proxy state ---'; " <>
                       "docker exec kamal-proxy kamal-proxy list 2>&1 || true"

  defp read_proxy_log(scope, ip, opts) do
    case with_builder_ssh(scope, opts) do
      {:ok, ssh_opts} -> run_proxy_log(ip, ssh_opts)
      {:error, reason} -> "The proxy log could not be read (#{format(reason)})."
    end
  end

  defp run_proxy_log(ip, ssh_opts) do
    runner = Remote.ssh_runner(%{"ip" => ip}, ssh_opts)

    case runner.([@proxy_log_command]) do
      {output, 0} -> "kamal-proxy on #{ip} last said: #{tidy_log(output)}"
      {output, status} -> "Reading the proxy log on #{ip} exited #{status}: #{tidy_log(output)}"
    end
  end

  # Compress every line rather than select some: a filter hides the absence
  # it was meant to show. Keeping a few JSON fields makes each line short.
  @log_fields ~w(time level msg error host path status service)

  defp tidy_log(output) do
    output
    |> to_string()
    |> String.split("\n", trim: true)
    |> Enum.take(-40)
    |> Enum.map_join(" | ", &compress_log_line/1)
    |> String.slice(0, 4000)
  end

  defp compress_log_line(line) do
    case Jason.decode(line) do
      {:ok, %{} = entry} -> summarise_entry(entry)
      # Not JSON — a plain line is already as short as it is going to get.
      _ -> String.slice(line, 0, 200)
    end
  end

  defp summarise_entry(entry) do
    @log_fields
    |> Enum.flat_map(fn key -> field_pair(key, Map.get(entry, key)) end)
    |> Enum.join(" ")
  end

  defp field_pair(_key, nil), do: []
  defp field_pair(_key, ""), do: []
  defp field_pair(key, value), do: ["#{key}=#{inspect(value)}"]

  # Whether HTTP-01 can complete: the challenge path must be served on 80, not
  # redirected to HTTPS. An unknown token answering 404 is healthy.
  defp acme_path_observation(host, probe, opts) do
    opts =
      Keyword.merge(opts,
        scheme: :http,
        tls_attempts: 1,
        health_path: "/.well-known/acme-challenge/cms-setup-probe"
      )

    case probe.(host, opts) do
      {:error, "responded 30" <> _} ->
        "The proxy redirects the ACME challenge path to HTTPS instead of " <>
          "serving it, so HTTP-01 validation cannot complete and no " <>
          "certificate will ever be issued."

      {:error, "responded " <> status} ->
        "The proxy serves the ACME challenge path directly (responded " <>
          "#{status}), so HTTP-01 validation can reach it."

      :ok ->
        "The proxy serves the ACME challenge path directly, so HTTP-01 " <>
          "validation can reach it."

      {:error, reason} ->
        "The ACME challenge path could not be reached at all " <>
          "(#{format(reason)})."
    end
  end

  # The probe uses this machine's resolver, which can cache a name's absence;
  # `Dns.resolves_publicly?/3` asks elsewhere, so the two can disagree.
  defp dns_observation(host, reason, opts) do
    resolves? = Dns.resolves_publicly?(host, :a, Keyword.put(opts, :attempts, 1))
    dns_sentence(resolves?, resolution_failure?(reason))
  end

  # Only a failure that named resolution implicates a resolver; a timeout
  # means the name resolved.
  defp resolution_failure?(reason) do
    String.contains?(format(reason), "does not resolve")
  end

  defp dns_sentence(true, true) do
    "A public resolver does return an A record for it, so the record exists " <>
      "and this machine's resolver is holding a stale negative answer."
  end

  defp dns_sentence(true, false) do
    "A public resolver does return an A record for it, so the name is published."
  end

  # Silence may still be propagation, so this does not claim the record is
  # missing.
  defp dns_sentence(false, _resolution_failure?) do
    "Neither public resolver returns an A record for it, so the record is " <>
      "missing or was written too recently to have propagated."
  end

  defp plain_http_observation(host, probe, opts) do
    # Any HTTP status counts as answering — a healthy kamal-proxy serves 301
    # on 80, which `probe/2` reports as an error.
    case probe.(host, Keyword.merge(opts, scheme: :http, tls_attempts: 1)) do
      {:error, "responded " <> status} -> port_80_answered("responded #{status}")
      :ok -> port_80_answered("responded 200")
      {:error, reason} -> port_80_silent(reason)
    end
  end

  defp port_80_answered(what) do
    "Port 80 does answer (#{what}), so the proxy is reachable and issuance " <>
      "itself is what failed — check the proxy's certificate log on the host."
  end

  defp port_80_silent(reason) do
    "Port 80 does not answer either (#{format(reason)}), so this is " <>
      "reachability rather than issuance."
  end

  defp tls_tag(%{name: name}) when is_binary(name), do: " environment=#{name}"
  defp tls_tag(_target), do: ""

  # Send one message and wait for it to arrive, read back from Resend's
  # `GET /emails/receiving` rather than the webhook (which needs the site
  # deployed).
  # See knowledge/provisioning/steps, "Inbound".
  defp prove_delivery(scope, name, domain_id, opts) do
    probe = Keyword.get(opts, :inbound_probe, &default_inbound_probe/3)
    # Through opts, so an injected probe keeps its three-argument contract.
    probe.(scope, name, Keyword.put(opts, :resend_domain_id, domain_id))
  end

  defp default_inbound_probe(scope, _name, opts) do
    # A token in the subject: the account receives real mail too.
    token = "cms-inbound-#{System.unique_integer([:positive])}"

    # The address is given, never invented: Resend silently drops mail to
    # addresses not configured for the domain, and cannot list them.
    # See knowledge/provisioning/steps, "Inbound".
    case Keyword.get(opts, :inbound_probe_to) do
      to when is_binary(to) and to != "" ->
        with {:ok, message} <- send_and_await(scope, to, token, opts) do
          {:ok, inbound_proof(to, message, Keyword.get(opts, :resend_domain_id))}
        end

      _ ->
        {:error, :no_probe_address}
    end
  end

  # On this domain, or the proof is about somebody else's inbox. Anchored on
  # `@`, or `john@evil-<domain>` would pass.
  defp probe_address_on_domain(name, opts) do
    case Keyword.get(opts, :inbound_probe_to) do
      to when is_binary(to) and to != "" ->
        if String.ends_with?(to, "@" <> name),
          do: :ok,
          else: {:error, {:probe_address_elsewhere, to, name}}

      _ ->
        :ok
    end
  end

  @doc """
  Send one message to `to` and wait for it to come back.

  The inbound step's proof, exposed so the page can re-run it on demand after
  setup has said done.

  Returns the received message, merged with its full body when it can be read.
  """
  @spec probe_inbound(Scope.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def probe_inbound(%Scope{} = scope, to, opts \\ []) do
    token = "cms-inbound-#{System.unique_integer([:positive])}"

    with {:ok, message} <- send_and_await(scope, to, token, opts) do
      # The listing carries metadata only; read the message for its body,
      # falling back to the listing since arrival is the primary claim.
      case Resend.get_received(scope, message["id"]) do
        {:ok, full} when is_map(full) -> {:ok, Map.merge(message, full)}
        _ -> {:ok, message}
      end
    end
  end

  @doc """
  Where this environment's registry actually answers, right now.

  The private address on the box's own adopted network
  (`existing_network_id/2`), as `run(:server, …)` and its verify reach it —
  for callers that write it into generated deploy files. Not
  `Registry.default_host/0`: a shared box publishes the registry on a private
  address, not loopback.

  `{:error, :not_provisioned}` covers no linked server and a server with no
  private network yet; the caller falls back to its own default.
  """
  @spec registry_address(Scope.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :not_provisioned}
  def registry_address(%Scope{} = scope, environment, opts \\ []) do
    name = server_name(scope, opts, environment)

    with {:ok, server} <- Hetzner.find_server(scope, name),
         {:ok, network_id} <- existing_network_id(scope, server),
         {:ok, ip} <- Hetzner.private_ip(server, network_id) do
      {:ok, "#{ip}:#{Registry.port()}"}
    else
      _ -> {:error, :not_provisioned}
    end
  end

  defp send_and_await(scope, to, token, opts) do
    # The arriving message is identified by not being in the mailbox before
    # the send — exact on record and replay, unlike the per-run token, and
    # immune to an earlier probe's residue.
    seen = already_received(scope, opts)

    # Before sending: an earlier bounce suppresses the address and every later
    # send is dropped. Result ignored — the send reports deliverability.
    _ = Resend.clear_suppression(scope, to)

    with {:ok, from} <- probe_sender(scope, domain_of(to)),
         {:ok, _sent} <- Resend.send_probe(scope, to, subject: token, from: from) do
      Resend.await_received(scope, &received?(&1, to, seen), probe_wait(opts))
    end
  end

  # Inbound mail takes tens of seconds to route on a fresh MX; settling first
  # keeps the poll short. Overridable via `:settle_ms`.
  @probe_settle_ms 60_000

  # Settle, then poll; the id-based match makes record and replay stop on the
  # same response.
  defp probe_wait(opts), do: Keyword.put_new(opts, :settle_ms, @probe_settle_ms)

  defp already_received(scope, opts) do
    case Resend.list_received(scope, opts) do
      {:ok, messages} -> MapSet.new(messages, & &1["id"])
      _ -> MapSet.new()
    end
  end

  # The recorded proof, stamped with the Resend domain id it was earned
  # against so `proof_current?/2` can refuse one from a rebuilt domain.
  defp inbound_proof(to, message, domain_id) do
    %{
      kind: "inbound_proof",
      location: to,
      identifier:
        "state=delivered message_id=#{message["id"]} proven_at=#{message["created_at"]} " <>
          "resend_domain_id=#{domain_id}"
    }
  end

  # Whether a proof was earned against this Resend domain id. Unstamped
  # proofs are not current: unknown reads as absent.
  defp proof_current?(%{identifier: identifier}, domain_id)
       when is_binary(identifier) and is_binary(domain_id) do
    case Regex.run(~r/resend_domain_id=(\S+)/, identifier) do
      [_, ^domain_id] -> true
      _ -> false
    end
  end

  defp proof_current?(_proof, _domain_id), do: false

  # A verified sender on the account, or a clear reason there is none.
  defp probe_sender(scope, domain) do
    case Resend.list_domains(scope) do
      {:ok, domains} ->
        verified = Enum.filter(domains, &(&1["status"] == "verified"))

        # The domain under test first, so the outcome does not depend on what
        # sorts first in a shared account; any other verified domain as a
        # fallback, since this one may not be verified for sending yet.
        preferred =
          Enum.find(verified, &(&1["name"] == domain)) ||
            Enum.find(verified, &(not String.contains?(&1["name"] || "", "codemyspec.com"))) ||
            List.first(verified)

        case preferred do
          %{"name" => name} -> {:ok, "setup-probe@#{name}"}
          _ -> {:error, :no_verified_sender}
        end

      other ->
        other
    end
  end

  # The domain half of an address, for choosing a sender that matches the
  # domain under test.
  defp domain_of(address) when is_binary(address) do
    case String.split(address, "@", parts: 2) do
      [_local, domain] -> domain
      _ -> nil
    end
  end

  defp domain_of(_), do: nil

  # Addressed to us, and not one of the messages already there.
  defp received?(message, to, %MapSet{} = seen) do
    recipients = List.wrap(message["to"]) |> Enum.map(&to_string/1)

    Enum.any?(recipients, &(&1 == to)) and not MapSet.member?(seen, message["id"])
  end

  # What went out, so the running version is traceable to its commit.
  defp deploy_record_attrs(image, version) do
    [
      commit_sha: image_commit(image),
      version: version
    ]
  end

  defp image_commit(%{reference: reference}) when is_binary(reference) do
    reference |> String.split(":") |> List.last()
  end

  defp image_commit(_image), do: nil

  # Building makes a box, and `create_server/3` refuses one with no key. The
  # account's access key is looked up; an explicit `:ssh_key_ids` wins.
  defp with_access_key(scope, opts) do
    case Keyword.get(opts, :ssh_key_ids) do
      ids when is_list(ids) and ids != [] ->
        {:ok, opts}

      _ ->
        case ensure_access_key(scope, server_name(scope, opts)) do
          {:ok, ssh_key} -> {:ok, Keyword.put(opts, :ssh_key_ids, [ssh_key["id"]])}
          {:error, reason} -> {:error, format(reason)}
        end
    end
  end

  # An explicit `:image` wins; `build: false` deploys nothing built. Otherwise
  # build — `bin/deploy` without `CMS_IMAGE` falls through to a CI path that
  # setup's projects do not have.
  defp image_for(scope, environment, opts) do
    case {Keyword.get(opts, :image), Keyword.get(opts, :build)} do
      {reference, _} when is_binary(reference) ->
        {:ok, %{reference: reference, built: false}}

      {nil, false} ->
        {:ok, :not_built}

      {nil, _build} ->
        build_image(scope, environment, opts)
    end
  end

  # Helpers live below all `run/3` clauses: interleaving them splits the
  # clauses, and the analyzer treats that compiler warning as fatal.

  # The registry address both the builder (push) and the app box (pull) can
  # use: the app box's private IP, on a network the builder joins. An
  # explicit `:registry_host` wins.
  defp with_private_network(scope, environment, opts) do
    case Keyword.get(opts, :registry_host) do
      host when is_binary(host) and host != "" -> {:ok, opts}
      _ -> attach_private_network(scope, environment, opts)
    end
  end

  defp attach_private_network(scope, environment, opts) do
    box = server_name(scope, opts, environment)

    # Adopts the box's own network by id; `provision_account_server/3` is what
    # creates one.
    with {:ok, server} <- Hetzner.find_server(scope, box),
         location = get_in(server, ["location", "name"]),
         {:ok, network_id} <- existing_network_id(scope, server),
         {:ok, network} <- Hetzner.find_network_by_id(scope, network_id),
         # Re-attached anyway; `attach_to_network/3` treats an existing
         # attachment as success.
         {:ok, _attached} <- Hetzner.attach_to_network(scope, server["id"], network["id"]),
         # Re-read: the attach does not report the address it assigned.
         {:ok, joined} <- Hetzner.find_server(scope, box),
         {:ok, ip} <- Hetzner.private_ip(joined, network["id"]) do
      {:ok,
       opts
       |> Keyword.put(:network_ids, [network["id"]])
       # `:builder_location`, not `:location`: these opts reach `Storage`,
       # where `:location` is the object-storage region.
       # See knowledge/provisioning/steps, "Lessons".
       |> Keyword.put(:builder_location, location)
       |> Keyword.put(:registry_bind, ip)
       |> Keyword.put(:registry_host, "#{ip}:#{Registry.port()}")
       |> Keyword.put(:network_resource, network_resource(network["name"], network))}
    else
      {:error, :not_found} ->
        {:error, "cannot build for #{environment}: no server named #{box}"}

      :error ->
        {:error,
         "cannot build for #{environment}: #{box} has no private network yet — provision it " <>
           "from the account-level servers page first, a project's own devops step never " <>
           "creates one"}

      {:error, reason} ->
        {:error, "cannot build for #{environment} on #{box}: #{format(reason)}"}
    end
  end

  @doc """
  Run `callback` with something that can `ssh` into `ip`.

  Manages the account's builder key for the length of the call unless the
  caller already supplied a `:run`.
  """
  def with_ssh_runner(scope, ip, opts, callback) do
    case Keyword.get(opts, :run) do
      run when is_function(run, 1) ->
        callback.(run)

      _ ->
        with {:ok, ssh_opts} <- with_builder_ssh(scope, opts) do
          try do
            callback.(Remote.ssh_runner(%{"ip" => ip}, ssh_opts))
          after
            cleanup_builder_key(opts, ssh_opts)
          end
        end
    end
  end

  defp cleanup_builder_key(opts, ssh_opts) do
    if is_nil(Keyword.get(opts, :ssh_key_path)) do
      case Keyword.get(ssh_opts, :builder_key_dir) do
        dir when is_binary(dir) -> File.rm_rf(dir)
        _ -> :ok
      end
    end
  end

  # What `Builder.Remote.ssh_runner/2` `fetch!`es: `:env` and a key on disk.
  # The account key is written 0600 to a temp dir (ssh refuses a readable
  # key) and removed by `cleanup_builder_key/2`.
  #
  # `:env` stays the checkout (source delivery reads it); `:ssh_env` is where
  # ssh itself runs: this node, where the key file is. Routing ssh through
  # `env/1` sent it to a harness copy's harness, which runs no commands, and
  # `await_ssh` timed out on boxes that were up.
  @doc false
  def with_builder_ssh(scope, opts) do
    case Keyword.get(opts, :ssh_key_path) do
      path when is_binary(path) ->
        {:ok, with_ssh_env(opts, scope, Path.dirname(path))}

      _ ->
        write_builder_key(scope, opts)
    end
  end

  # The checkout's own context runs ssh when it can run commands (and keeps any
  # injected one); a harness copy, or none, gets a local context on this node.
  defp with_ssh_env(opts, scope, key_dir) do
    opts = Keyword.put_new_lazy(opts, :env, fn -> env(scope) end)

    case Keyword.fetch!(opts, :env) do
      %{type: :harness} -> Keyword.put_new(opts, :ssh_env, ExecutionContext.new(:local, key_dir))
      nil -> Keyword.put_new(opts, :ssh_env, ExecutionContext.new(:local, key_dir))
      _runs_commands -> opts
    end
  end

  defp write_builder_key(scope, opts) do
    case AccountSecrets.fetch_value(scope, @access_key_private) do
      {:ok, private} when is_binary(private) and private != "" ->
        # Owned: removed when the caller exits even where no explicit cleanup
        # runs, and named per OS process so two processes never share a key.
        dir = TempFile.owned_dir("cms-build")
        path = Path.join(dir, "id_ed25519")
        File.write!(path, private)
        File.chmod!(path, 0o600)

        {:ok,
         opts
         |> Keyword.put(:ssh_key_path, path)
         |> Keyword.put(:builder_key_dir, dir)
         |> with_ssh_env(scope, dir)}

      _ ->
        {:error,
         "no server access key on this account — the server step mints one, so run it first"}
    end
  end

  # One environment's bucket. Buckets already made are carried in the failure
  # so teardown can still find them.
  defp ensure_bucket_for(environment, {:ok, acc}, project, credentials, opts) do
    bucket = Storage.bucket_name(project, environment)

    case Storage.ensure_bucket(bucket, credentials, opts) do
      {:ok, created} -> {:cont, {:ok, acc ++ [bucket_created_resource(created)]}}
      {:error, reason} -> {:halt, {:error, format(reason), acc}}
    end
  end

  defp bucket_created_resource(created) do
    %{
      kind: "bucket",
      location: created.location,
      identifier: created.owner,
      origin: created.origin
    }
  end

  # Refuses a deploy config whose `proxy.host` names a host this project does
  # not own — kamal deploys wherever the checkout's config says. Only
  # `proxy.host` is compared (`servers.web` legitimately holds IPs); an
  # unreadable config is left to kamal and `DeployBoilerplate`.
  # See knowledge/provisioning/steps, "Deploy and build".
  defp config_targets_this_project(scope, environment) do
    with {:ok, body} <- read_deploy_config(scope, environment),
         {:ok, %{"proxy" => %{"host" => named}}} when is_binary(named) <-
           parse_deploy_config(body),
         [_ | _] = expected <- expected_hosts(scope, environment) do
      # An ERB host (`CMS_DEPLOY_HOST`, set by this step from the project's
      # domain) cannot name the wrong one.
      if resolved_at_runtime?(named) or named in expected do
        :ok
      else
        {:error,
         "#{deploy_config_path(environment)} deploys to #{named}, but this project's " <>
           "#{environment} is #{Enum.join(expected, ", ")}. Setup will not deploy to a host " <>
           "the project does not own — point the config at the right hostname, or fix the " <>
           "project's domain."}
      end
    else
      _ -> :ok
    end
  end

  # kamal's service name, read from its config: kamal refuses an image without
  # a matching `service` label, which its own build would have stamped.
  defp with_kamal_service(opts, scope, environment) do
    with {:ok, body} <- read_deploy_config(scope, environment),
         {:ok, %{"service" => service}} when is_binary(service) <-
           parse_deploy_config(body) do
      Keyword.put(opts, :service, service)
    else
      _ -> opts
    end
  end

  @doc """
  Parse kamal's deploy config, which is ERB before it is YAML.

  Statement tags (`<% … %>`) are removed — one followed by a key on the same
  line is invalid YAML. Output tags (`<%= … %>`) stay, so
  `resolved_at_runtime?/1` can recognise them, with inner double quotes
  swapped for single ones so they do not close their enclosing YAML string.

  Public so the rewrite can be tested directly; both callers treat a failed
  parse as "nothing to check".
  """
  @spec parse_deploy_config(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_deploy_config(body) do
    body
    |> String.replace(~r/<%(?!=).*?%>/s, "")
    |> then(&Regex.replace(~r/<%=.*?%>/s, &1, fn tag -> String.replace(tag, "\"", "'") end))
    |> YamlElixir.read_from_string()
  end

  defp read_deploy_config(scope, environment) do
    ExecutionContexts.read_file(env(scope), deploy_config_path(environment))
  end

  # Mirrors `bin/deploy`'s choice of file.
  defp deploy_config_path("uat"), do: "config/deploy.uat.yml"
  defp deploy_config_path(_), do: "config/deploy.yml"

  defp expected_hosts(scope, environment) do
    case domain(scope) do
      nil ->
        []

      name ->
        scope
        |> permitted_hosts(name)
        |> Enum.filter(&(&1.name == environment and is_binary(&1.host)))
        |> Enum.map(& &1.host)
    end
  end

  defp content_proof(%{render: render, proven_at: proven_at} = result) do
    %{
      kind: "content_proof",
      location: MapAccess.get(render, :path, ""),
      identifier:
        "state=rendered status=#{MapAccess.get(render, :status)} " <>
          "title_present=#{title_present?(render)} proven_at=#{iso(proven_at)} " <>
          "version=#{content_version(result)}"
    }
  end

  # Which content is live: a failed publish keeps the last good proof, so the
  # version shows what visitors still see.
  defp content_version(%{published: %{content_hash: hash}}) when is_binary(hash), do: hash
  defp content_version(_result), do: ""

  defp content_failure(state, reason, published) do
    %{
      kind: "content_failure",
      location: to_string(reason),
      identifier: "state=#{state} objects_uploaded=#{uploaded?(published)}"
    }
  end

  # One resource per object, naming whose bucket it landed in.
  defp content_objects(%{published: %{objects: objects}}) when is_list(objects) do
    Enum.map(objects, fn object ->
      %{
        kind: "content_object",
        location: MapAccess.get(object, :key, ""),
        identifier:
          "owner=#{MapAccess.get(object, :owner, "user")} " <>
            "bucket=#{MapAccess.get(object, :bucket)}"
      }
    end)
  end

  defp content_objects(_), do: []

  defp uploaded?(%{objects: objects}) when is_list(objects), do: objects != []
  defp uploaded?(_), do: false

  defp title_present?(render) do
    contains = MapAccess.get(render, :body_contains)
    contains not in [nil, false, []]
  end

  # The live site's status, and whether the widget was present and openable
  # (present-but-not-openable is a broken bundle).
  defp widget_render(%{presence: %{} = presence}) do
    %{
      kind: "widget_render",
      location: to_string(MapAccess.get(presence, :status)),
      identifier:
        "status=#{MapAccess.get(presence, :status)} " <>
          "present=#{MapAccess.get(presence, :present)} " <>
          "openable=#{MapAccess.get(presence, :openable)}"
    }
  end

  defp widget_render(_), do: nil

  # Widget messages tagged by origin relative to the deployed site, compared
  # by host (scheme, port and slash may differ). No origin is `unknown`, never
  # trusted.
  defp widget_messages(scope, site_url) do
    host = uri_host(site_url)

    scope
    |> Conversations.list_widget_messages()
    |> Enum.map(
      &%{
        origin: origin_of(&1.origin, host),
        id: &1.id,
        at: &1.inserted_at,
        body: Conversations.Message.text(&1)
      }
    )
  end

  defp origin_of(origin, host) when is_binary(origin) and is_binary(host) do
    if uri_host(origin) == host, do: "deployed_site", else: "elsewhere"
  end

  defp origin_of(_origin, _host), do: "unknown"

  defp uri_host(url) when is_binary(url), do: URI.parse(url).host
  defp uri_host(_url), do: nil

  # A message that travelled from the deployed site; `origin` separates it
  # from one posted by hand. No nil clause: the only caller is the `:proven`
  # branch, and an unreachable clause warns (which the analyzer treats as fatal).
  defp widget_proof(%{proof: %{} = proof, proven_at: proven_at}) do
    %{
      kind: "widget_proof",
      location: to_string(MapAccess.get(proof, :origin, "deployed_site")),
      identifier:
        "state=#{MapAccess.get(proof, :state)} " <>
          "origin=#{MapAccess.get(proof, :origin)} proven_at=#{iso(proven_at)}"
    }
  end

  defp build_image(scope, environment, opts) do
    # The registry belongs to the server step; a build finds infrastructure,
    # never creates it.
    with {:ok, architecture} <- architecture_for(scope, environment, opts),
         {:ok, opts} <- with_access_key(scope, opts),
         opts = Keyword.put_new(opts, :environment, environment),
         {:ok, opts} <- with_private_network(scope, environment, opts),
         {:ok, opts} <- with_registry_credential(scope, opts),
         {:ok, opts} <- with_builder_ssh(scope, opts),
         opts = with_kamal_service(opts, scope, environment),
         {:ok, tag} <- image_tag(scope, opts),
         # Before the build: it is where the image is pushed to, and the
         # builder refuses without `opts[:reference]`.
         {:ok, reference} <- Registry.reference(scope, tag, opts),
         opts = Keyword.put(opts, :reference, reference),
         opts = with_deploy_execution(opts, scope, environment, reference, architecture),
         {:ok, build} <- build_on_builder(scope, tag, architecture, opts) do
      {:ok,
       %{
         reference: reference,
         built: true,
         # Surfaced so the step records it for teardown.
         network: Keyword.get(opts, :network_resource),
         architecture: build.architecture,
         retention: retention_claim(scope, environment, opts),
         builder: build.builder,
         builder_image: build.builder_image,
         builder_destroyed: build.builder_destroyed,
         deploy: build.deploy
       }}
    end
  end

  # The deploy runs on the builder box, right after the push, via `Builder`'s
  # `opts[:then]` hook — never from wherever the caller is connected.
  # `with_deploy_ssh`/`forget_stale_host_key` are not needed here:
  # `with_builder_ssh` already set `opts[:env]`, and `Deploy`'s `trust_host/1`
  # handles host keys remotely.
  # See knowledge/provisioning/steps, "Deploy and build".
  defp with_deploy_execution(opts, scope, environment, reference, architecture) do
    host = Keyword.get(opts, :host) || environment_host(scope, environment) || domain(scope)

    deploy_opts =
      opts
      |> Keyword.put(:architecture, architecture)
      |> deploy_opts(host, %{reference: reference})
      |> with_host_ip(scope, environment)
      |> with_age_key(scope, environment)
      |> with_registry_credential_for_deploy(scope)
      |> Keyword.put(:environment_previously_deployed, previously_deployed?(scope, environment))

    Keyword.put(opts, :then, fn run, dir ->
      Deploy.run(env(scope), environment, Keyword.merge(deploy_opts, run: run, remote_dir: dir))
    end)
  end

  # Tells `Deploy.run/3` whether a failing health check protects something
  # live (see `Deploy.skip_health?/3`). Unknown reads as `true`.
  defp previously_deployed?(scope, environment) do
    case Environments.get_deployment(scope, environment) do
      %{first_deployed_at: nil} -> false
      %{first_deployed_at: %DateTime{}} -> true
      _ -> true
    end
  end

  # Retention claimed only from a mechanism that ran: a bucket lifecycle rule
  # when enforced, else a prune to `keep_images` after this push. A failed
  # prune makes no claim and does not fail the deploy.
  # See knowledge/provisioning/steps, "Deploy and build".
  defp retention_claim(scope, environment, opts) do
    if Registry.retention_enforced?(opts) do
      {:days, Registry.retention_days(opts)}
    else
      case prune_registry(scope, environment, opts) do
        :ok -> {:images, Registry.keep_images(opts)}
        :error -> nil
      end
    end
  end

  # The registry lives on the app box, so its IP is looked up here (the
  # builder's key opens it too). A supplied `:run` wins, as in
  # `serve_one_registry/5`.
  defp prune_registry(scope, environment, opts) do
    with ip when is_binary(ip) and ip != "" <- environment_ip(scope, %{name: environment}, opts),
         run = Keyword.get(opts, :run) || Remote.ssh_runner(%{"ip" => ip}, opts),
         bind = Keyword.get(opts, :registry_bind) || Keyword.get(opts, :bind, "127.0.0.1"),
         prune_opts = opts |> Keyword.put(:run, run) |> Keyword.put(:bind, bind),
         {:ok, _pruned} <- Registry.prune(scope, prune_opts) do
      :ok
    else
      _ -> :error
    end
  end

  # A failed build still made a box; the failure carries it as a partial
  # resource.
  defp build_on_builder(scope, tag, architecture, opts) do
    case Builder.build(scope, tag, Keyword.put(opts, :architecture, architecture)) do
      {:ok, build} -> {:ok, build}
      {:error, reason, disposition} -> {:error, format(reason), builder_resource(disposition)}
      {:error, reason} -> {:error, format(reason)}
    end
  after
    # However the build went: this key opens every box the account owns.
    case Keyword.get(opts, :builder_key_dir) do
      dir when is_binary(dir) -> File.rm_rf(dir)
      _ -> :ok
    end
  end

  @doc """
  The image tag: `opts[:tag]` or the project's head commit, first 12 chars.

  Public so the tagging decision can be tested without a build pipeline.
  """
  @spec image_tag(Scope.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def image_tag(scope, opts) do
    case Keyword.get(opts, :tag) || head_commit(scope) do
      sha when is_binary(sha) and sha != "" -> {:ok, String.slice(sha, 0, 12)}
      _ -> {:error, "cannot tag an image: the project has no commit to build"}
    end
  end

  # `cwd` checked first: `ExecutionContexts.cmd/4` raises for an environment with
  # no working directory. Falls back to the `head_commit` the harness reports
  # on sync.
  defp head_commit(scope) do
    case env(scope) do
      %{cwd: cwd} = environment when is_binary(cwd) ->
        case ExecutionContexts.cmd(environment, "git", ["rev-parse", "HEAD"],
               stderr_to_stdout: true
             ) do
          {sha, 0} -> String.trim(sha)
          _ -> reported_head_commit(scope)
        end

      _ ->
        reported_head_commit(scope)
    end
  end

  defp reported_head_commit(scope) do
    case project(scope) |> Map.get(:head_commit) do
      sha when is_binary(sha) and sha != "" -> sha
      _ -> nil
    end
  end

  # The architecture the box actually runs, asked of Hetzner — the server step
  # may fall back to the other one when a region is sold out, and a mismatched
  # image dies at container start.
  defp architecture_for(scope, environment, opts) do
    case Keyword.get(opts, :architecture) do
      nil -> environment_architecture(scope, environment)
      architecture -> {:ok, architecture}
    end
  end

  defp environment_architecture(scope, environment) do
    case Environments.get_deployment(scope, environment) do
      %{server_name: name} when is_binary(name) -> server_architecture(scope, name)
      _ -> {:error, "cannot build for #{environment}: it has no server yet"}
    end
  end

  defp server_architecture(scope, name) do
    with {:ok, server} <- Hetzner.find_server(scope, name),
         {:ok, architecture} <- Hetzner.server_architecture(server) do
      {:ok, architecture}
    else
      {:error, :not_found} ->
        {:error, "cannot build for #{name}: the provider has no such server"}

      {:error, reason} ->
        {:error, format(reason)}
    end
  end

  defp deploy_opts(opts, host, %{reference: reference}),
    do: opts |> Keyword.put(:host, host) |> Keyword.put(:image, reference)

  defp deploy_opts(opts, host, :not_built), do: Keyword.put(opts, :host, host)

  # Kamal evaluates ERB in its config, so a host written that way is decided
  # when the deploy runs rather than when the file was committed.
  defp resolved_at_runtime?(value), do: String.contains?(value, "<%")

  # The key kamal connects with. Without `CMS_SSH_KEY_PATH` the config's
  # `keys_only` branch is not rendered and net-ssh offers every agent
  # identity, which trips `MaxAuthTries`.
  defp with_deploy_ssh(opts, scope) do
    case with_builder_ssh(scope, opts) do
      {:ok, opts} -> opts
      _ -> opts
    end
  end

  # Removes the key written for kamal however the deploy goes.
  defp run_deploy(scope, environment, deploy_opts) do
    Deploy.run(env(scope), environment, deploy_opts)
  after
    case Keyword.get(deploy_opts, :builder_key_dir) do
      dir when is_binary(dir) -> File.rm_rf(dir)
      _ -> :ok
    end
  end

  # kamal refuses a config without a registry password and `docker login`s
  # with it, so the builder's push credential reaches the deploy too.
  defp with_registry_credential_for_deploy(opts, scope) do
    case Registry.credential(scope) do
      {:ok, credential} ->
        opts
        |> Keyword.put(:registry_username, credential.username)
        |> Keyword.put(:registry_password, credential.password)

      _ ->
        opts
    end
  end

  # Providers recycle addresses, so a `known_hosts` entry for a box setup just
  # made is stale and kamal's net-ssh refuses it. Removed, not disabled:
  # host-key checking stays on.
  defp forget_stale_host_key(opts) do
    case Keyword.get(opts, :host_ip) do
      ip when is_binary(ip) and ip != "" ->
        System.cmd("ssh-keygen", ["-R", ip], stderr_to_stdout: true)
        :ok

      _ ->
        :ok
    end
  end

  # The registry's own credential, for the builder's push and kamal's pull.
  defp with_registry_credential(scope, opts) do
    case Registry.credential(scope) do
      {:ok, credential} ->
        {:ok, Keyword.put(opts, :registry_credentials, credential)}

      {:error, reason} ->
        {:error, "could not read or mint the registry password: #{format(reason)}"}
    end
  end

  # The age key for this environment's encrypted env, from `ProjectSecrets`
  # (not the repository), handed to the deploy for the container.
  defp with_age_key(opts, scope, environment) do
    case fetch_age_key(scope, environment) do
      {:ok, key} -> Keyword.put(opts, :age_key, key)
      _ -> opts
    end
  end

  # The box this environment's traffic lands on; not knowable when the deploy
  # config was generated.
  defp with_host_ip(opts, scope, environment) do
    case environment_ip(scope, %{name: environment}, opts) do
      ip when is_binary(ip) and ip != "" -> Keyword.put(opts, :host_ip, ip)
      _ -> opts
    end
  end

  # Records the architecture, so a mismatch is answerable from the record.
  defp image_resources(%{reference: reference, built: true} = image) do
    [
      %{
        kind: "published_image",
        location: reference,
        identifier: "built=true architecture=#{image.architecture}"
      }
      | retention_resource(image) ++ builder_resource(image) ++ network_resources(image)
    ]
  end

  defp image_resources(%{reference: reference}),
    do: [%{kind: "published_image", location: reference, identifier: "built=false"}]

  defp image_resources(:not_built), do: []
  defp network_resources(%{network: %{} = network}), do: [network]
  defp network_resources(_image), do: []

  # `enforced_by` names the mechanism `retention_claim/3` found; no claim, no
  # resource. The page reads `enforced_by` from here.
  defp retention_resource(%{retention: {:days, days}}),
    do: [
      %{
        kind: "image_retention",
        location: "#{days} days",
        identifier: "enforced_by=bucket_lifecycle"
      }
    ]

  defp retention_resource(%{retention: {:images, count}}),
    do: [
      %{
        kind: "image_retention",
        location: "#{count} images",
        identifier: "enforced_by=prune_on_push"
      }
    ]

  defp retention_resource(_image), do: []

  # The builder box and whether it was destroyed — one left running costs
  # money invisibly. `booted_from` is the pre-warmed image.
  defp builder_resource(%{builder: name} = image) when is_binary(name) do
    [
      %{
        kind: "builder",
        location: name,
        identifier: "destroyed=#{image.builder_destroyed} booted_from=#{image.builder_image}"
      }
    ]
  end

  defp builder_resource(_image), do: []

  ## Helpers

  defp verify_dns_records(scope, domain, environments) do
    with {:ok, %{"id" => zone_id}} <- Cloudflare.find_zone(scope, domain),
         {:ok, records} <- Cloudflare.list_dns_records(scope, zone_id) do
      dns_records_satisfied(records, environments)
    else
      # Unreadable zone: absent, and the idempotent run converges.
      _ -> {:ok, :absent}
    end
  end

  defp dns_records_satisfied(records, environments) do
    if Enum.all?(environments, &record_points_at?(records, &1)),
      do:
        {:ok, :satisfied,
         Enum.flat_map(environments, &(dns_resources_for(&1) ++ [dns_outcome(&1, "unchanged")]))},
      else: {:ok, :absent}
  end

  # Present and pointing at this environment's server — a leftover record may
  # point at an address the project no longer holds.
  defp record_points_at?(records, environment) do
    Enum.any?(records, fn record ->
      record["name"] == environment.host and record["type"] == "A" and
        record["content"] == environment.ip and record["proxied"] != true
    end)
  end

  defp dns_resources_for(environment) do
    [
      %{
        kind: "dns_record",
        location: "cloudflare/#{environment.host}",
        identifier: "#{environment.ip} environment=#{environment.name}"
      },
      %{
        kind: "dns_verification",
        location: environment.host,
        identifier: "source=zone environment=#{environment.name}"
      }
    ]
  end

  defp verify_sending_domains(scope, base, environments) do
    environments
    |> Enum.reduce_while({:ok, []}, fn environment, {:ok, acc} ->
      sending = Resend.sending_domain(base, environment)

      case Resend.find_domain(scope, sending) do
        {:ok, %{"status" => "verified"} = d} ->
          # Resend's "verified" is its memory of a past check, so the records
          # are also checked in the zone.
          # See knowledge/provisioning/steps, "Email".
          sending_domain_outcome(scope, sending, d, acc)

        {:ok, _unverified} ->
          {:halt, :absent}

        {:error, :not_found} ->
          {:halt, :absent}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, resources} -> {:ok, :satisfied, resources}
      :absent -> {:ok, :absent}
      {:error, reason} -> {:error, reason}
    end
  end

  # Whether the records Resend lists (DKIM is per-domain, so never derived)
  # exist in the zone. Existence only, not content — rewriting on a value
  # mismatch would fight deliberate edits. Asked authoritatively: a recursive
  # resolver may cache a negative from just before the write.
  defp sending_published?(scope, sending, domain) do
    records =
      scope
      |> sending_records_for(domain)
      |> Resend.sending_records(sending)

    case {records, find_sending_zone(scope, sending)} do
      # Nothing required is trivially satisfied.
      {[], _} ->
        true

      {records, {:ok, zone}} ->
        Enum.all?(records, &record_published?(&1, zone))

      # Cannot tell: the provider's verified stands, rather than rewriting
      # every record on a zone lookup failure.
      {_records, _} ->
        true
    end
  end

  defp record_published?(record, zone) do
    record["name"]
    |> qualify(zone["name"])
    |> Dns.lookup_authoritative(dns_record_type(record["type"]))
    |> Kernel.!=([])
  end

  # Resend names types the way DNS does; `Dns` wants them as atoms.
  defp dns_record_type(type) when is_binary(type) do
    case String.upcase(type) do
      "MX" -> :mx
      "CNAME" -> :cname
      "A" -> :a
      _ -> :txt
    end
  end

  defp dns_record_type(_type), do: :txt

  defp sending_domain_outcome(scope, sending, domain, acc) do
    if sending_published?(scope, sending, domain) do
      {:cont,
       {:ok,
        acc ++
          [
            %{kind: "sending_domain", location: "resend/#{domain["name"]}"},
            %{kind: "verification", location: "1 attempts"}
          ]}}
    else
      {:halt, :absent}
    end
  end

  defp register_sending_domains(scope, base, environments, opts) do
    Enum.reduce_while(environments, {:ok, []}, fn environment, {:ok, acc} ->
      case register_sending_domain(scope, base, environment, opts) do
        {:ok, resources} -> {:cont, {:ok, acc ++ resources}}
        # Carries what earlier environments made.
        {:paused, instructions, partial} -> {:halt, {:paused, instructions, acc ++ partial}}
        {:error, reason, partial} -> {:halt, {:error, reason, acc ++ partial}}
        {:error, reason} -> {:halt, {:error, reason, acc}}
      end
    end)
  end

  defp register_sending_domain(scope, base, environment, opts) do
    sending = Resend.sending_domain(base, environment)
    _ = environment

    case Resend.ensure_domain(scope, sending) do
      {:ok, d} ->
        # Recorded from here on, verified or not. `origin: "adopted"` keeps
        # teardown off a domain setup only found.
        created = [
          %{
            kind: "sending_domain",
            location: "resend/#{sending}",
            identifier: "#{environment}:#{d["id"]}",
            origin: if(d["__adopted__"], do: "adopted", else: "created")
          }
        ]

        # Publish before polling: Resend will not verify a domain whose records
        # are not in DNS.
        case publish_sending_records(scope, sending, sending_records_for(scope, d)) do
          {:ok, published} ->
            verify_sending_domain(scope, d, sending, created ++ published, opts)

          {:error, reason} ->
            {:error, reason, created}
        end

      {:error, reason} ->
        {:error, format(reason)}
    end
  end

  # The domain as Resend describes it by id — the only form that carries
  # `records`.
  defp inbound_records_for(scope, %{"id" => id} = domain) do
    case Resend.get_domain(scope, id) do
      {:ok, body} -> body["data"] || body
      _ -> domain
    end
  end

  defp inbound_records_for(_scope, domain), do: domain

  # Re-reads the domain: `ensure_domain/2`'s result carries no records, and
  # without them nothing would be published while the step reported success.
  defp sending_records_for(scope, %{"id" => id} = domain) do
    case Resend.get_domain(scope, id) do
      {:ok, body} -> Resend.records(body["data"] || body)
      _ -> Resend.records(domain)
    end
  end

  defp sending_records_for(_scope, domain), do: Resend.records(domain)

  # Write Resend's records into the zone that covers `sending` and no other.
  # The zone is resolved from `sending` itself, never the project or opts, and
  # names are qualified against that zone (Resend's are relative).
  # See knowledge/provisioning/steps, "Email".
  defp publish_sending_records(scope, sending, records) do
    case Resend.sending_records(records, sending) do
      [] ->
        {:ok, []}

      sending_records ->
        with {:ok, zone} <- find_sending_zone(scope, sending),
             {:ok, existing} <- Cloudflare.list_dns_records(scope, zone["id"]) do
          write_sending_records(scope, zone, sending_records, existing)
        else
          {:error, :not_found} ->
            {:error,
             "no Cloudflare zone covers #{sending}, so the records Resend needs cannot be " <>
               "published — add the domain to Cloudflare, or point the project at one that is"}

          {:error, reason} ->
            {:error, format(reason)}
        end
    end
  end

  defp find_sending_zone(scope, sending), do: Cloudflare.find_zone(scope, sending)

  defp write_sending_records(scope, zone, records, existing) do
    Enum.reduce_while(records, {:ok, []}, &write_sending_record(&1, &2, scope, zone, existing))
  end

  defp write_sending_record(record, {:ok, acc}, scope, zone, existing) do
    name = qualify(record["name"], zone["name"])

    # Should be unreachable (`find_zone` matches on a label boundary); kept
    # because the failure is DNS written to someone's live domain.
    if covered_by?(name, zone["name"]) do
      publish_sending_record(scope, zone, name, record, existing, acc)
    else
      {:halt,
       {:error,
        "refusing to publish #{name}: it is not inside the #{zone["name"]} zone, and a " <>
          "record written outside its own zone lands on a domain nobody meant to touch"}}
    end
  end

  # No `ttl`: Resend reports "Auto", which Cloudflare rejects as a non-number.
  # Its default is what "Auto" means.
  defp publish_sending_record(scope, zone, name, record, existing, acc) do
    case Cloudflare.ensure_dns_record(scope, zone["id"], name, record["value"],
           type: record["type"],
           priority: record["priority"],
           records: existing
         ) do
      {:ok, result} -> {:cont, {:ok, acc ++ [sending_record_resource(name, record, result)]}}
      {:error, reason} -> {:halt, {:error, format(reason)}}
    end
  end

  defp sending_record_resource(name, record, result) do
    %{
      kind: "sending_record",
      location: "cloudflare/#{name}",
      identifier: "#{record["type"]} #{record["value"]}",
      origin: if(adopted?(result), do: "adopted", else: "created")
    }
  end

  defp adopted?(%{"result" => %{"__adopted__" => true}}), do: true
  defp adopted?(_), do: false

  defp covered_by?(name, zone_name) when is_binary(name) and is_binary(zone_name) do
    name == zone_name or String.ends_with?(name, "." <> zone_name)
  end

  defp covered_by?(_, _), do: false

  defp verify_sending_domain(scope, domain, sending, created, opts) do
    case Resend.poll_until_verified(scope, domain["id"], opts) do
      {:ok, %{attempts: n}} ->
        {:ok, created ++ [%{kind: "verification", location: "#{n} attempts"}]}

      # Names the records at fault, so nobody diffs a record set by hand.
      {:error, {:unverified, faulted}} ->
        {:error,
         "the sending domain #{sending} did not verify — these records are not as Resend " <>
           "expects: " <> Enum.map_join(faulted, ", ", &"#{&1["type"]} #{&1["name"]}"), created}

      # Still verifying is a wait, not a fault: Resend checks on its own
      # schedule and a re-run picks it up.
      {:error, {:still_verifying, pending}} ->
        {:paused,
         "#{sending} is registered and its records are published — Resend has not finished " <>
           "checking them yet (#{Enum.map_join(pending, ", ", &"#{&1["type"]} #{&1["name"]}")}). " <>
           "Nothing is wrong with them; run this step again in a few minutes.", created}

      {:error, reason} ->
        {:error, format(reason), created}
    end
  end

  # Records the pushed repository on the project, so a re-run can tell its own
  # work from a repository the user already had.
  defp record_repository(%{state: :pushed, repository: repo} = result, scope) do
    url = repo["clone_url"] || repo["html_url"]

    if is_binary(url) and url != "" do
      Projects.update_project(scope, project(scope), %{code_repo: url})
    end

    result
  end

  defp record_repository(result, _scope), do: result

  # Whether the project already records the repository this step would use.
  # Compared on the last path segment (SSH or HTTPS form), with `_` and `-`
  # equated: `Repository.default_name/1` hyphenates, while existing repos
  # often use the underscored app name.
  defp ours?(%{code_repo: url} = project, opts) when is_binary(url) and url != "" do
    name = Keyword.get(opts, :name) || Repository.default_name(project)

    recorded =
      url |> String.trim_trailing(".git") |> String.split("/") |> List.last()

    normalize_repo_name(recorded) == normalize_repo_name(name)
  end

  defp ours?(_project, _opts), do: false

  defp normalize_repo_name(name), do: String.replace(name, "_", "-")

  # Points `Repository.ensure/3` at the recorded owner/name instead of its
  # derived defaults; explicit `opts[:owner]`/`opts[:name]` still win.
  defp with_recorded_location(opts, %{code_repo: url}, true)
       when is_binary(url) and url != "" do
    case parse_recorded_repo(url) do
      {:ok, owner, name} -> opts |> Keyword.put_new(:owner, owner) |> Keyword.put_new(:name, name)
      :error -> opts
    end
  end

  defp with_recorded_location(opts, _project, _adopt?), do: opts

  # SSH (`git@github.com:Owner/name.git`) and HTTPS forms; `:` → `/` makes
  # them split the same way.
  defp parse_recorded_repo(url) do
    segments =
      url
      |> String.trim_trailing(".git")
      |> String.replace(":", "/")
      |> String.split("/")
      |> Enum.reject(&(&1 == ""))

    case Enum.take(segments, -2) do
      [owner, name] -> {:ok, owner, name}
      _ -> :error
    end
  end

  defp repository_outcome(result) do
    case result do
      %{state: :pushed, repository: repo, commit: commit, disposition: disposition} ->
        {:ok, [repo_resource(repo, disposition), %{kind: "commit", location: commit}]}

      %{state: :name_taken, reason: reason} ->
        {:paused, reason}

      %{reason: reason} ->
        {:error, reason}
    end
  end

  @doc """
  What the deploy will hand the app, and what it is still missing.

  The age key travels as deploy configuration, and a missing required secret
  refuses the deploy by name — both before anything touches the server.
  Returns the key-delivery resource, or an error naming what is missing (or
  that the project has no environment).
  """
  @spec check_secrets(Scope.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def check_secrets(%Scope{} = scope, environment) do
    case env(scope) do
      nil ->
        {:error, no_environment_message()}

      resolved_environment ->
        check_resolved_secrets(scope, environment, resolved_environment)
    end
  end

  defp check_resolved_secrets(scope, environment, resolved_environment) do
    with {:ok, private} <- fetch_age_key(scope, environment),
         {:ok, missing} <-
           missing_required_secrets(scope, environment, private, resolved_environment) do
      case missing do
        [] -> {:ok, key_delivery_resource(environment)}
        names -> {:error, boot_refusal(environment, names)}
      end
    else
      {:error, :not_found} ->
        {:error,
         "#{environment} has no age key yet — set a secret, or run the secrets step, " <>
           "before deploying."}

      {:error, reason} ->
        {:error, to_string_reason(reason)}
    end
  end

  # The verdict the harness reported at sync (`Files.Scanner.validate_entry/4`,
  # `:encrypted_env` — dotenv-mode sops leaves key names plaintext) wins;
  # otherwise the file is read directly.
  defp missing_required_secrets(scope, environment, private, resolved_environment) do
    case Files.get_by_path(scope, Sops.env_file(environment)) do
      %{validation_errors: %{"data" => %{"missing" => missing}}} ->
        {:ok, missing}

      _ ->
        Sops.missing_secrets(resolved_environment, environment, private, @required_secrets)
    end
  end

  # The private key goes into the deploy's environment from `ProjectSecrets`;
  # nobody places a keys.txt by hand.
  defp key_delivery_resource(environment) do
    %{
      kind: "age_key_delivery",
      location: "#{environment}/SOPS_AGE_KEY",
      identifier: "via=deploy_env manual=false"
    }
  end

  defp boot_refusal(environment, names) do
    "#{environment} is missing " <>
      Enum.join(names, ", ") <>
      " — the app refuses to boot without it rather than starting half-configured."
  end

  @doc """
  Appends the script's output to a failure reason, head and tail
  (`Truncate.head_and_tail/2` at its default budget): the real error may sit
  at either end. Public so it can be tested without a failed deploy.
  """
  @spec with_output(String.t(), term()) :: String.t()
  def with_output(reason, output) when is_binary(output) do
    case String.trim(output) do
      "" -> reason
      trimmed -> reason <> "\n\n" <> Truncate.head_and_tail(trimmed)
    end
  end

  def with_output(reason, _output), do: reason

  defp deploy_outcome(result, environment, host) do
    phases =
      [
        # Only on a first deploy: kamal needs a boot to write the env file
        # migrate reads.
        result.bootstrapped_at &&
          %{kind: "deploy_phase", location: "bootstrap", identifier: iso(result.bootstrapped_at)},
        result.migrated_at &&
          %{kind: "deploy_phase", location: "migrate", identifier: iso(result.migrated_at)},
        result.health_ok_at &&
          %{kind: "deploy_phase", location: "swap", identifier: iso(result.health_ok_at)},
        %{kind: "live_version", location: to_string(result.live_version)}
      ]
      |> Enum.reject(&is_nil/1)

    case result do
      %{swapped_at: nil, reason: reason} ->
        failure = %{
          kind: "deploy_failure",
          location: reason,
          identifier: to_string(result.failed_phase)
        }

        # With what the script said, not just that it failed.
        {:error, with_output(reason, result.output), [failure | phases]}

      %{swapped_at: _} ->
        {:ok, [%{kind: "deployment", location: "#{environment}/#{host}"} | phases]}
    end
  end

  # What the deploy shipped, when the caller supplied `:deployed_version`.
  defp version_resources(%{commit: commit, image: image, source: source}) do
    [
      %{
        kind: "deployed_version",
        location: image,
        identifier: "commit=#{commit} source=#{source}"
      }
    ]
  end

  defp version_resources(_), do: []

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(_), do: nil

  # Handed over rather than decrypted on the box, which has docker and curl
  # and no sops.
  defp put_database_url(opts, scope, environment) do
    case Database.credential(scope, environment) do
      {:ok, credential} -> Keyword.put_new(opts, :database_url, Database.url(credential))
      _ -> opts
    end
  end

  # The credential `bin/backup restore` uses for its scratch database. Must
  # be handed over too: `load_env` skips decryption once `DATABASE_URL` and
  # the bucket keys are present.
  defp put_restore_admin_url(opts, scope, environment) do
    case Database.restore_credential(scope, environment) do
      {:ok, restore} -> Keyword.put_new(opts, :restore_admin_url, Database.restore_url(restore))
      _ -> opts
    end
  end

  defp put_age_key(opts, scope, environment) do
    case fetch_age_key(scope, environment) do
      {:ok, key} -> Keyword.put(opts, :age_key, key)
      # No key yet: the dump fails on its own terms.
      {:error, :not_found} -> opts
    end
  end

  # Each resource carries its environment, so the page can say which
  # database each dump holds.
  defp backups_outcome({:ok, %{proof: proof} = result}, bucket, environment) do
    {:ok,
     [
       %{
         kind: "age_key_delivery",
         location: "#{environment}/SOPS_AGE_KEY",
         identifier: "via=backup_env manual=false"
       },
       %{
         kind: "dump",
         location: "#{bucket}/#{result.key}",
         identifier: "environment=#{environment}"
       },
       %{
         kind: "restore_proof",
         location: proof.target,
         identifier:
           "environment=#{environment} rows=#{proof.rows} " <>
             "proven_at=#{DateTime.to_iso8601(proof.proven_at)}"
       },
       %{
         kind: "retention",
         location: "#{result.retention_days} days",
         identifier: "environment=#{environment}"
       }
     ]}
  end

  defp backups_outcome({:error, reason}, _bucket, _environment), do: {:error, format(reason)}

  defp project(%Scope{active_project: project}), do: project

  defp env(%Scope{active_working_copy_id: copy_id} = scope) when not is_nil(copy_id),
    do: WorkingCopies.execution_context(scope)

  defp env(%Scope{} = scope), do: LocalScope.execution_context(scope.active_project)

  defp domain(%Scope{active_project: %{domain: d}}) when is_binary(d) and d != "", do: d
  defp domain(_), do: nil

  # The environment's own hostname — not the project's domain except for
  # production. `nil` when unset; callers fall back to `domain/1`.
  defp environment_host(scope, environment) do
    case Environments.get_deployment(scope, environment) do
      %{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  # Halts on the first failure — a prod deploy after UAT failed has no
  # evidence behind it — keeping what landed. Empty means the devops level
  # filtered out every environment, an error rather than a vacuous success.
  defp deploy_environments(scope, [], _opts),
    do: {:error, no_permitted_environments_message(scope)}

  defp deploy_environments(scope, environments, opts) do
    Enum.reduce_while(environments, {:ok, []}, fn environment, {:ok, acc} ->
      case deploy_environment(scope, environment, opts) do
        {:ok, resources} -> {:cont, {:ok, acc ++ resources}}
        {:error, reason} -> {:halt, {:error, reason, acc}}
        {:error, reason, resources} -> {:halt, {:error, reason, acc ++ resources}}
      end
    end)
  end

  defp deploy_environment(%Scope{} = scope, environment, opts) do
    host = Keyword.get(opts, :host) || environment_host(scope, environment) || domain(scope)
    version = Keyword.get(opts, :deployed_version)

    with {:ok, delivery} <- check_secrets(scope, environment),
         :ok <- config_targets_this_project(scope, environment),
         :ok <- require_script(scope, "bin/deploy"),
         # Before the build: the builder archives HEAD, and the image is
         # versioned by HEAD.
         :ok <- commit_generated_configuration(scope),
         {:ok, image} <- image_for(scope, environment, opts),
         result <- deploy_result(scope, environment, host, image, opts) do
      case deploy_outcome(result, environment, host) do
        {:ok, resources} ->
          # Only after the health probe passed: a deploy that never answered
          # must not read as done.
          {:ok, _deploys} =
            Deploys.record_environment_deploy(
              scope,
              environment,
              deploy_record_attrs(image, version)
            )

          environment_row = Environments.get_deployment(scope, environment)

          {:ok, _instance} =
            AppInstances.record_deployment(scope, environment_row.id, %{
              confirmed_at: result.swapped_at,
              url: "https://#{host}",
              image: deployed_image_reference(image)
            })

          # On the environment too: `Deploys` is keyed by story, and
          # `previously_deployed?/2` needs an answer without one.
          :ok = Environments.mark_first_deployed(scope, environment)

          {:ok, [delivery | version_resources(version) ++ image_resources(image) ++ resources]}

        {:error, reason, resources} ->
          {:error, reason, [delivery | resources]}
      end
    end
  end

  defp deployed_image_reference(%{reference: reference}), do: reference
  defp deployed_image_reference(_image), do: nil

  # A build already ran the deploy on its box (`with_deploy_execution/4`), so
  # its result is reused. Only an unbuilt image (explicit `:image` or
  # `build: false`) deploys here, against `env(scope)`.
  defp deploy_result(_scope, _environment, _host, %{deploy: %Deploy.Result{} = result}, _opts),
    do: result

  defp deploy_result(scope, environment, host, image, opts) do
    deploy_opts =
      opts
      |> deploy_opts(host, image)
      |> with_host_ip(scope, environment)
      |> with_age_key(scope, environment)
      |> with_registry_credential_for_deploy(scope)
      |> with_deploy_ssh(scope)

    forget_stale_host_key(deploy_opts)
    run_deploy(scope, environment, deploy_opts)
  end

  defp environments(scope, opts) do
    Keyword.get(opts, :environments) || permitted_environments(scope)
  end

  defp telemetry_for_environments(_scope, [], _opts) do
    {:error, "no permitted environments to set up telemetry for"}
  end

  defp telemetry_for_environments(scope, environments, opts) do
    Enum.reduce_while(environments, {:ok, []}, fn environment, {:ok, acc} ->
      case TelemetryStep.run(scope, environment, opts) do
        {:ok, resources} -> {:cont, {:ok, acc ++ resources}}
        {:error, reason} -> {:halt, {:error, reason, acc}}
      end
    end)
  end

  # The environments the devops level permits, not every row the project has
  # (both prod and uat are always seeded, so promoting is one setting).
  # See knowledge/provisioning/steps, "Environments".
  @doc "See `ProvisioningPlan.permitted_environments/1`."
  defdelegate permitted_environments(scope), to: ProvisioningPlan

  @doc "See `ProvisioningPlan.permitted_existing_environments/1`."
  defdelegate permitted_existing_environments(scope), to: ProvisioningPlan

  defp permitted_environment_rows(scope), do: ProvisioningPlan.permitted_environment_rows(scope)

  # The same filter over hosts, for dns, tls and the deploy config check.
  defp permitted_hosts(scope, domain) do
    permitted = MapSet.new(permitted_environments(scope))

    scope
    |> Environments.assign_deployment_hosts(domain)
    |> Enum.filter(&MapSet.member?(permitted, &1.name))
  end

  defp selected_dns_environments(environments, opts) do
    case Keyword.fetch(opts, :environments) do
      :error ->
        {:ok, environments}

      {:ok, names} when is_list(names) and names != [] ->
        if Enum.all?(names, &(is_binary(&1) and &1 != "")) do
          selected = Enum.filter(environments, &(&1.name in names))
          missing = Enum.uniq(names) -- Enum.map(selected, & &1.name)

          if missing == [],
            do: {:ok, selected},
            else:
              {:error,
               "DNS environments are not permitted or do not exist: #{Enum.join(missing, ", ")}"}
        else
          {:error, "DNS environments must be a nonempty list of names"}
        end

      {:ok, _} ->
        {:error, "DNS environments must be a nonempty list of names"}
    end
  end

  defp devops_level(scope), do: ProvisioningPlan.devops_level(scope)

  # For every fan-out step whose permitted environment list is empty: refuse
  # by name rather than report done over zero environments.
  defp no_permitted_environments_message(scope) do
    "no environment is permitted for this project's devops level (#{devops_level(scope)}) — " <>
      "every environment row this project has was filtered out. Add the missing environment " <>
      "before this step can provision anything."
  end

  defp server_name(scope, opts) do
    Keyword.get(opts, :server_name) || Repository.default_name(project(scope))
  end

  # `<project>-<environment>`: each environment its own box — unless it is
  # linked to an account-level server, whose real name is used.
  defp server_name(scope, opts, environment) do
    case linked_server_name(scope, environment) do
      nil -> "#{server_name(scope, opts)}-#{environment}"
      name -> name
    end
  end

  defp linked_server_name(scope, environment_name) do
    with %{device_id: device_id} when is_binary(device_id) <-
           Environments.get_deployment(scope, environment_name),
         %Device{provider_name: name} <- Devices.get_device(scope, device_id) do
      name
    else
      _ -> nil
    end
  end

  # `Generators.audit/3` before anything is built: a config it can prove will
  # fail otherwise costs a build, a migration and a health timeout that reads
  # as an app fault. No environment passes through; `require_script/2` names
  # that later.
  defp deploy_ready(%Scope{} = scope) do
    case env(scope) do
      nil ->
        :ok

      environment ->
        deploy_ready_in(scope, environment)
    end
  end

  defp deploy_ready_in(scope, environment) do
    case CodeMySpec.Generators.audit(scope, router_path(scope), environment) do
      [] ->
        :ok

      findings ->
        {:error,
         "this project is not deploy-ready: " <>
           Enum.map_join(findings, "; ", &CodeMySpec.Generators.explain/1) <>
           ". Setup will not build and ship an image it can already tell will not come up."}
    end
  end

  # Asked before the firewall, because everything after it costs money: the
  # registry on each box needs the object-storage keys. Paused with the
  # storage step's own instructions; `opts[:credentials]` wins.
  defp storage_credentials_ready(%Scope{} = scope, opts) do
    case Keyword.get(opts, :credentials) || Storage.credentials(scope, opts) do
      :none -> {:paused, Storage.credentials_instructions(scope.active_project_id)}
      _credentials -> :ok
    end
  end

  # `origin` from the disposition, never the schema default ("adopted").
  defp repo_resource(repo, disposition) do
    %{
      kind: "repository",
      location: repo["full_name"] || repo["name"],
      origin: repo_origin(disposition),
      identifier: disposition && to_string(disposition)
    }
  end

  defp repo_origin(:adopted), do: "adopted"
  defp repo_origin(_disposition), do: "created"

  # Carries what has been made so far alongside a failure.
  defp made_or_error({:error, reason}, made), do: {:error, reason, made}
  defp made_or_error(result, _made), do: result

  # A missing sub-resource contributes nothing to verify's list.
  defp found_resource({:ok, thing}, build), do: [build.(thing)]
  defp found_resource(_, _build), do: []

  # One server per environment, recorded onto the environment for dns and
  # deploy; a partial failure keeps what was made. The environment list is
  # read once and threaded through, so the fan-out and its checks agree.
  defp ensure_environment_servers(scope, opts, made) do
    case permitted_environment_rows(scope) do
      # Zero environments would report done having built no box.
      [] ->
        {:error, no_permitted_environments_message(scope), made}

      environments ->
        Logger.info(
          "[Provisioning] server step provisioning #{length(environments)} environment(s): " <>
            Enum.map_join(environments, ", ", & &1.name)
        )

        environments
        |> Enum.reduce_while({:ok, made}, &ensure_environment_server(&1, &2, scope, opts))
        |> join_baseline_network(scope, opts, environments)
    end
  end

  # Adopts each box's private network (only `provision_account_server/3`
  # creates one), after the servers are resolved, then serves registries.
  defp join_baseline_network({:ok, made}, scope, opts, environments) do
    servers = environment_servers(scope, opts, environments)

    with {:ok, [_ | _] = servers} <- servers,
         {:ok, networks} <- adopt_zone_networks(scope, servers) do
      finish_baseline_network(scope, servers, networks, opts, environments, made)
    else
      {:ok, []} -> {:ok, made}
      {:paused, message} -> {:paused, message}
      {:error, reason} -> {:error, format(reason), made}
    end
  end

  defp join_baseline_network(other, _scope, _opts, _environments), do: other

  # Keyed by server id, not zone: two servers in one zone can be on different
  # networks. No create path — a server with none pauses. `__adopted__` keeps
  # teardown off it.
  # See knowledge/provisioning/steps, "Account servers and networks".
  defp adopt_zone_networks(scope, servers) do
    Enum.reduce_while(servers, {:ok, %{}}, fn server, {:ok, acc} ->
      case existing_network_id(scope, server) do
        {:ok, network_id} -> adopt_network(scope, server, network_id, acc)
        :error -> {:halt, {:paused, no_account_network_message(server)}}
      end
    end)
  end

  defp adopt_network(scope, server, network_id, acc) do
    Logger.info("[Provisioning] #{server["name"]}: adopting its own network #{network_id}")

    case Hetzner.find_network_by_id(scope, network_id) do
      {:ok, network} ->
        {:cont, {:ok, Map.put(acc, server["id"], Map.put(network, "__adopted__", true))}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp no_account_network_message(server) do
    "#{server["name"]} has no private network yet — provision it from the account-level " <>
      "servers page (or the account-level provisioning tool) first; a project's own devops " <>
      "step never creates one."
  end

  # The attached network in the server's own zone, else the first. A server
  # may hold a wrong-zone network, which Hetzner refuses for anything new.
  defp existing_network_id(scope, server) do
    case server["private_net"] || [] do
      [] ->
        :error

      entries ->
        zone = server |> get_in(["location", "name"]) |> Hetzner.network_zone()

        entries
        |> Enum.map(& &1["network"])
        |> Enum.reject(&is_nil/1)
        |> pick_zone_matching_network(scope, zone)
    end
  end

  defp pick_zone_matching_network([], _scope, _zone), do: :error

  defp pick_zone_matching_network([first | _] = ids, scope, zone) do
    case Enum.find(ids, &network_in_zone?(scope, &1, zone)) do
      nil -> {:ok, first}
      network_id -> {:ok, network_id}
    end
  end

  defp network_in_zone?(_scope, _network_id, nil), do: false

  defp network_in_zone?(scope, network_id, zone) do
    case Hetzner.find_network_by_id(scope, network_id) do
      {:ok, network} -> Enum.any?(network["subnets"] || [], &(&1["network_zone"] == zone))
      _ -> false
    end
  end

  # The server's own network from `adopt_zone_networks/2`.
  defp network_for(server, networks), do: Map.fetch!(networks, server["id"])

  # Split out so both outcomes of `serve_registries/5` can see `networks`.
  defp finish_baseline_network(scope, servers, networks, opts, environments, made) do
    # Keyed by server id, so a shared network would otherwise record twice.
    network_records =
      networks
      |> Map.values()
      |> Enum.uniq_by(& &1["id"])
      |> Enum.map(&network_resource(&1["name"], &1))

    case serve_registries(scope, servers, networks, opts, environments) do
      {:ok, registries} ->
        {:ok, registries ++ network_records ++ made}

      # Every server was attempted independently; record what was built.
      {:error, reason, registries} ->
        {:error, format(reason), registries ++ network_records ++ made}
    end
  end

  # One registry (and database) per environment box — baseline infrastructure,
  # per environment because images do not cross architectures. Iterates the
  # servers found, not the rows, and attempts every one regardless of
  # another's failure.
  # See knowledge/provisioning/steps, "Server baseline".
  defp serve_registries(scope, servers, networks, opts, environments) do
    results =
      Enum.map(servers, &{&1, serve_one_registry(scope, &1, networks, opts, environments)})

    resources = for {_server, {:ok, resources}} <- results, resource <- resources, do: resource

    case Enum.filter(results, fn {_server, result} -> match?({:error, _}, result) end) do
      [] ->
        {:ok, resources}

      failures ->
        message =
          Enum.map_join(failures, "; ", fn {server, {:error, reason}} ->
            "#{environment_of(scope, server, opts, environments)}: #{reason}"
          end)

        {:error, message, resources}
    end
  end

  defp serve_one_registry(scope, server, networks, opts, environments) do
    environment = environment_of(scope, server, opts, environments)
    network = network_for(server, networks)

    with {:ok, server} <- Hetzner.find_server(scope, server["name"]),
         {:ok, ip} <- Hetzner.private_ip(server, network["id"]),
         public when is_binary(public) <- get_in(server, ["public_net", "ipv4", "ip"]),
         {:ok, opts} <- with_builder_ssh(scope, opts),
         {:ok, opts} <- with_registry_credential(scope, opts),
         run = Keyword.get(opts, :run) || Remote.ssh_runner(%{"ip" => public}, opts),
         registry_opts =
           opts
           |> Keyword.put(:environment, environment)
           |> Keyword.put(:run, run)
           # `put_new`: with `:run`, a supplied bind lets a local box stand in
           # (it has no 10.x address to publish on).
           |> Keyword.put_new(:bind, ip),
         # Hetzner returns a server while still initializing; wait for SSH
         # before any command.
         :ok <- await_box(run, opts),
         :ok <- HostBaseline.ensure(run),
         {:ok, registry_bucket} <- Registry.ensure(scope, registry_opts),
         {:ok, served} <- Registry.serve(scope, registry_opts),
         {:ok, database} <- serve_database(scope, environment, run, opts) do
      {:ok,
       [
         %{
           kind: "registry",
           location: "#{ip}:#{served.port}",
           identifier: "environment=#{environment} bucket=#{served.bucket}"
         },
         database
       ] ++ registry_bucket_resource(registry_bucket)}
    else
      {:error, reason} -> {:error, format(reason)}
      _ -> {:error, "the #{environment} server has no address yet"}
    end
  end

  # The app's database, with `DATABASE_URL` and the restore credential written
  # into the environment's encrypted env.
  defp serve_database(scope, environment, run, opts) do
    with {:ok, credential} <- Database.credential(scope, environment),
         {:ok, restore} <- Database.restore_credential(scope, environment),
         {:ok, served} <-
           Database.serve(scope, environment, Keyword.put(opts, :run, run)),
         :ok <- write_database_url(scope, environment, credential),
         :ok <- write_restore_admin_url(scope, environment, restore) do
      {:ok,
       %{
         kind: "database",
         location: "#{served.host}:#{served.port}/#{served.database}",
         identifier: "environment=#{environment}"
       }}
    end
  end

  defp write_database_url(scope, environment, credential) do
    case put_secret(scope, environment, "DATABASE_URL", Database.url(credential)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # `bin/backup restore`'s scratch-database credential (a second role — see
  # `Database`), delivered like `DATABASE_URL`.
  defp write_restore_admin_url(scope, environment, restore) do
    case put_secret(scope, environment, "CMS_RESTORE_ADMIN_URL", Database.restore_url(restore)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The registry's bucket as its own `kind: "bucket"` resource (teardown
  # matches on kind), `origin: "created"` explicitly (the default "adopted" is
  # skipped by teardown). Nothing under filesystem storage.
  defp registry_bucket_resource(:none), do: []

  defp registry_bucket_resource(bucket) when is_binary(bucket),
    do: [%{kind: "bucket", location: bucket, identifier: "registry", origin: "created"}]

  # The builder's wait, with the same `:ssh_attempts`/`:ssh_interval_ms` knobs.
  defp await_box(run, opts) do
    Remote.await_ssh(run, Keyword.get(opts, :ssh_attempts, 90), opts)
  end

  # Which environment a box belongs to, from the name the server step gave it.
  defp environment_of(scope, server, opts, environments) do
    Enum.find_value(environments, "uat", fn environment ->
      environment.name == nil ||
        (server_name(scope, opts, environment.name) == server["name"] && environment.name)
    end)
  end

  # Every environment's box, or a refusal naming the ones missing — a partial
  # baseline must fail here, not two steps later.
  defp environment_servers(scope, opts, environments) do
    found =
      Enum.map(environments, fn environment ->
        name = server_name(scope, opts, environment.name)

        case Hetzner.find_server(scope, name) do
          {:ok, server} -> {:ok, server}
          _ -> {:missing, name}
        end
      end)

    case Enum.filter(found, &match?({:missing, _}, &1)) do
      [] ->
        {:ok, Enum.map(found, fn {:ok, server} -> server end)}

      missing ->
        {:error,
         "the provider does not have " <>
           Enum.map_join(missing, ", ", fn {:missing, name} -> name end) <>
           " — the server step reported creating them, so they were made and then " <>
           "could not be read back"}
    end
  end

  defp ensure_environment_server(environment, {:ok, acc}, scope, opts) do
    name = server_name(scope, opts, environment.name)

    case server_creation_gate(scope, environment, name) do
      :ok ->
        Logger.info("[Provisioning] #{environment.name}: ensuring server #{name}")

        case Hetzner.ensure_server(scope, name, opts) do
          {:ok, server} ->
            Logger.info("[Provisioning] #{environment.name}: got #{inspect(server["name"])}")
            record_environment_server(scope, environment, name, server, acc)

          {:error, reason} ->
            {:halt, {:error, format(reason), acc}}
        end

      {:paused, message} ->
        {:halt, {:paused, message}}
    end
  end

  # An unlinked environment never reaches `Hetzner.ensure_server/3`'s create
  # path — creating servers is `provision_account_server/3`'s job alone. A
  # linked one may: linking is the account's authorization. A linked server
  # missing after a recorded ip (it existed once) pauses instead.
  # See knowledge/provisioning/steps, "Account servers and networks".
  defp server_creation_gate(scope, environment, name) do
    record = Environments.get_deployment(scope, environment.name)
    linked? = linked_server_name(scope, environment.name) != nil
    ever_succeeded? = is_binary(record && record.ip)

    case Hetzner.find_server(scope, name) do
      {:ok, _server} ->
        :ok

      {:error, :not_found} when linked? and ever_succeeded? ->
        {:paused, linked_server_missing_message(environment, name)}

      {:error, :not_found} when linked? ->
        :ok

      {:error, :not_found} ->
        {:paused, new_server_message(scope, environment, name)}

      # Any other provider error is reported by `ensure_server`.
      {:error, _reason} ->
        :ok
    end
  end

  defp new_server_message(scope, environment, name) do
    existing = account_server_names(scope)

    known =
      case existing do
        [] -> ""
        names -> " The account already has: #{Enum.join(names, ", ")}."
      end

    "#{environment.name} has no server linked, and a project's own devops step never " <>
      "creates one.#{known} Link one of those if it should serve this environment, or " <>
      "provision a new server (#{name}) from the account-level servers page first."
  end

  defp linked_server_missing_message(environment, name) do
    "#{environment.name} is linked to #{name}, but the provider no longer has a server by " <>
      "that name. Nothing was rebuilt under a guessed name — find out what happened to " <>
      "#{name} before deciding whether to relink this environment or recreate it."
  end

  defp account_server_names(scope) do
    case Servers.list(scope) do
      {:ok, servers} -> Enum.map(servers, & &1.name)
      {:error, _reason, servers} -> Enum.map(servers, & &1.name)
    end
  end

  # Verify writes the provider's address back onto the environment row, as
  # `run/3` does — DNS, deploy and the TLS diagnostic all read that row. Only
  # when it differs, since every page load verifies.
  defp reconcile_environment_server(scope, environment, name, server) do
    ip = get_in(server, ["public_net", "ipv4", "ip"])
    recorded = Environments.get_deployment(scope, environment)

    if is_binary(ip) and
         (recorded == nil or recorded.ip != ip or recorded.server_name != name or
            is_nil(recorded.device_id)) do
      put_environment_server(scope, environment, name, ip, server)
    end

    server_resource(server, environment)
  end

  # Halts on a failed write-back: an unrecorded box leaks while the step says
  # done.
  defp record_environment_server(scope, environment, name, server, acc) do
    ip = get_in(server, ["public_net", "ipv4", "ip"])

    case put_environment_server(scope, environment.name, name, ip, server) do
      {:ok, _environment} ->
        {:cont, {:ok, [server_resource(server, environment.name) | acc]}}

      {:error, reason} ->
        {:halt,
         {:error,
          "provisioned #{name} but could not record it against the #{environment.name} " <>
            "environment: #{format(reason)}", acc}}
    end
  end

  defp put_environment_server(scope, environment, name, ip, server) do
    with {:ok, device} <- Devices.link_provider_machine(scope, %{name: name, id: server["id"]}) do
      Environments.put_deployment(scope, environment, %{
        server_name: name,
        ip: ip,
        device_id: device.id
      })
    end
  end

  defp find_dns_zone(scope, name, opts) do
    case Keyword.get(opts, :zone) do
      nil -> Cloudflare.find_zone(scope, name)
      zone -> {:ok, zone}
    end
  end

  # One record per environment host, pointing at its own server; production
  # on the apex is data (`assign_hosts/2`), not a branch.
  defp dns_records_for(scope, zone, environments, opts) do
    # Listed once for the whole zone, not once per environment.
    existing =
      case Keyword.fetch(opts, :dns_records) do
        {:ok, records} ->
          records

        :error ->
          case Cloudflare.list_dns_records(scope, zone["id"]) do
            {:ok, records} -> records
            _ -> []
          end
      end

    environments
    |> Enum.filter(& &1.host)
    |> Enum.reduce_while({[], []}, fn environment, {resources, pauses} ->
      case apex_repoint(scope, environment, existing, opts) do
        {:paused, message} ->
          outcome = dns_outcome(environment, "paused-awaiting-confirmation")
          {:cont, {resources ++ [outcome], pauses ++ [message]}}

        :ok ->
          ip = environment_ip(scope, environment, opts)

          if is_nil(ip) do
            {:cont, {resources, pauses}}
          else
            unchanged? =
              Enum.any?(existing, fn record ->
                record["name"] == environment.host and record["type"] == "A" and
                  record["content"] == ip and record["proxied"] != true
              end)

            case write_dns_record_for(scope, zone, environment, ip, existing, resources, opts) do
              {:cont, {:ok, written}} ->
                outcome = if unchanged?, do: "unchanged", else: "written"
                {:cont, {written ++ [dns_outcome(environment, outcome)], pauses}}

              {:halt, {:error, reason}} ->
                {:halt, {:error, reason, resources}}
            end
          end
      end
    end)
    |> case do
      {:error, _, _} = error ->
        error

      {resources, []} ->
        {:ok, resources}

      {resources, pauses} ->
        outcomes =
          resources
          |> Enum.filter(&(&1.kind == "dns_outcome"))
          |> Enum.map_join(", ", & &1.identifier)

        {:paused, "DNS outcomes: #{outcomes}. #{Enum.join(pauses, " ")}", resources}
    end
  end

  defp dns_outcome(environment, outcome) do
    %{
      kind: "dns_outcome",
      location: environment.host,
      identifier: "environment=#{environment.name} outcome=#{outcome}"
    }
  end

  # Refuse to move a live apex without `confirm_apex_repoint: true`: only the
  # apex, and only when an A record already points elsewhere. Decided from the
  # zone's already-listed records.
  # See knowledge/provisioning/steps, "DNS".
  defp apex_repoint(scope, environment, existing, opts) do
    apex = domain(scope)
    confirmed? = Keyword.get(opts, :confirm_apex_repoint, false)

    with false <- confirmed?,
         true <- environment.host == apex,
         ip when is_binary(ip) <- environment_ip(scope, environment, opts),
         %{"content" => current} <-
           Enum.find(existing, &(&1["name"] == apex and &1["type"] == "A")),
         true <- current != ip do
      {:paused,
       "#{apex} already resolves to #{current}, and this would repoint it at #{ip} — a " <>
         "server this run just created. If #{apex} is serving anything today, that takes it " <>
         "down. Nothing else about the run is blocked: production is an environment like any " <>
         "other, so remove the `prod` environment to leave the apex alone, or run DNS " <>
         "for only uat with `run_provisioning_step` and `environment: \"uat\"`, or " <>
         "confirm to repoint it when ready."}
    else
      _ -> :ok
    end
  end

  defp write_dns_record_for(scope, zone, environment, ip, existing, acc, opts) do
    write = Keyword.get(opts, :write_dns_record, &Cloudflare.ensure_dns_record/5)

    case write.(scope, zone["id"], environment.host, ip, records: existing, proxied: false) do
      {:ok, response} ->
        record = dns_resource(environment.host, ip, response, environment.name)
        confirm_dns_record(environment, ip, record, acc, opts)

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  # A record that does not resolve fails this step, not `tls` later.
  defp confirm_dns_record(environment, ip, record, acc, opts) do
    case Dns.resolution_status(environment.host, :a, resolver_opts(opts)) do
      :resolves ->
        {:cont, {:ok, acc ++ [record] ++ dns_verification(environment)}}

      # A cached negative is a fact about a resolver, not the record; no retry
      # outlasts a half-hour negative TTL, so continue.
      {:absent, :cached, seconds} ->
        Logger.info(
          "[Steps] #{environment.host} is published; a public resolver still holds a " <>
            "cached negative with about #{seconds}s left. Continuing."
        )

        {:cont, {:ok, acc ++ [record] ++ dns_verification(environment)}}

      absent ->
        {:halt, {:error, unresolved_record_message(environment, ip, absent)}}
    end
  end

  # Cached negative vs. missing record: one means wait, the other a mistake.
  defp unresolved_record_message(environment, ip, {:absent, :cached, seconds}) do
    "#{environment.host} was written as an A record for #{ip} and is published — " <>
      "but a public resolver is still serving a cached \"does not exist\" for the " <>
      "name, from before it was written, with about #{seconds}s left to run. " <>
      "Nothing is wrong with the record. Re-run this step once that expires; if " <>
      "this name is created and destroyed repeatedly, each cycle starts the wait " <>
      "again."
  end

  defp unresolved_record_message(environment, ip, _fresh) do
    "#{environment.host} was written as an A record for #{ip}, but no public " <>
      "resolver returns it. Everything after this step reaches the name rather " <>
      "than the address, so none of it can work until the record resolves."
  end

  # Records the resolver confirmation `confirm_dns_record/5` already made.
  defp dns_verification(environment) do
    [
      %{
        kind: "dns_verification",
        location: environment.host,
        identifier: "source=resolver environment=#{environment.name}",
        origin: "created"
      }
    ]
  end

  # Qualified against the zone, not the receiving domain: Resend's names are
  # zone-relative.
  defp publish_mx_record(record, {:ok, acc}, scope, zone) do
    record_name = qualify(record["name"], zone["name"])

    case Cloudflare.ensure_dns_record(scope, zone["id"], record_name, record["value"],
           type: "MX",
           priority: record["priority"]
         ) do
      {:ok, _} -> {:cont, {:ok, acc ++ [mx_record_resource(record_name, record)]}}
      {:error, reason} -> {:halt, {:error, format(reason)}}
    end
  end

  defp mx_record_resource(record_name, record) do
    %{
      kind: "mx_record",
      location: "cloudflare/#{record_name}",
      identifier: "#{record["value"]} priority #{record["priority"]}"
    }
  end

  # Own `:resolver_attempts`, not the step-wide `attempts` (sized for a
  # provider verifying a domain); a fresh record resolves in seconds.
  defp resolver_opts(opts) do
    interval = Keyword.get(opts, :interval_ms, 2_000)

    opts
    |> Keyword.take([:resolver])
    |> Keyword.put(:interval_ms, interval)
    |> Keyword.put(:attempts, Keyword.get(opts, :resolver_attempts, 15))
    |> Keyword.put(:settle_ms, settle_ms(opts, interval))
  end

  # Settle before the first lookup: asking too early caches the negative the
  # retries cannot get past. Zero when `interval_ms` is (replay).
  defp settle_ms(opts, 0), do: Keyword.get(opts, :resolver_settle_ms, 0)
  defp settle_ms(opts, _interval), do: Keyword.get(opts, :resolver_settle_ms, 5_000)

  # Prefer what the server step recorded on the environment; fall back to
  # asking Hetzner, so a project provisioned before environments existed still
  # resolves.
  defp environment_ip(_scope, %{ip: ip}, _opts) when is_binary(ip) and ip != "", do: ip

  defp environment_ip(scope, %{name: name}, opts) do
    case Hetzner.find_server(scope, server_name(scope, opts, name)) do
      {:ok, server} -> get_in(server, ["public_net", "ipv4", "ip"])
      _ -> nil
    end
  end

  defp dns_resource(record_name, ip, response, environment) do
    %{
      kind: "dns_record",
      location: "cloudflare/#{record_name}",
      identifier: "#{ip} environment=#{environment}",
      origin: origin(response["result"] || %{})
    }
  end

  # Recorded so teardown can find it; a leaked network holds a subnet.
  defp network_resource(name, network),
    do: %{kind: "network", location: "hetzner/#{name}", origin: origin(network)}

  defp firewall_resource(name, firewall),
    do: %{kind: "firewall", location: "hetzner/#{name}", origin: origin(firewall)}

  defp ssh_key_resource(name, ssh_key) do
    %{
      kind: "ssh_key",
      location: "hetzner/#{name}",
      identifier: ssh_key["fingerprint"],
      origin: origin(ssh_key)
    }
  end

  defp server_resource(server, environment) do
    server
    |> server_resource()
    |> Map.update!(:identifier, &"#{&1} environment=#{environment}")
  end

  # The IP as identifier: present on both create and find (`datacenter` is
  # not), and what DNS points at.
  defp server_resource(server) do
    %{
      kind: "server",
      location: "hetzner/#{server["name"]}",
      identifier: get_in(server, ["public_net", "ipv4", "ip"]),
      origin: origin(server)
    }
  end

  # Providers mark what they reused (`__adopted__`); unmarked reads created.
  # Verify's `find_*` results are deliberately left unmarked.
  # See knowledge/provisioning/steps, "Origin".
  defp origin(%{"__adopted__" => true}), do: "adopted"
  defp origin(_), do: "created"

  # Checked first: `ExecutionContexts.cmd/4` raises :enoent on a missing executable.
  # The error names what is missing via `Generators`.
  defp require_script(scope, path) do
    case env(scope) do
      nil -> {:error, no_environment_message()}
      environment -> require_script_in(scope, environment, path)
    end
  end

  # Steps that shell out need an environment; a nil one would crash in
  # `ExecutionContexts.cmd/4` instead of erroring one step.
  defp no_environment_message do
    "this project has no working environment, so setup cannot run commands for it. " <>
      "The steps that shell out — the repository push, the deploy, and backups — need a " <>
      "checkout on a machine setup can reach."
  end

  defp require_script_in(scope, environment, path) do
    if script_executable?(environment, path) do
      :ok
    else
      findings = CodeMySpec.Generators.audit(scope, router_path(scope), environment)

      case {findings, ExecutionContexts.file_exists?(environment, path), environment.type} do
        # A harness cannot inspect executable bits. Its clean audit already
        # checked the `Files` sync table, so presence is sufficient here.
        {[], true, :harness} ->
          :ok

        {[], false, _} ->
          :ok

        # Local and sprite contexts can inspect mode: this is a real permission problem.
        {[], true, _} ->
          deploy_not_ready_error("#{path} is not present or not executable")

        {findings, _, _} ->
          detail = Enum.map_join(findings, "; ", &CodeMySpec.Generators.explain/1)
          deploy_not_ready_error(detail)
      end
    end
  end

  # Local's generic exec_file_exists?/2 checks presence for tools such as mix.exs.
  # Deploy scripts need the executable bit as well.
  defp script_executable?(%{type: :local, cwd: cwd}, path) when is_binary(cwd) do
    case File.stat(Path.join(cwd, path)) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp script_executable?(environment, path),
    do: ExecutionContexts.exec_file_exists?(environment, path)

  defp deploy_not_ready_error(detail) do
    {:error,
     "this project is not deploy-ready: #{detail}. " <>
       "The boilerplate ships with `cms new`; a project generated another way has to add it."}
  end

  @doc """
  Commit the files setup generated (`.sops.yaml`, `envs/`, the deploy
  boilerplate) so `bin/deploy`, which refuses a dirty tree, can ship. Only
  setup's own paths are staged; anything else stays uncommitted.

  `:ok` without touching anything when the environment has no `cwd` (a
  harness-only checkout the server cannot write to), no repository, or
  nothing staged. Public so the guard can be tested directly.
  """
  @spec commit_generated_configuration(Scope.t()) :: :ok | {:error, String.t()}
  def commit_generated_configuration(scope) do
    case env(scope) do
      # The checkout is on another machine and its harness runs no git; the
      # agent working there commits.
      %{type: :harness} ->
        :ok

      %{cwd: cwd} = environment when is_binary(cwd) ->
        commit_generated_configuration_in(environment)

      _ ->
        :ok
    end
  end

  defp commit_generated_configuration_in(environment) do
    paths =
      [".sops.yaml", "envs"]
      |> Enum.concat(Enum.map(DeployBoilerplate.manifest(), & &1.path))
      |> Enum.filter(&ExecutionContexts.file_exists?(environment, &1))

    with true <- work_tree?(environment),
         {_, 0} <- git(environment, ["add", "--"] ++ paths),
         false <- nothing_staged?(environment) do
      commit_staged(environment)
    else
      # Nothing of ours changed, or no repository (e.g. an injected build):
      # neither is a failure.
      false -> :ok
      true -> :ok
      {output, status} -> {:error, "could not stage setup's files (#{status}): #{output}"}
    end
  end

  # Asked first: `git add` outside a repository fails like a real staging
  # error.
  defp work_tree?(environment) do
    match?({_, 0}, git(environment, ["rev-parse", "--is-inside-work-tree"]))
  end

  defp nothing_staged?(environment) do
    match?({_, 0}, git(environment, ["diff", "--cached", "--quiet"]))
  end

  # `-c user.*`: the machine need not have a git identity.
  defp commit_staged(environment) do
    args = [
      "-c",
      "user.email=setup@codemyspec.com",
      "-c",
      "user.name=CodeMySpec Setup",
      "commit",
      "-q",
      "-m",
      "Setup-generated configuration"
    ]

    case git(environment, args) do
      {_, 0} -> :ok
      {output, status} -> {:error, "could not commit setup's files (#{status}): #{output}"}
    end
  end

  defp git(environment, args),
    do: ExecutionContexts.cmd(environment, "git", args, stderr_to_stdout: true)

  # Setup generates its own keypair (the operator's key is not on hosted
  # machines); the private half lives only in `AccountSecrets`.
  defp ensure_access_key(scope, name) do
    with {:ok, public} <- access_public_key(scope, name) do
      Hetzner.ensure_ssh_key(scope, name, public)
    end
  end

  # Account first, then the project (older installs): the key must open every
  # box the account owns, including ones no project made.
  defp access_public_key(scope, name) do
    case AccountSecrets.fetch_account_then_project(scope, @access_key_public) do
      {:ok, _value} = ok -> ok
      {:error, :not_found} -> generate_access_key(scope, name)
    end
  end

  defp generate_access_key(scope, name) do
    dir = TempFile.dir("cms-ssh")
    File.mkdir_p!(dir)
    path = Path.join(dir, "id_ed25519")

    try do
      case System.cmd("ssh-keygen", ["-t", "ed25519", "-N", "", "-C", name, "-f", path],
             stderr_to_stdout: true
           ) do
        {_out, 0} ->
          private = File.read!(path)
          public = File.read!(path <> ".pub")

          # Account grain, so one key opens every box the account owns.
          AccountSecrets.put_value(scope, @access_key_private, private)
          AccountSecrets.put_value(scope, @access_key_public, public)

          {:ok, public}

        {out, status} ->
          {:error,
           "could not generate an access key (ssh-keygen exit #{status}): #{String.trim(out)}"}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp require_value(nil, what),
    do: {:error, "the widget step needs #{what}, and this project has none set"}

  defp require_value(value, _what), do: {:ok, value}

  # The primary environment's host, not the apex (which has no record when
  # prod is off); the domain is the fallback.
  defp site_url(scope, opts) do
    host =
      case primary_environment(scope, opts) do
        name when is_binary(name) -> environment_host(scope, name) || domain(scope)
        _ -> domain(scope)
      end

    case host do
      nil -> nil
      name -> "https://#{name}"
    end
  end

  defp router_path(scope) do
    "lib/#{app_path(scope)}_web/router.ex"
  end

  # Runs the backup on the environment's own box, where `cms-postgres`
  # resolves (and so its systemd schedule is not installed locally). HEAD is
  # delivered to the fixed `@backup_dir` over SSH, since the box runs a
  # container, not a checkout.
  defp on_the_environments_box(scope, environment, opts) do
    with {:ok, ssh_opts} <- with_builder_ssh(scope, opts),
         ip when is_binary(ip) and ip != "" <-
           environment_ip(scope, environment_row(scope, environment), ssh_opts),
         server = %{"ip" => ip},
         deliver = Remote.ssh_deliver(server, ssh_opts),
         :ok <- deliver.("HEAD", @backup_dir) do
      {:ok,
       opts
       |> Keyword.put(:run, Remote.ssh_runner(server, ssh_opts))
       |> Keyword.put(:remote_dir, @backup_dir)}
    else
      {:error, reason} ->
        {:error, "could not reach #{environment}'s server to back it up: #{format(reason)}"}

      _ ->
        {:error,
         "no address is recorded for #{environment}, so there is no box to run its backup on"}
    end
  end

  defp environment_row(scope, environment) do
    Environments.get_deployment(scope, environment) || %{name: environment}
  end

  defp awaiting_first_message(site) do
    "The widget is installed on #{site} and opens, and setup asked the site " <>
      "to send a message through its own client — but none has arrived here. " <>
      "The likeliest reason is that the deployed application is pointed at a " <>
      "different CodeMySpec than this one: `CODEMYSPEC_WIDGET_URL` defaults to " <>
      "the hosted service, so an app provisioned by any other server sends its " <>
      "messages there. Otherwise the socket, the deploy key or CORS is wrong, " <>
      "and all three can be wrong while the markup is right. A message from a " <>
      "real visitor at #{site} proves it just as well; resume once one exists."
  end

  # The app's path segment: `mix.exs`'s `app:` when the checkout is readable,
  # else the `module_name` the harness reports on sync, else `nil` — never a
  # guessed `app`.
  defp app_path(scope) do
    case env(scope) do
      nil ->
        module_name_app_path(scope)

      environment ->
        ExecutionContexts.mix_exs_app_name(environment) || module_name_app_path(scope)
    end
  end

  defp module_name_app_path(scope) do
    case project(scope) |> Map.get(:module_name) do
      name when is_binary(name) and name != "" -> Macro.underscore(name)
      _ -> nil
    end
  end

  # Receiving is at the apex by decision: sending owns the `send` subdomain,
  # and the app is meant to receive the domain's mail. `:inbound_subdomain`
  # moves it aside.
  # See knowledge/provisioning/steps, "Inbound".
  defp receiving_domain(scope, opts) do
    case base_domain(scope, opts) do
      nil ->
        nil

      base ->
        case Keyword.get(opts, :inbound_subdomain) do
          nil -> base
          "" -> base
          sub -> sub <> "." <> base
        end
    end
  end

  # Where Resend POSTs a received message: the app itself.
  defp webhook_endpoint(scope, opts) do
    Keyword.get(opts, :webhook_endpoint) ||
      "https://#{Keyword.get(opts, :app_host) || domain(scope)}/webhooks/resend"
  end

  # Seeds `RESEND_WEBHOOK_SECRET` so the app can verify webhook signatures.
  # Resend returns `signing_secret` only on create, so an adopted webhook has
  # none. Best-effort and logged: the app degrades to unverified, and inbound
  # still works.
  defp seed_webhook_secret(scope, %{"signing_secret" => secret})
       when is_binary(secret) and secret != "" do
    resources =
      scope
      |> Environments.deployment_names()
      |> Enum.flat_map(fn environment ->
        case put_secret(scope, environment, "RESEND_WEBHOOK_SECRET", secret) do
          {:ok, _} ->
            [%{kind: "secret", location: "#{environment}/RESEND_WEBHOOK_SECRET"}]

          {:error, reason} ->
            Logger.warning(
              "[Steps] could not seed RESEND_WEBHOOK_SECRET for #{environment}: " <>
                "#{inspect(reason)} — inbound still works, signature verification " <>
                "stays off until this is seeded"
            )

            []
        end
      end)

    {:ok, resources}
  end

  defp seed_webhook_secret(_scope, _webhook), do: {:ok, []}

  # The MX Resend hands back, published at the priority it specifies. Resend
  # only receives when its MX is the lowest priority for the name, so the
  # value is copied from the provider rather than chosen here.
  defp publish_mx(scope, name, domain, opts) do
    # Re-read by id: an adopted domain comes from the list, which omits
    # `records`.
    case Resend.mx_records(inbound_records_for(scope, domain)) do
      [] ->
        {:error,
         "Resend returned no MX record for #{name}, so there is nothing to publish — " <>
           "the domain cannot receive mail without one"}

      records ->
        base = base_domain(scope, opts)

        with {:ok, zone} <- Cloudflare.find_zone(scope, base),
             :ok <- check_competing_mx(scope, zone, records, opts),
             {:ok, published} <-
               Enum.reduce_while(records, {:ok, []}, &publish_mx_record(&1, &2, scope, zone)) do
          confirm_cleared(scope, zone, records, opts, published)
        end
    end
  end

  # After a confirmed repoint, any competing MX that survived is an error.
  # Only when confirmed: MX may legitimately be split across providers.
  defp confirm_cleared(scope, zone, records, opts, published) do
    if Keyword.get(opts, :confirm_inbound_mx_repoint, false) do
      with {:ok, existing} <- Cloudflare.list_dns_records(scope, zone["id"]) do
        published_unless_survivors(zone, records, existing, published)
      end
    else
      {:ok, published}
    end
  end

  defp published_unless_survivors(zone, records, existing, published) do
    case competing_records(zone, records, existing) do
      [] ->
        {:ok, published}

      survivors ->
        named = Enum.map_join(survivors, ", ", &"#{&1["content"]} (#{&1["name"]})")

        {:error,
         "confirmed and published, but #{length(survivors)} competing record(s) are " <>
           "still there afterward: #{named} — the replace did not fully take; run again"}
    end
  end

  @doc """
  MX records in `existing` that still disagree with what `records` wants.

  Public so the survivor check can be tested directly; the race it guards
  against is not reproducible against the fake.
  """
  def competing_records(zone, records, existing) do
    records
    |> Enum.flat_map(fn record ->
      record_name = qualify(record["name"], zone["name"])

      Enum.filter(
        existing,
        &(&1["name"] == record_name and &1["type"] == "MX" and &1["content"] != record["value"])
      )
    end)
    |> Enum.uniq_by(& &1["id"])
  end

  # `Cloudflare.ensure_dns_record/5` would overwrite an existing MX with other
  # content, possibly taking over someone's inbox; so this refuses unless
  # `confirm_inbound_mx_repoint`, the MX analogue of `apex_repoint/4`.
  defp check_competing_mx(scope, zone, records, opts) do
    if Keyword.get(opts, :confirm_inbound_mx_repoint, false) do
      clear_competing_mx(scope, zone, records)
    else
      refuse_competing_mx(scope, zone, records)
    end
  end

  defp refuse_competing_mx(scope, zone, records) do
    with {:ok, existing} <- Cloudflare.list_dns_records(scope, zone["id"]) do
      records
      |> Enum.find_value(fn record ->
        record_name = qualify(record["name"], zone["name"])

        Enum.find(
          existing,
          &(&1["name"] == record_name and &1["type"] == "MX" and
              &1["content"] != record["value"])
        )
      end)
      |> case do
        nil ->
          :ok

        %{"name" => record_name, "content" => current} ->
          {:error, {:competing_mx, record_name, current}}
      end
    end
  end

  # A confirmation deletes the whole competing set before publishing —
  # `ensure_dns_record/5` would update only the first match. Matching records
  # are left alone.
  # See knowledge/provisioning/steps, "Inbound".
  defp clear_competing_mx(scope, zone, records) do
    with {:ok, existing} <- Cloudflare.list_dns_records(scope, zone["id"]) do
      zone
      |> competing_records(records, existing)
      |> Enum.reduce_while(:ok, &delete_stale_mx(&1, &2, scope, zone))
    end
  end

  defp delete_stale_mx(stale, :ok, scope, zone) do
    case Cloudflare.delete_dns_record(scope, zone["id"], stale["id"]) do
      {:ok, _} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  # Resend names records relative to the zone (`"mail"`, or `""` at the apex),
  # so always qualify against the zone, never the receiving domain.
  defp qualify(nil, domain), do: domain
  defp qualify("", domain), do: domain
  defp qualify("@", domain), do: domain
  defp qualify(name, domain), do: "#{name}.#{domain}"

  # The registrable domain the zone is looked up by. Shared with
  # `receiving_domain/2` so both read the same option.
  defp base_domain(scope, opts) do
    Keyword.get(opts, :domain) || Keyword.get(opts, :inbound_domain) || domain(scope)
  end

  defp bucket_resource(bucket, opts) do
    location = Keyword.get(opts, :location, "fsn1")

    %{
      kind: "bucket",
      location: "#{location}.your-objectstorage.com/#{bucket}",
      identifier: "user"
    }
  end

  # Not owned means not in this account, not "available": the Registrar API
  # cannot sell a name the account does not hold, so this sends the user to
  # the Cloudflare dashboard.
  defp not_owned_message(name) do
    "#{name} is not registered to this account. This app cannot register a " <>
      "name it does not already hold — the Registrar API will not price or " <>
      "sell it. Buy #{name} in the Cloudflare dashboard, then return here and " <>
      "setup will adopt it."
  end

  # One key per environment, and the private half never leaves ProjectSecrets
  # — it reaches a server through the deploy, not a file on disk.
  defp generate_keys(scope, env, environments) do
    keys =
      Enum.reduce_while(environments, {:ok, %{}}, fn environment, {:ok, acc} ->
        case key_for(scope, env, environment) do
          {:ok, public} -> {:cont, {:ok, Map.put(acc, environment, public)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, recipients} <- keys,
         :ok <- Sops.write_config(env, with_other_environment_recipients(scope, recipients)),
         {:ok, seeded} <- seed_secret_key_base(scope, env, recipients),
         {:ok, issued} <- seed_deploy_key(scope, recipients) do
      {:ok,
       Enum.map(recipients, fn {environment, public} ->
         %{kind: "age_key", location: "secrets/#{environment}", identifier: public}
       end) ++ seeded ++ issued}
    else
      {:error, reason} -> {:error, format(reason)}
    end
  end

  # `.sops.yaml` names every environment with a stored key, not only the ones
  # this run touched — a devops-filtered run must not drop another
  # environment's rule. Derived from `ProjectSecrets`, so a key with no file
  # yet is kept too.
  defp with_other_environment_recipients(scope, recipients) do
    names = Environments.deployment_names(scope) -- Map.keys(recipients)

    Enum.reduce(names, recipients, fn environment, acc ->
      with {:ok, private} <- fetch_age_key(scope, environment),
           {:ok, public} <- Sops.public_key(private) do
        Map.put(acc, environment, public)
      else
        # No stored key, or one sops itself cannot derive from — nothing to
        # carry forward for this environment, same as before it existed.
        _ -> acc
      end
    end)
  end

  # The key the deployed app authenticates back with, written into every
  # environment's encrypted env as `DEPLOY_KEY` (with `CODEMYSPEC_WIDGET_URL`).
  # Minted at the secrets step because the app reads it at boot, so it must
  # exist before the deploy. Only when absent: rotating would break a running
  # app.
  defp seed_deploy_key(scope, recipients) do
    project = project(scope)

    case Map.get(project, :deploy_key) do
      key when is_binary(key) and key != "" -> place_deploy_key(scope, recipients, key)
      _ -> mint_deploy_key(scope, recipients, project)
    end
  end

  defp mint_deploy_key(scope, recipients, project) do
    key = "dk_" <> random_secret()

    case Projects.update_project(scope, project, %{deploy_key: key}) do
      {:ok, _project} -> place_deploy_key(scope, recipients, key)
      {:error, reason} -> {:error, reason}
    end
  end

  defp place_deploy_key(scope, recipients, key) do
    Enum.reduce_while(recipients, {:ok, []}, fn {environment, _public}, {:ok, acc} ->
      with {:ok, _} <- put_secret(scope, environment, "DEPLOY_KEY", key),
           {:ok, _} <-
             put_secret(scope, environment, "CODEMYSPEC_WIDGET_URL", widget_socket_url()) do
        resource = %{
          kind: "secret",
          location: "#{environment}/DEPLOY_KEY",
          identifier: "generated=true"
        }

        {:cont, {:ok, acc ++ [resource]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # This server's widget socket URL. Generated apps default to the hosted
  # service, so an app provisioned by any other server would talk to the
  # wrong CodeMySpec.
  defp widget_socket_url do
    base = Application.get_env(:code_my_spec, :base_url) || "https://codemyspec.com"

    case URI.parse(base) do
      %URI{scheme: "http"} = uri -> %{uri | scheme: "ws", path: "/widget"}
      uri -> %{uri | scheme: "wss", path: "/widget"}
    end
    |> URI.to_string()
  end

  # SECRET_KEY_BASE is entropy, so setup mints it (DATABASE_URL comes from
  # `serve_database/4`). Only when absent: rotating would invalidate every
  # signed cookie and session.
  defp seed_secret_key_base(scope, env, recipients) do
    Enum.reduce_while(recipients, {:ok, []}, fn {environment, _public}, {:ok, acc} ->
      case secret_key_base_missing?(scope, env, environment) do
        {:ok, false} -> {:cont, {:ok, acc}}
        {:ok, true} -> mint_secret_key_base(scope, environment, acc)
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Everything `serve_database/4` writes; verify checks all of them so a
  # missing one sends the server step back through `run/3`.
  @database_secrets ["DATABASE_URL", "CMS_RESTORE_ADMIN_URL"]

  defp database_secrets_present?(scope, environment) do
    # Without sops nothing can tell (or deploy); don't rebuild over a missing
    # tool.
    if Sops.available?() do
      with {:ok, private} <- fetch_age_key(scope, environment),
           {:ok, missing} <-
             Sops.missing_secrets(env(scope), environment, private, @database_secrets) do
        missing == []
      else
        # Short of proof, absent: an unopenable file is as useless to the app
        # as a missing value.
        _ -> false
      end
    else
      true
    end
  end

  # Every environment's registry asked once over SSH, with one account key
  # for the whole walk, removed in `after` (this runs on every status read).
  defp registries_reachable?(scope, environments, opts) do
    case with_builder_ssh(scope, opts) do
      {:ok, ssh_opts} -> registries_reachable_with_ssh(scope, environments, ssh_opts)
      _ -> false
    end
  end

  defp registries_reachable_with_ssh(scope, environments, ssh_opts) do
    Enum.all?(environments, &registry_reachable?(scope, &1, ssh_opts))
  after
    case Keyword.get(ssh_opts, :builder_key_dir) do
      dir when is_binary(dir) -> File.rm_rf(dir)
      _ -> :ok
    end
  end

  # The same lookups `serve_one_registry/5` makes — public IP, and the private
  # IP on the server's own network (`existing_network_id/2`, never by name) —
  # then asks whether the registry answers. A supplied `:run` wins.
  defp registry_reachable?(scope, environment, opts) do
    name = server_name(scope, opts, environment)

    with {:ok, server} <- Hetzner.find_server(scope, name),
         public when is_binary(public) and public != "" <-
           get_in(server, ["public_net", "ipv4", "ip"]),
         {:ok, network_id} <- existing_network_id(scope, server),
         {:ok, bind} <- Hetzner.private_ip(server, network_id) do
      run = Keyword.get(opts, :run) || Remote.ssh_runner(%{"ip" => public}, opts)
      Registry.reachable?(scope, Keyword.merge(opts, run: run, bind: bind))
    else
      _ -> false
    end
  end

  defp secret_key_base_missing?(scope, env, environment) do
    with {:ok, private} <- fetch_age_key(scope, environment),
         {:ok, missing} <- Sops.missing_secrets(env, environment, private, ["SECRET_KEY_BASE"]) do
      {:ok, "SECRET_KEY_BASE" in missing}
    end
  end

  defp mint_secret_key_base(scope, environment, acc) do
    case put_secret(scope, environment, "SECRET_KEY_BASE", phoenix_secret()) do
      {:ok, _} ->
        resource = %{
          kind: "secret",
          location: "#{environment}/SECRET_KEY_BASE",
          identifier: "generated=true"
        }

        {:cont, {:ok, [resource | acc]}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  # Phoenix refuses a `secret_key_base` shorter than 64 bytes, so this is sized
  # like `mix phx.gen.secret` rather than like `random_secret/0`.
  defp phoenix_secret, do: 64 |> :crypto.strong_rand_bytes() |> Base.encode64(padding: false)

  # Reuses the key on record unless it no longer opens its file — minting
  # unconditionally destroys every existing secret on re-run. Genuine drift
  # mints.
  # See knowledge/provisioning/steps, "Secrets".
  defp key_for(scope, env, environment) do
    with true <- key_opens_its_own_file?(scope, environment),
         {:ok, private} <- ProjectSecrets.fetch_value(scope, age_key_name(environment)),
         {:ok, public} <- Sops.public_key(private) do
      {:ok, public}
    else
      _ -> mint_key(scope, env, environment)
    end
  end

  # A fresh key discards the old `.enc.env`: nobody can decrypt it, and
  # keeping it would make verify report drift forever.
  defp mint_key(scope, env, environment) do
    with {:ok, {public, private}} <- Sops.generate_key(),
         {:ok, _} <- ProjectSecrets.put_value(scope, age_key_name(environment), private) do
      discard_unreadable_env(env, environment)
      {:ok, public}
    end
  end

  defp discard_unreadable_env(env, environment) do
    path = Sops.env_file(environment)

    case ExecutionContexts.file_exists?(env, path) do
      true ->
        Logger.warning(
          "[Secrets] #{environment}'s encrypted env was written to a key that no longer " <>
            "exists — discarding #{path}, its contents cannot be decrypted by anyone."
        )

        ExecutionContexts.delete_file(env, path)

      _ ->
        :ok
    end
  end

  @doc """
  Set one secret in an environment's encrypted file.

  Public because the setup page offers it. The plaintext goes to `sops set`
  as an argument and is never written to the working tree. Mints the
  environment's age key if it has none.
  """
  @spec put_secret(Scope.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def put_secret(%Scope{} = scope, environment, key, value) do
    case env(scope) do
      nil ->
        {:error, no_environment_message()}

      resolved_environment ->
        put_secret_in(scope, resolved_environment, environment, key, value)
    end
  end

  @doc """
  Import every `KEY=value` line of `dotenv` into an environment's encrypted
  file, one `put_secret/4` call per key.

  The bulk path for an app that already has its own secrets -- its own
  `.env`, or a value copied from wherever it currently lives -- rather than
  retyping them one at a time through the form, or letting a later step
  mint fresh ones over values that already exist (story 967, issue
  a634ffac: SECRET_KEY_BASE imported this way is on file before the secrets
  step ever runs, so `seed_secret_key_base/3` finds it present and keeps it).

  Comments and blank lines are skipped, same as `Sops.parse_dotenv/1` does
  reading a file back. Stops at the first key that fails to write rather
  than importing a partial set silently.
  """
  @spec import_dotenv(Scope.t(), String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def import_dotenv(%Scope{} = scope, environment, dotenv) when is_binary(dotenv) do
    dotenv
    |> Sops.parse_dotenv()
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, acc} ->
      case put_secret(scope, environment, key, value) do
        {:ok, _} -> {:cont, {:ok, [key | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, keys} -> {:ok, Enum.reverse(keys)}
      error -> error
    end)
  end

  defp put_secret_in(scope, resolved_environment, environment, key, value) do
    with {:ok, private} <- ensure_age_key(scope, resolved_environment, environment),
         :ok <- Sops.put_secret(resolved_environment, environment, key, value, private) do
      {:ok, %{environment: environment, key: key, file: Sops.env_file(environment)}}
    else
      {:error, reason} -> {:error, to_string_reason(reason)}
    end
  end

  # Mints the environment's key if it has none rather than refusing — no
  # ordering dependency on the secrets step.
  defp ensure_age_key(scope, env, environment) do
    case fetch_age_key(scope, environment) do
      {:ok, private} ->
        {:ok, private}

      {:error, :not_found} ->
        with {:ok, {public, private}} <- Sops.generate_key(),
             {:ok, _} <- ProjectSecrets.put_value(scope, age_key_name(environment), private),
             :ok <- write_recipients(scope, env, environment, public) do
          {:ok, private}
        end
    end
  end

  # Writing one environment's key must not drop another's recipient.
  defp write_recipients(scope, env, environment, public) do
    recipients = with_other_environment_recipients(scope, %{environment => public})
    Sops.write_config(env, recipients)
  end

  @doc "The age recipients each environment's encrypted file names."
  @spec recipients(Scope.t(), [String.t()]) :: [
          %{environment: String.t(), fingerprints: [String.t()]}
        ]
  def recipients(%Scope{} = scope, environments) do
    case env(scope) do
      nil ->
        []

      resolved_environment ->
        for environment <- environments,
            {:ok, keys} <- [Sops.recipients(resolved_environment, environment)],
            keys != [] do
          %{environment: environment, fingerprints: keys}
        end
    end
  end

  defp fetch_age_key(scope, environment) do
    case ProjectSecrets.fetch_value(scope, age_key_name(environment)) do
      {:ok, key} when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Record an environment's age key when it was generated somewhere this
  server cannot reach, not minted by `ensure_age_key/3` itself.

  For a project reached only through the harness, whose key was generated
  on its own checkout: without it on file, the next decrypting step would
  mint a different key under the same name.

  Returns the derived public key, so the caller can check it against the
  committed `.sops.yaml`.
  """
  @spec import_age_key(Scope.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def import_age_key(%Scope{} = scope, environment, private_key) when is_binary(private_key) do
    with {:ok, public} <- Sops.public_key(private_key),
         {:ok, _} <- ProjectSecrets.put_value(scope, age_key_name(environment), private_key) do
      {:ok, public}
    end
  end

  defp to_string_reason(reason) when is_binary(reason), do: reason

  # A harness-scoped scope has no working directory; say so in words.
  defp to_string_reason(:no_working_directory),
    do: "this project has no local working directory to write secrets into"

  defp to_string_reason(reason), do: inspect(reason)

  @doc "The `ProjectSecrets` key an environment's private age key is stored under."
  @spec age_key_name(String.t()) :: String.t()
  def age_key_name(environment), do: "age_private_key_#{environment}"

  defp host(scope, opts) do
    Keyword.get(opts, :host) || domain(scope)
  end

  defp random_secret, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  # Connected once, not usable now — expired past renewal, or the provider
  # refused the refresh. Names the account action that fixes it rather than
  # leaving a tuple on the page.
  defp format({:resend_token_unusable, reason}),
    do:
      "Resend is connected but its authorization is no longer usable " <>
        "(#{inspect(reason)}). Reconnect Resend for this account, then run this step again."

  defp format(reason) when is_binary(reason), do: reason

  # Transport failures in words (`Transport.describe/1`) rather than nested
  # inspected structs.
  defp format(%{reason: reason}) when is_atom(reason), do: format_transport(reason)
  defp format({:error, reason}), do: format(reason)
  defp format(reason) when is_atom(reason), do: format_transport(reason)

  # No inspect limits: build logs arrive inside tuples and the reason is at
  # the end, which the defaults cut off.
  defp format(reason), do: inspect(reason, printable_limit: :infinity, limit: :infinity)

  defp format_transport(reason), do: Transport.describe(reason)
end
