defmodule CodeMySpec.Provisioning.Steps do
  @moduledoc """
  Adapts each provider module to the one shape the sequence runs.

  ## Why this module exists at all

  No two providers share a signature. `Hetzner.ensure_server/3` takes a scope,
  `Deploy.run/3` takes an environment, `Repository.run/4` takes both plus the
  project, and `Sops.put_secret/5` takes an environment name and a private
  key. That is right for each of them in isolation — a provider should ask for
  what it needs — and useless to a sequencer, which needs one call it can make
  fourteen times.

  So the adapting happens here, once, rather than each provider being bent to
  a common interface it does not want.

  ## Two functions, and the difference matters

  - `verify/3` asks the provider whether the resource exists **right now**.
    Never reads persisted state. This is what makes a re-run converge and a
    resource deleted behind setup's back get rebuilt.
  - `run/3` does the work.

  A step that cannot be verified returns `{:ok, :absent}`, which means "run
  it". That is the safe default: running an idempotent step twice is
  harmless, whereas skipping one that was never done is a broken foundation.

  ## Steps with no provider yet

  Every step in the sequence now reaches a provider. The catch-all clause
  stays: a key added to `Sequence` without a runner returns
  `{:error, {:not_implemented, key}}` naming itself, so it halts visibly
  rather than reporting done for work that never happened. Reporting success
  for an unimplemented step is the exact failure `Provisioning` exists to
  prevent, so it is better to be loudly incomplete.
  """

  require Logger

  alias CodeMySpec.{AccountSecrets, Conversations, Deploys, Environments, Projects, ProjectSecrets}
  alias CodeMySpec.Generators.DeployBoilerplate
  alias CodeMySpec.TempFile

  alias CodeMySpec.Provisioning.{
    Backups,
    Builder,
    Builder.Remote,
    Cloudflare,
    ContentPublishing,
    Database,
    Deploy,
    Dns,
    EnvironmentRepository,
    Hetzner,
    Registry,
    Repository,
    Resend,
    Sops,
    StepRepository,
    Storage,
    Transport,
    Wait,
    Widget
  }

  alias CodeMySpec.Users.Scope

  # The access key opens every box the account owns, so it lives at the
  # account grain — see `access_public_key/2`.
  @access_key_public "server_ssh_public_key"
  @access_key_private "server_ssh_private_key"

  @type outcome ::
          {:ok, [map()]}
          | {:paused, String.t()}
          | {:error, term()}
          # Failed, but these resources were created before it did. See
          # `Provisioning.run_and_record/4` for why the partial list matters.
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
  # Deliberately never satisfied from the provider.
  #
  # The other steps can be verified by asking whether the resource is there,
  # because for them existing *is* the claim. This step's claim is that the
  # project's history reached the remote — "the step is proven by a push, not
  # by the repository existing" (8183). A repository can exist and be the wrong
  # one (8185), or be the right one and reject the push (8184), and asking
  # GitHub whether it exists cannot tell any of those apart.
  #
  # So the decision is left to `run/3`, which adopts or asks, pushes, and
  # reports what actually happened. Re-running is cheap and idempotent: a push
  # of a history the remote already has is "Everything up-to-date".
  def verify(:repository, %Scope{} = _scope, _opts), do: {:ok, :absent}

  def verify(:server, %Scope{} = scope, opts) do
    name = server_name(scope, opts)
    environments = environments(scope, opts)

    found =
      for environment <- environments,
          server_name = server_name(scope, opts, environment),
          {:ok, server} <- [Hetzner.find_server(scope, server_name)],
          do: reconcile_environment_server(scope, environment, server_name, server)

    # Satisfied only when EVERY environment has its box **and** the connection
    # string to the database on it.
    #
    # One environment missing a box is not "done" — it is a project that cannot
    # deploy that environment, and reporting done hides it until the deploy
    # fails. `DATABASE_URL` is the same claim about the same step: this step
    # serves the database and writes the URL (`serve_database/4`), so this step
    # is the only one that can notice it has gone.
    #
    # Asking only about the box made that unrecoverable rather than merely
    # broken, which is the shape `verify(:secrets, …)` already documents for
    # `SECRET_KEY_BASE`. The encrypted env is a file in the working tree, so it
    # goes missing the ordinary ways files do — a fresh checkout, a revert, a
    # rotated age key discarding what it can no longer open. Both steps then
    # verified satisfied against boxes that really were there, neither re-wrote
    # anything, and the deploy failed two steps later on "uat is missing
    # DATABASE_URL" — a secret its two predecessors had just certified.
    #
    # This is checked here rather than added to `secrets_ready?/2` deliberately.
    # That step's `run/3` mints keys and `SECRET_KEY_BASE`; it does not know a
    # database exists. Marking it unsatisfied would have run it, produced no
    # `DATABASE_URL`, and left it unsatisfied — a step that reruns forever
    # instead of one that reports done wrongly, which is not an improvement.
    if length(found) == length(environments) and found != [] and
         Enum.all?(environments, &database_url_present?(scope, &1)) do
      # The step also makes a firewall and an ssh_key, shared across
      # environments. A second run takes this satisfied path instead of
      # `run/3`; returning only the servers would drop those two from the
      # step's resources (7965: "running twice leaves one of everything").
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

  def verify(:email, %Scope{} = scope, opts) do
    environments = environments(scope, opts)

    case domain(scope) do
      nil ->
        {:ok, :absent}

      base ->
        # Satisfied only when every environment has a verified sending domain.
        # Reporting done with production verified and UAT missing hides the
        # exact gap that lets a test message go out looking like a real one.
        verify_sending_domains(scope, base, environments)
    end
  end

  def verify(:secrets, %Scope{} = scope, opts) do
    environments = environments(scope, opts)

    # Satisfied only when EVERY environment has a key that still opens its own
    # file. A partially-keyed project is not done — the environment without one
    # cannot be deployed, and reporting done would hide that until the deploy
    # failed.
    #
    # Having a key is not enough, and that is the whole point of asking twice.
    # Half the pair lives in the repository (`.sops.yaml` names the public
    # recipient) and half in the database. Nothing keeps them in step, and git
    # moves tracked files around — a checkout, a revert, a bad merge, or a
    # teammate committing their own `.sops.yaml`. When they drift, sops can
    # still encrypt, because encrypting only needs the recipient; nothing can
    # decrypt.
    #
    # Checking only for presence made that unrecoverable rather than merely
    # broken: `run_step/3` verifies before it executes, so re-running the
    # secrets step — the obvious remedy — found it satisfied and never reached
    # `generate_keys`, which is what would have rewritten `.sops.yaml` from
    # fresh keys. The step read done, the button did nothing, and the failure
    # surfaced two steps away in deploy.
    # And the boot secret this step mints, or the step reports done having
    # produced nothing. A working directory that is fresh while the key is
    # still in the database has no file to disagree with, so the key check
    # alone said satisfied, `run_step/3` skipped `generate_keys`, and the
    # deploy failed two steps later on "uat is missing SECRET_KEY_BASE" — the
    # exact shape this verify already documents for the key itself.
    case Enum.all?(environments, &secrets_ready?(scope, &1)) do
      true ->
        {:ok, :satisfied, Enum.map(environments, &%{kind: "age_key", location: "secrets/#{&1}"})}

      false ->
        {:ok, :absent}
    end
  end

  def verify(:tls, %Scope{} = scope, opts) do
    case host(scope, opts) do
      nil ->
        {:ok, :absent}

      h ->
        # The certificate either works or it does not, and the only honest
        # check is an HTTPS request that would fail on a bad one.
        case Deploy.probe(h, opts) do
          :ok -> {:ok, :satisfied, [%{kind: "certificate", location: "https://#{h}"}]}
          {:error, _} -> {:ok, :absent}
        end
    end
  end

  def verify(:callback_credential, %Scope{} = scope, _opts) do
    case ProjectSecrets.has_value?(scope, "cms_refresh_secret") do
      true -> {:ok, :satisfied, [%{kind: "callback_credential", location: "encrypted_env"}]}
      false -> {:ok, :absent}
    end
  end

  def verify(:inbound, %Scope{} = scope, opts) do
    with name when is_binary(name) <- receiving_domain(scope, opts),
         {:ok, domain} <- Resend.find_domain(scope, name),
         true <- Resend.receiving?(domain),
         {:ok, webhooks} <- Resend.list_webhooks(scope),
         %{"status" => "enabled"} <-
           Enum.find(webhooks, &(&1["endpoint"] == webhook_endpoint(scope, opts))) do
      # Configured is not proven. `run_step/3` marks a step done straight from
      # a satisfied verification without running it, so reporting satisfied on
      # a domain and a webhook meant the step body — the part that sends a
      # message and waits for it to arrive — never ran, and the page showed an
      # inbox called done on settings alone.
      #
      # That is criterion 8033 exactly: "the inbox is proven by a message, not
      # by configuration". The step was written to prove it and the verifier
      # was excusing it from doing so.
      #
      # So a proof a previous run recorded is what satisfies this. Absent one,
      # the step runs and proves it.
      case delivery_proof(scope) do
        nil ->
          {:ok, :absent}

        proof ->
          {:ok, :satisfied,
           [
             %{kind: "receiving_domain", location: "resend/#{name}"},
             %{kind: "webhook", location: webhook_endpoint(scope, opts)},
             proof
           ]}
      end
    else
      # Anything short of "receiving domain plus an ENABLED webhook" is absent.
      # A disabled webhook is the case worth being strict about: it looks
      # configured from every angle except the one that counts.
      _ -> {:ok, :absent}
    end
  end

  def verify(:storage, %Scope{} = scope, opts) do
    environments = environments(scope, opts)
    project = project(scope)

    case Storage.credentials(scope, opts) do
      :none ->
        {:ok, :absent}

      {:ok, credentials} ->
        environments
        |> Enum.map(&Storage.bucket_name(project, &1))
        |> every_bucket_present(credentials, opts)
        |> record_content_bucket(scope, opts)
    end
  end

  # Everything else is either cheap to re-run or has no read-back that
  # distinguishes done from not-done without doing the work.
  def verify(_key, _scope, _opts), do: {:ok, :absent}

  ## Run

  @doc "Execute a step. See the moduledoc for the shape and why it is this one."
  @spec run(atom(), Scope.t(), keyword()) :: outcome()
  def run(:repository, %Scope{} = scope, opts) do
    project = project(scope)

    if is_nil(env(scope)) do
      {:error, no_environment_message()}
    else
      # Adopt only what setup itself already recorded. Criteria 8179 and 8185
      # describe the same situation — a repository at the name setup would use
      # — and want opposite things, so the distinguishing fact has to be
      # whether *we* put it there:
      #
      #   - the project already points at it: this is a re-run finding its own
      #     work, and adopting is what makes a retried step safe (8179);
      #   - the project points nowhere: the repository predates setup, might be
      #     somebody's unrelated work, and Sam chooses (8185).
      #
      # Guessing either way is the bad outcome. Adopting always would let a
      # re-run push into a stranger's repository; prompting always would make
      # every retry stop and ask about a repository setup made a minute ago.
      opts = Keyword.put_new(opts, :adopt, ours?(project, opts))

      scope
      |> Repository.run(env(scope), project, opts)
      |> record_repository(scope)
      |> repository_outcome()
    end
  end

  # Three resources, made in order, and the last one is the one that fails.
  # Each is recorded as soon as it exists rather than all together at the end:
  # a firewall and an SSH key are real the moment Hetzner accepts them, and a
  # failure at `ensure_server` that returned a bare error left both of them
  # unrecorded — existing at the provider with nothing able to find them.
  # Teardown works from what a step recorded, so that leaks by construction.
  def run(:server, %Scope{} = scope, opts) do
    # The firewall and the ssh key are the project's, shared by every
    # environment; the servers are not. Each environment gets its own box, so
    # that "each environment resolves to its own server" is true by
    # construction rather than by convention.
    name = server_name(scope, opts)

    with {:ok, firewall} <- Hetzner.ensure_firewall(scope, name),
         made = [firewall_resource(name, firewall)],
         {:ok, ssh_key} <- made_or_error(ensure_access_key(scope, name), made),
         made = [ssh_key_resource(name, ssh_key) | made],
         opts <-
           opts
           |> Keyword.put(:firewall_ids, [firewall["id"]])
           |> Keyword.put(:ssh_key_ids, [ssh_key["id"]])
           # The Docker app image, for the reason `Builder` gives for the
           # builder: a bare OS pays `apt-get install docker` before it can do
           # its job, and depends on apt mirrors being up to do it. This box
           # runs every kamal container and the registry the deploy pulls
           # from, so it needs Docker from first boot — the first drill to
           # start a registry got `bash: docker: command not found`.
           |> Keyword.put_new(:image, "docker-ce") do
      ensure_environment_servers(scope, opts, made)
    else
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
          # `origin: "adopted"` matters for teardown — a domain setup found is
          # never destroyed. A registered one omits it (reads as created), but
          # a registered domain is not torn down either (registration is not
          # refundable); the mark is what keeps an *adopted* one safe.
          {:ok, :adopted} ->
            {:ok, [%{kind: "domain", location: "cloudflare/#{name}", origin: "adopted"}]}

          {:ok, _body} ->
            {:ok, [%{kind: "domain", location: "cloudflare/#{name}"}]}

          {:paused, instructions} ->
            {:paused, instructions}

          {:error, :confirmation_required} ->
            {:paused, confirmation_message(name)}

          {:error, reason} ->
            {:error, format(reason)}
        end
    end
  end

  def run(:dns, %Scope{} = scope, opts) do
    # Injectable for the same reason `run_step/3` takes `:verify` and
    # `:execute`. The claim worth testing here is *whether the step refuses to
    # move a live apex*, and proving that should not need a real zone.
    with name when is_binary(name) <- domain(scope),
         {:ok, zone} <- find_dns_zone(scope, name, opts),
         environments <- EnvironmentRepository.assign_hosts(scope, name),
         {:ok, resources} <- dns_records_for(scope, zone, environments, opts) do
      record_client_api_url(scope, environments, opts)
      {:ok, resources}
    else
      nil ->
        {:error, "no domain set on the project"}

      # Passed through, not folded into the error branch. A paused step is
      # waiting on a decision and can be resumed; an errored one is broken.
      # Reporting this as an error would make "your apex is live" look like a
      # failure of the run rather than a question for the operator.
      {:paused, message} ->
        {:paused, message}

      {:error, reason} ->
        {:error, format(reason)}
    end
  end

  def run(:email, %Scope{} = scope, opts) do
    environments = environments(scope, opts)

    # `base_domain/2` rather than `domain/1`, so this reads the same value its
    # neighbours do. Reading the project directly meant a caller that narrowed
    # every other step to one domain had this one still working from the
    # project's — two domains in one run, each believing it was the only one.
    case base_domain(scope, opts) do
      nil -> {:error, "no domain set on the project"}
      base -> register_sending_domains(scope, base, environments, opts)
    end
  end

  # Required before the app can boot at all. Checked here rather than
  # discovered on the server, because a missing secret found at boot is a
  # deploy that swapped and then failed — and the message a crashed release
  # gives is not the name of the thing that was missing.
  @required_secrets ~w(SECRET_KEY_BASE DATABASE_URL)

  # Every environment the project has, not one of them.
  #
  # This step took a singular `:environment` defaulting to "uat", and the
  # sequence runs each step once — so a default run deployed UAT, reported
  # `deploy` done, and left production with two boxes, DNS, secrets and an
  # image and nothing serving. The whole run's shell cassette held exactly two
  # invocations, `bin/deploy migrate uat` and `bin/deploy swap uat`. Criterion
  # 1961 is "UAT and prod live"; it went green on the deploy step while half of
  # that was untrue, and the failure surfaced two steps later as TLS being
  # refused by an address nothing was listening on.
  #
  # Every other step in this module already fans out over `environments/2`.
  # A caller naming one environment still gets one, which is what the
  # per-environment criteria (1963's ride-to-UAT, 1964's failing health check)
  # drive.
  def run(:deploy, %Scope{} = scope, opts) do
    case Keyword.fetch(opts, :environment) do
      {:ok, environment} -> deploy_environment(scope, environment, opts)
      :error -> deploy_environments(scope, environments(scope, opts), opts)
    end
  end

  def run(:monitoring, %Scope{} = scope, opts) do
    hosts = Keyword.get(opts, :hosts) || List.wrap(domain(scope))

    # A spex can inject the monitor outcome (host + notify target) without a
    # real UptimeRobot account — the criterion is that a monitor exists per
    # host and has somewhere to shout, not UptimeRobot's API.
    case Keyword.get(opts, :monitors) || Deploy.ensure_monitors(hosts, opts) do
      {:ok, monitors} ->
        {:ok, Enum.map(monitors, &%{kind: "monitor", location: &1["friendly_name"] || "monitor"})}

      monitors when is_list(monitors) ->
        {:ok,
         Enum.map(monitors, fn m ->
           %{kind: "monitor", location: m.host, identifier: "notify=#{m.notify}"}
         end)}

      {:error, :no_notification_target} ->
        {:paused,
         "Add a notification target before installing monitors — a monitor nobody hears is not monitoring."}

      {:error, reason} ->
        {:error, format(reason)}
    end
  end

  def run(:content, %Scope{} = scope, opts) do
    # `ContentPublishing.run/2` already computes everything story 972 asks
    # about — which objects landed in whose bucket, what the live site returned
    # for the post's path, when it was proven. Collapsing all of it to
    # `%{kind: "content", location: "published and rendered"}` meant the page
    # had nothing to show and the criteria had nothing to read, which is why
    # every one of them selected on markup that could not exist.
    #
    # Shaped like `inbound_proof` and `restore_proof`: the claim in `kind`, the
    # thing it is about in `location`, and the evidence in `identifier`.
    case ContentPublishing.run(scope, opts) do
      %{state: :rendered} = result ->
        {:ok, [content_proof(result) | content_objects(result)]}

      %{state: state, published: published, reason: reason} ->
        # A publish that uploaded and then failed to render is not the same as
        # one that never uploaded, and 8058 turns on the difference. The
        # objects are kept so the page can say the files are there while the
        # post is not being served.
        {:error, reason,
         [content_failure(state, reason, published) | content_objects(%{published: published})]}
    end
  end

  def run(:widget, %Scope{} = scope, opts) do
    # `Widget.run/3` requires both and says so with `fetch!`, which is the
    # right contract for a module that cannot do anything useful without them.
    # Supplying them is this adapter's job — letting the KeyError escape turns
    # a missing domain into a crashed run instead of one errored step.
    project = project(scope)

    with {:ok, site} <- require_value(Keyword.get(opts, :site_url) || site_url(scope), "a domain"),
         {:ok, key} <-
           require_value(
             Keyword.get(opts, :deploy_key) || Map.get(project, :deploy_key),
             "a deploy key"
           ) do
      opts =
        opts
        |> Keyword.put(:site_url, site)
        |> Keyword.put(:deploy_key, key)
        # `Widget.message_proof/2` reads this with `fetch!` — correctly, since
        # it can prove nothing without it — and nothing supplied it, so the
        # first run that got past install and presence would have died on a
        # KeyError rather than reporting an unproven widget.
        |> Keyword.put_new(:lookup, &widget_messages(&1, site))

      # Same as the content step: `Widget.run/3` computes the render check and
      # the message proof — status, present, openable, origin, when — and all
      # of it was being discarded into one opaque resource, so story 973's
      # criteria selected on markup that had no source.
      case Widget.run(scope, env(scope), opts) do
        %{state: :proven} = result ->
          {:ok, Enum.reject([widget_render(result), widget_proof(result)], &is_nil/1)}

        %{reason: reason} = result ->
          {:error, reason, Enum.reject([widget_render(result)], &is_nil/1)}
      end
    end
  end

  def run(:secrets, %Scope{} = scope, opts) do
    environments = environments(scope, opts)
    env = env(scope)

    case Sops.available?() do
      false ->
        {:paused,
         "sops and age are not installed on this machine. Install them " <>
           "(brew install sops age), then resume — setup cannot encrypt secrets without them."}

      true ->
        generate_keys(scope, env, environments)
    end
  end

  def run(:tls, %Scope{} = scope, opts) do
    # Issuance is kamal-proxy's job during deploy; this step verifies it
    # actually happened. A certificate nobody checked is a certificate that
    # fails on a visitor rather than during setup. The probe is injectable so a
    # spex can verify the recording without a live host.
    probe = Keyword.get(opts, :probe, &Deploy.probe/2)

    case tls_targets(scope, opts) do
      [] -> {:error, "no domain set on the project — nothing to issue a certificate for"}
      targets -> verify_certificates(scope, targets, probe, opts)
    end
  end

  def run(:callback_credential, %Scope{} = scope, opts) do
    environments = environments(scope, opts)
    env = env(scope)
    secret = Keyword.get(opts, :secret) || random_secret()

    # Story 971: the credential lands in the encrypted env, not in a plaintext
    # config and not by hand. Sops.put_secret writes ciphertext in place, so
    # the plaintext never reaches the working tree.
    environments
    |> Enum.reduce_while(:ok, fn environment, _acc ->
      # `ensure_age_key` mints the key if the secrets step has not run yet,
      # rather than failing — same as `put_secret`. The credential lands in
      # the encrypted env regardless of step order.
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

        # And register its digest, or the secret we just wrote into the app's
        # environment can never be exchanged for anything — issued and not
        # redeemable, which is what this step looked like before /api/token
        # existed.
        CodeMySpec.AppTokens.put_refresh_secret(project(scope), secret)

        {:ok,
         Enum.map(environments, fn e ->
           # `placed_in` and `manual` are the observable form of "Sam never
           # sees the credential he is using" (8022): setup wrote it into the
           # encrypted env, and Sam copied nothing between systems.
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
         # Before any provider call. An address on another domain can never
         # prove this one's inbox, so the run cannot succeed — and the rule the
         # deploy step states applies here too: something that cannot succeed
         # does not first go and change the provider.
         #
         # A missing address is deliberately *not* checked here. The records
         # are needed either way and MX propagation is the slow part, so that
         # case publishes first and pauses afterwards.
         :ok <- probe_address_on_domain(name, opts),
         {:ok, domain} <- Resend.ensure_receiving_domain(scope, name, opts),
         {:ok, webhook} <- Resend.ensure_webhook(scope, endpoint, opts),
         {:ok, mx} <- publish_mx(scope, name, domain, opts),
         # The inbound records, not the domain. Mail addressed to a name Resend
         # has not checked yet is not accepted, so probing straight after
         # publishing produced a message that went nowhere — indistinguishable
         # from a broken inbox.
         #
         # Waiting on the domain as a whole was worse than not waiting: a
         # receiving-only domain reports `pending` forever, because its sending
         # records belong to story 969 and this step must leave them alone
         # (criterion 8029). Observed against a real run — apex `MX c8033`
         # verified while the domain sat pending on three records nobody here
         # had published.
         {:ok, _inbound} <- Resend.await_inbound_verified(scope, domain["id"], name, opts),
         {:ok, proof} <- prove_delivery(scope, name, opts) do
      {:ok,
       [
         %{kind: "receiving_domain", location: "resend/#{name}"},
         %{kind: "webhook", location: endpoint, identifier: webhook["id"]}
       ] ++ mx ++ [proof]}
    else
      nil ->
        {:error, "no domain set on the project — nothing to receive mail at"}

      {:error, {:receiving_disabled, name}} ->
        {:paused,
         "#{name} exists in Resend with receiving disabled, and Resend only accepts " <>
           "capabilities when a domain is created — there is no API to turn it on. " <>
           "Enable receiving for #{name} in the Resend dashboard, then resume. " <>
           "Setup will not delete and recreate the domain: that rotates its DKIM key " <>
           "and would break sending until DNS caught up."}

      # Paused, not errored. Nothing is wrong with the inbound setup; there is
      # simply nothing to send the probe from, and that is somebody's decision
      # to make rather than a failure to retry.
      {:error, :no_verified_sender} ->
        {:paused,
         "the inbound records are published, but proving delivery means sending a message to " <>
           "this domain and the account has no verified sending domain to send it from. " <>
           "Verify one — the email step does this — then resume."}

      # Paused rather than errored: nothing is broken, setup just does not know
      # where to send. Resend accepts mail only at addresses configured for the
      # domain and offers no API to list them, so this is Sam's to answer.
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

      {:error, :never_arrived} ->
        {:error,
         "the records are published and Resend is configured, but the message sent to this " <>
           "domain never arrived. Check first that the address it was sent to is configured " <>
           "to receive in Resend — an address the domain does not accept is dropped in " <>
           "silence and looks exactly like this. Otherwise: configuration that looks right " <>
           "is how a receiving setup fails, because the MX, Resend's receiving capability " <>
           "and the webhook all have to be right together and each can look correct alone."}

      {:error, reason} ->
        {:error, format(reason)}
    end
  end

  def run(:storage, %Scope{} = scope, opts) do
    environments = environments(scope, opts)
    project = project(scope)

    case Storage.credentials(scope, opts) do
      :none ->
        # Hetzner issues object-storage keys in the console and nowhere else,
        # so there is no call to make here. Pausing states the real limit and
        # re-checks on resume rather than pretending it can be automated.
        {:paused, Storage.credentials_instructions()}

      {:ok, credentials} ->
        environments
        |> Enum.reduce_while({:ok, []}, &ensure_bucket_for(&1, &2, project, credentials, opts))
        |> record_content_bucket(scope, opts)
    end
  end

  # Every environment, the way `run(:storage, ...)` immediately above already
  # does it. This used to read `Keyword.get(opts, :environment, "prod")` — one
  # environment, defaulted — while the step beside it created a bucket per
  # environment.
  #
  # The visible failure was the lucky one: a project with only `uat` looked for
  # a `-prod` bucket nothing had made and errored on NoSuchBucket. The
  # dangerous case is an ordinary prod+uat project, where the default finds a
  # real bucket and the step reports **done** having dumped production only.
  # UAT's database is never written anywhere and nothing says so, which is
  # discovered on the day somebody needs a restore.
  #
  # Same shape as the TLS default fixed in 69ca7625: a per-environment fact
  # served by a project-level default.
  def run(:backups, %Scope{} = scope, opts) do
    environments = environments(scope, opts)
    project = project(scope)

    case Storage.credentials(scope, opts) do
      :none ->
        {:paused, Storage.credentials_instructions()}

      {:ok, credentials} ->
        environments
        |> Enum.reduce_while({:ok, []}, fn environment, {:ok, acc} ->
          bucket = Storage.bucket_name(project, environment)

          # The key travels with the work, the way the deploy step carries it.
          # `bin/backup` decrypts the environment file itself and sops reads
          # its identity from `SOPS_AGE_KEY` — without it every dump failed on
          # "no identity matched any of the recipients", which reads like a
          # broken key rather than one that was never handed over.
          environment_opts =
            opts
            |> Keyword.put(:bucket, bucket)
            |> Keyword.put(:credentials, credentials)
            |> put_age_key(scope, environment)

          with :ok <- require_script(scope, "bin/backup"),
               {:ok, resources} <-
                 backups_outcome(
                   Backups.run(env(scope), environment, environment_opts),
                   bucket,
                   environment
                 ) do
            {:cont, {:ok, acc ++ resources}}
          else
            # What was already dumped is named in the failure, so a run that
            # dies on the second environment still accounts for the first.
            # No `:paused` clause: neither `require_script/2` nor
            # `backups_outcome/3` can pause, so one here only looked like
            # backups could stop for input.
            {:error, reason} -> {:halt, {:error, reason, acc}}
          end
        end)
    end
  end

  # Named rather than silently succeeding — see the moduledoc.
  def run(key, _scope, _opts), do: {:error, {:not_implemented, key}}

  ## Client-facing configuration
  #
  # Three fields on the project — `content_bucket`, `client_api_url` and
  # `deploy_key` — that the content and widget steps refuse without, and that
  # nothing in the sequence used to write. They were left to somebody typing
  # into the content settings form, so a project that had never opened it could
  # not finish setup: `content` reported "Publishing is not configured" and
  # `widget` reported "needs a deploy key, and this project has none set".
  #
  # Since a project that has never chosen options gets *every* option, that was
  # the default plan — and criterion 1961 asserts the default plan finishes.
  # None of the three is a decision anybody makes; setup already knows all of
  # them by the time they are read. `deploy_key` is minted at the secrets step
  # (`seed_deploy_key/3`), which has to be before the deploy that carries it.

  # The bucket the content step publishes into, recorded by the step that owns
  # it. `content` ran two positions later and failed for want of a name this
  # step already had.
  #
  # On both paths, which is the whole point. A bucket that already exists takes
  # the satisfied branch of `verify/3` and never reaches `run/3`, so recording
  # it only there meant the very first walk wrote the name and every walk after
  # it — the ones with the infrastructure already standing — did not. The name
  # is derived from the project and the environment, so it is equally knowable
  # whichever branch got here.
  #
  # Only when unset: a project that names a bucket of its own has chosen it, and
  # a re-run must not point publishing somewhere else.
  defp record_content_bucket({:ok, :satisfied, _resources} = outcome, scope, opts) do
    write_content_bucket(scope, opts)
    outcome
  end

  defp record_content_bucket({:ok, _resources} = outcome, scope, opts) do
    write_content_bucket(scope, opts)
    outcome
  end

  defp record_content_bucket(other, _scope, _opts), do: other

  # The bucket, and where it is.
  #
  # `s3_endpoint` and `aws_region` travel with it because publishing signs a
  # request against a host, and ExAws with no endpoint configured defaults to
  # Amazon — `ContentPublishing.client_config/1` says so outright. So a project
  # whose bucket this step had just created on Hetzner published to AWS and got
  # `NoSuchBucket` for a bucket that existed, with `server: AmazonS3` in the
  # response as the only clue that it had gone to the wrong provider entirely.
  #
  # Written together, never separately: a bucket name pointed at the wrong
  # endpoint is worse than no bucket name, because the failure names the bucket
  # rather than the host.
  defp write_content_bucket(scope, opts) do
    project = project(scope)
    location = Keyword.get(opts, :location, "fsn1")

    with true <- blank?(Map.get(project, :content_bucket)),
         environment when is_binary(environment) <- primary_environment(scope, opts) do
      Projects.update_project(scope, project, %{
        content_bucket: Storage.bucket_name(project, environment),
        s3_endpoint: "https://#{location}.your-objectstorage.com",
        aws_region: location
      })
    end

    :ok
  end

  # The address the content step fetches a published post back from, written as
  # the hosts are decided.
  #
  # At the DNS step rather than the deploy, because the URL is a fact about the
  # name and this is the step that assigns names. Nothing serves it yet at
  # position five; the content step that reads it runs at twelve, six after the
  # deploy.
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

  # The environment the project's client-facing configuration describes.
  #
  # `content_bucket` and `client_api_url` are single fields while buckets and
  # hosts are per-environment, so both have to name the *same* environment —
  # otherwise the content step proves a render on one site against objects in
  # another site's bucket, and its two distinguishable failures stop being
  # distinguishable.
  #
  # Production when there is one, because that is the site a reader visits.
  # Otherwise the first environment the project has, so a UAT-only project gets
  # a working pair rather than a pair of nils.
  defp primary_environment(scope, opts) do
    environments = environments(scope, opts)

    if "prod" in environments, do: "prod", else: List.first(environments)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # The image a deploy runs, built now rather than when the project was made.
  #
  # Three ways in, and the order matters. An explicit `:image` wins, because a
  # criterion about deploying is not a criterion about building and should not
  # buy a builder to prove its point. Otherwise a build happens — but only when
  # one is configured: the deploy step predates the builder, and a project
  # whose image is already somewhere must keep deploying rather than start
  # failing on a builder nobody asked it to use.
  # Whether the stored private key is the one the environment's file was
  # encrypted to. Derived rather than trusted: the public half is the only
  # thing the file records, so the question is whether what we hold produces
  # it.
  #
  # A file that does not exist yet is not drift — there is nothing to be out of
  # step with — so the key's presence is the answer in that case, which keeps a
  # first run from reporting absent forever.
  # Every secret this step is responsible for minting, not just the key that
  # encrypts them. `DEPLOY_KEY` joins `SECRET_KEY_BASE` for the reason that
  # comment already gives: `run_step/3` verifies before it executes, so a step
  # that reports satisfied never reaches the code that would put the missing
  # value back, and the failure surfaces somewhere else entirely.
  defp secrets_ready?(scope, environment) do
    key_opens_its_own_file?(scope, environment) and
      match?({:ok, false}, secret_key_base_missing?(scope, env(scope), environment)) and
      not deploy_key_missing?(scope, environment)
  end

  # Absent only when the file opens and the value is not in it. Anything this
  # cannot read — no age key, no sops — is somebody else's error to report, and
  # `key_opens_its_own_file?/2` above reports it in its own words.
  defp deploy_key_missing?(scope, environment) do
    with {:ok, private} <- fetch_age_key(scope, environment),
         {:ok, missing} <- Sops.missing_secrets(env(scope), environment, private, ["DEPLOY_KEY"]) do
      "DEPLOY_KEY" in missing
    else
      _ -> false
    end
  end

  defp key_opens_its_own_file?(scope, environment) do
    with {:ok, private} <- ProjectSecrets.fetch_value(scope, age_key_name(environment)),
         true <- is_binary(private) and private != "" do
      case Sops.recipients(env(scope), environment) do
        {:ok, [_ | _] = recipients} ->
          case Sops.public_key(private) do
            {:ok, public} -> public in recipients
            _ -> false
          end

        # No file, or none we can read a recipient out of. Nothing to disagree
        # with; the key being there is all this can honestly claim.
        _ ->
          true
      end
    else
      _ -> false
    end
  end

  # The delivery this step last proved, if it proved one. Read from what the
  # step recorded rather than re-sent — a verifier that mails somebody every
  # time the page loads would be its own bug.
  defp delivery_proof(scope) do
    case StepRepository.get(scope, :inbound) do
      %{resources: resources} when is_list(resources) ->
        Enum.find(resources, &(&1.kind == "inbound_proof"))

      _ ->
        nil
    end
  end

  # One target per environment, because a certificate belongs to a host and the
  # DNS step directly above already fans out this way. Verifying the project's
  # domain instead meant a `uat`-only project was probed at an apex the run had
  # never pointed anywhere — and, worse, that the usual prod+uat pair reported
  # TLS done having checked production only, so UAT's certificate was never
  # looked at.
  #
  # An injected `:host` still stands in for the whole list, which is how a
  # criterion probes one name without setting up environments.
  defp tls_targets(scope, opts) do
    case Keyword.get(opts, :host) do
      host when is_binary(host) and host != "" ->
        [%{name: nil, host: host}]

      _ ->
        case domain(scope) do
          nil ->
            []

          name ->
            scope
            |> EnvironmentRepository.assign_hosts(name)
            |> Enum.filter(&is_binary(&1.host))
        end
    end
  end

  # Halts on the first environment without a certificate, carrying what was
  # already verified — the same shape the storage step uses, so a run that
  # fails on the second environment still records the first.
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

  # Issuance is asynchronous. kamal-proxy asks Let's Encrypt for a certificate
  # when the service comes up, and the handshake stalls until it arrives, so
  # the honest reading of a single timed-out probe is "not yet" rather than
  # "never". This step used to make exactly one 10-second attempt and was the
  # only asynchronous thing in provisioning that did not poll — every sibling
  # here waits for the world to catch up, and the deploy step polls this very
  # probe thirty times.
  defp await_certificate(probe, host, opts, attempts) do
    case probe.(host, opts) do
      :ok ->
        :ok

      {:error, _reason} when attempts > 1 ->
        Wait.sleep(Keyword.get(opts, :tls_interval_ms, 5_000))
        await_certificate(probe, host, opts, attempts - 1)

      # The last reason, not a bare "gave up" — what the host was doing on the
      # final attempt is the whole diagnosis.
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tls_attempts(opts), do: Keyword.get(opts, :tls_attempts, 20)

  # A successful probe is a 200 over HTTPS with `redirect: false` and a valid
  # chain — so scheme, status and cert validity are all implied by it
  # succeeding, and recorded so the page can show them (8006).
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

  # The advice names two prerequisites — DNS and port 80 — and every drill so
  # far had to guess which one was missing, from a host that teardown had
  # already destroyed. So ask, once, while the host still exists: a proxy that
  # answers on 80 but not on 443 has failed *issuance*, which is a different
  # problem from a proxy nothing can reach, and the sentence should not make a
  # human run a drill to tell them apart.
  defp certificate_error(scope, target, reason, probe, opts) do
    "#{target.host} did not answer over HTTPS with a valid certificate (#{format(reason)}). " <>
      "Issuance needs DNS resolving to the server and the proxy reachable on 80. " <>
      plain_http_observation(target.host, probe, opts) <>
      " " <> acme_path_observation(target.host, probe, opts) <>
      " " <> dns_observation(target.host, reason, opts) <>
      " " <> proxy_log_observation(scope, target, opts)
  end

  # The evidence this message has been asking for since it was written.
  #
  # "Check the proxy's certificate log on the host" names something nobody can
  # do: teardown destroys the box minutes after the step fails, and six drills
  # reported this without anyone ever seeing why issuance did not complete.
  # Every check that can be made from outside now passes — DNS resolves, port
  # 80 answers, the challenge path is served — and 443 still times out, so
  # what is left is only visible from inside.
  #
  # Read while the host still exists, and folded into the failure rather than
  # left for a human to go and fetch. Injectable so a test can drive it, and
  # the whole thing is best-effort: this is diagnosis, and a diagnosis that can
  # fail the step it is explaining would be worse than no diagnosis.
  defp proxy_log_observation(scope, target, opts) do
    reader = Keyword.get(opts, :proxy_log, &read_proxy_log/3)

    case Map.get(target, :ip) do
      ip when is_binary(ip) and ip != "" -> reader.(scope, ip, opts)
      _ -> "No address is recorded for this environment, so its proxy log could not be read."
    end
  end

  # The log says what happened; `kamal-proxy list` says what the proxy believes
  # its state to be, which is the question drill 47 left open — it deployed
  # with tls true and then never ordered a certificate, and a log cannot
  # distinguish "tried and failed silently" from "never considered it".
  #
  # `|| true` on the state command so a proxy without that subcommand still
  # yields its log rather than an empty capture.
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

  # Compress every line rather than selecting some.
  #
  # Three times now this capture has hidden the thing it was fetching. First a
  # `tail` in the shell, then eight lines sliced at 1200 characters, then a
  # keyword filter that dropped "Server started" and left absence to be
  # inferred from a view that had already thrown lines away. Each was tuned for
  # what I expected to find, which is exactly the wrong instinct when the
  # finding is that something never happened.
  #
  # kamal-proxy logs one JSON object per line and most of it is ballast —
  # request ids, content types, durations. Keeping five fields turns a
  # 600-character line into about eighty, so the whole sequence fits and
  # nothing has to be chosen between.
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

  # Whether HTTP-01 can even complete, asked of the one path it uses.
  #
  # A proxy with `ssl: true` redirects http to https, and the challenge path is
  # the exception it has to make — Let's Encrypt fetches
  # `/.well-known/acme-challenge/<token>` over port 80, and a proxy that
  # redirects that to a host with no certificate yet has made issuance
  # impossible by trying to be secure. An unknown token answering 404 is the
  # healthy shape: the proxy served it rather than bouncing it.
  #
  # No SSH, so this costs one HTTP request and works from here. The message it
  # replaces told the reader to go and read the proxy's certificate log on a
  # host that teardown destroys minutes later, which nobody has ever been able
  # to do.
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

  # Which resolver disagreed, because two of them are in play and they can
  # answer differently for the same name. The dns step above verifies over
  # DNS-over-HTTPS; this step's probe goes through the system resolver. A
  # recursive resolver caches the *absence* of a name (see `Dns`), so a drill
  # started inside that negative TTL reads `nxdomain` for a record the dns step
  # just watched appear — which is a stale cache on this machine, not a
  # deployment that failed, and the two deserve different sentences.
  defp dns_observation(host, reason, opts) do
    resolves? = Dns.resolves_publicly?(host, :a, Keyword.put(opts, :attempts, 1))
    dns_sentence(resolves?, resolution_failure?(reason))
  end

  # Only a failure that named resolution says anything about a resolver. A
  # timeout means the name resolved and the host did not answer, so blaming a
  # stale cache there invents a second fault to explain the first — which this
  # sentence did on drill 45, asserting the local resolver was stale in a run
  # whose probe never failed to resolve anything.
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

  # Two independent resolvers, because one is not a public opinion.
  #
  # This said "so the record is missing" on the strength of a single answer from
  # `dns.google`, on a run where the record was published and `1.1.1.1` returned
  # it — Google was holding a negative answer cached from before it was written.
  # `Dns.doh_lookup/3` now asks Cloudflare too when Google has nothing, so a
  # silence from both is worth something; propagation still explains it, and
  # this no longer decides which it was.
  defp dns_sentence(false, _resolution_failure?) do
    "Neither public resolver returns an A record for it, so the record is " <>
      "missing or was written too recently to have propagated."
  end

  defp plain_http_observation(host, probe, opts) do
    # Any HTTP status counts as answering, including the ones `probe/2` reports
    # as errors. It is a health check, so it calls a 301 a failure — and a 301
    # is exactly what a healthy kamal-proxy serves on 80 while it redirects to
    # HTTPS. Reading that as silence made this sentence contradict itself:
    # "Port 80 does not answer either (responded 301)", which sent a drill
    # looking at reachability when the proxy was plainly up and issuance was
    # the thing that had failed.
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

  # Send one, and wait for it to come back. Every other step in this epic
  # proves itself against the world rather than against its own settings —
  # backups restore into a scratch database and count the rows, tls makes an
  # HTTPS request a bad certificate would fail, the sending step polls until
  # Resend itself reports verified. Inbound was the one that accepted its own
  # configuration as evidence.
  #
  # Read back from Resend rather than from the webhook. The webhook posts to
  # the project's own domain, which may serve something unrelated or nothing at
  # all, so waiting on it would make this step depend on the customer having
  # deployed — and would report failure for a site that is merely not up yet.
  # `GET /emails/receiving` is the same delivery, seen from a place that does
  # not need anything deployed.
  defp prove_delivery(scope, name, opts) do
    probe = Keyword.get(opts, :inbound_probe, &default_inbound_probe/3)
    probe.(scope, name, opts)
  end

  defp default_inbound_probe(scope, name, opts) do
    # A token in the subject, because the account receives real mail too and
    # "something arrived" is not "the thing we sent arrived".
    token = "cms-inbound-#{System.unique_integer([:positive])}"

    # The address is given, never invented. Resend delivers only to addresses
    # configured for the domain, and exposes no API to ask which those are, so
    # a made-up local part is dropped in silence.
    #
    # `setup-probe@` was hardcoded here and cost most of a day: mail to
    # `john@astralbi.com` arrived, mail to `setup-probe@astralbi.com` never
    # did, and the step reported the inbox broken. A novel local part *did*
    # arrive on another domain, which sent me chasing Resend outages and our
    # own webhook — that domain simply had a catch-all. One sample generalised
    # into the wrong theory while the right one sat discarded.
    #
    # Pausing for an address Sam already receives at is the honest move: setup
    # cannot discover it, and guessing produces a failure that blames the
    # inbox for the guess.
    case Keyword.get(opts, :inbound_probe_to) || owner_address(scope, name) do
      to when is_binary(to) and to != "" ->
        with {:ok, message} <- send_and_await(scope, to, token, opts) do
          {:ok, inbound_proof(to, message)}
        end

      _ ->
        {:error, :no_probe_address}
    end
  end

  # Sam's own local part at this domain. Derived rather than invented, which is
  # the distinction that matters: `setup-probe@` was a name nobody had
  # configured, and Resend drops mail to an unconfigured address in silence, so
  # the step reported the inbox broken. The address Sam reads his own mail at
  # is the one he is most likely to have set up, and he can override it.
  #
  # Still a guess, so when it does not arrive the error says to check the
  # address first — that being the likeliest cause and the one that reads as a
  # broken inbox.
  defp owner_address(%Scope{user: %{email: email}}, domain)
       when is_binary(email) and is_binary(domain) do
    case String.split(email, "@") do
      [local | _] when local != "" -> "#{local}@#{domain}"
      _ -> nil
    end
  end

  defp owner_address(_scope, _domain), do: nil

  # On *this* domain, or the proof is about somebody else's inbox: a message to
  # an address elsewhere arrives just as happily and says nothing about whether
  # mail to this domain lands.
  #
  # Anchored on `@` rather than a bare suffix, or `john@evil-<domain>` would
  # pass — a different domain that merely ends with ours.
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

  The same proof the inbound step performs, exposed so the page can run it on
  demand. Public because "does this inbox still work" is a question worth
  asking after setup has said done — a domain that stops receiving looks
  exactly like one that never did until somebody sends to it.

  Returns the received message rather than a boolean, so the caller can report
  where it landed.
  """
  @spec probe_inbound(Scope.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def probe_inbound(%Scope{} = scope, to, opts \\ []) do
    token = "cms-inbound-#{System.unique_integer([:positive])}"

    with {:ok, message} <- send_and_await(scope, to, token, opts) do
      # Read the message itself, not the listing. `/emails/receiving` carries
      # metadata only, so a caller asking "can the app act on this" off the
      # list sees an empty body and concludes no — when the body was simply
      # never sent. Falls back to the listing if the single read fails, since
      # arrival is still the primary claim.
      case Resend.get_received(scope, message["id"]) do
        {:ok, full} when is_map(full) -> {:ok, Map.merge(message, full)}
        _ -> {:ok, message}
      end
    end
  end

  defp send_and_await(scope, to, token, opts) do
    # From a domain the account has already verified, whichever one that is.
    #
    # Not from the domain being set up: it is verified for *receiving* at this
    # point and not for sending, so an inbox's proof would have depended on
    # outbound configuration and failed with a 403 that says nothing about
    # receiving. Not from `onboarding@resend.dev` either, which was my first
    # attempt — Resend answers that with "You can only send testing emails to
    # your own email address", because it is a testing sender rather than a
    # usable one.
    #
    # Any verified domain works. The claim is that mail addressed to this
    # domain arrives here; who sent it is not part of it.
    # What was already in the mailbox before this probe. The arriving message
    # is then identified by *not being one of them*, rather than by carrying a
    # token — and that is what makes the proof replayable.
    #
    # The token is generated per run (`System.unique_integer/1`), so on replay
    # it never matched the subject recorded against it: the poll ran to its
    # limit, exhausted sixty recorded interactions, and every criterion in
    # story 974 recorded green and replayed red. Matching the subject prefix
    # instead would replay, but would also let a *previous* probe to the same
    # address satisfy a later one — proof by residue, which is the failure this
    # step exists to prevent.
    #
    # Ids are stable across record and replay because they come from the
    # cassette, so this is exact in both.
    seen = already_received(scope, opts)

    with {:ok, from} <- probe_sender(scope),
         {:ok, _sent} <- Resend.send_probe(scope, to, subject: token, from: from) do
      Resend.await_received(scope, &received?(&1, to, seen), probe_wait(opts))
    end
  end

  # One read, after a settle. Inbound mail takes tens of seconds to route on a
  # freshly published MX, and polling for it issued a number of requests that
  # depended on how long it took — which a sequentially matched cassette cannot
  # replay. Waiting first and reading once is the same total patience with a
  # fixed request count.
  #
  # Overridable, because a caller that already knows the mail has landed should
  # not wait a minute to be told so.
  @probe_settle_ms 60_000

  # Settle, then poll normally. Capping at a single read made recording fail
  # whenever a minute was not enough, and it was not needed: with the arriving
  # message identified by id rather than by a per-run token, the poll stops on
  # the same response when recording and when replaying, so the request counts
  # already agree. The settle just means there are usually fewer of them.
  defp probe_wait(opts), do: Keyword.put_new(opts, :settle_ms, @probe_settle_ms)

  defp already_received(scope, opts) do
    case Resend.list_received(scope, opts) do
      {:ok, messages} -> MapSet.new(messages, & &1["id"])
      _ -> MapSet.new()
    end
  end

  # The message, turned into what the step records. Kept apart from the send so
  # `probe_inbound/3` can hand the caller the message itself — the page needs
  # where it landed, not a formatted string it would have to parse back.
  defp inbound_proof(to, message) do
    %{
      kind: "inbound_proof",
      location: to,
      identifier: "state=delivered message_id=#{message["id"]} proven_at=#{message["created_at"]}"
    }
  end

  # A verified sender on the account, or a clear reason there is none.
  defp probe_sender(scope) do
    case Resend.list_domains(scope) do
      {:ok, domains} ->
        verified = Enum.filter(domains, &(&1["status"] == "verified"))

        # Any verified domain can carry the probe, so prefer one that is not
        # the product's own. Sending as `codemyspec.com` works and changes
        # nothing, but a setup probe should not go out over the production
        # sending domain when another is available.
        preferred =
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

  # Addressed to us, and not one of the messages that were already here. The
  # second half is what makes this exact without depending on a value that
  # changes between recording and replay.
  defp received?(message, to, %MapSet{} = seen) do
    recipients = List.wrap(message["to"]) |> Enum.map(&to_string/1)

    Enum.any?(recipients, &(&1 == to)) and not MapSet.member?(seen, message["id"])
  end

  # What went out, so "the running version is traceable to the commit CI
  # built" (criterion 8005) has something to compare against later.
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

  # Building makes a box, and `create_server/3` refuses to make one with no key
  # attached — rightly, since nobody could then log in to run the build. The
  # server step resolves the same key and passes it; deploy did not, so a build
  # triggered from the setup page died on `ssh_key_required` while the identical
  # call from the server step succeeded.
  #
  # The key is the account's, already minted by then, so this is a lookup rather
  # than a second source of keys. An explicitly-passed `:ssh_key_ids` wins — a
  # spex injecting a builder should not be made to buy a real key.
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

  # Building is the default, because setup has just provisioned a registry and
  # a builder for exactly this and `bin/deploy` is written expecting it: given
  # no `CMS_IMAGE` it falls through to the CI path, pushes, and fails with
  # "could not find a CI run for main". Every drill ended there, and 8039 had
  # to set `build: true` through application env to get a site at all.
  #
  # `build: false` still opts out, for a caller that means to deploy an image
  # someone else published.
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

  # Helpers for the steps above. Kept together below the `run/3` clauses
  # rather than beside the one each serves: interleaving them splits the
  # clauses, and Elixir warns about that — a warning the analyzer treats as
  # reason to skip exunit, credo and spex outright.

  # The address the registry answers to, and the network that makes it mean the
  # same thing on two machines.
  #
  # The builder pushes and the app's box pulls, and an image reference is baked
  # into the image — so one string has to be correct in both places. A private
  # address is: it is the app box's own, and the builder joins the same network
  # to reach it. Loopback was only ever true on one of the two.
  #
  # An explicit `:registry_host` wins, so a criterion about what gets built
  # does not have to buy a network to say so.
  defp with_private_network(scope, environment, opts) do
    case Keyword.get(opts, :registry_host) do
      host when is_binary(host) and host != "" -> {:ok, opts}
      _ -> attach_private_network(scope, environment, opts)
    end
  end

  defp attach_private_network(scope, environment, opts) do
    name = server_name(scope, opts)
    box = server_name(scope, opts, environment)

    # Found, not created. The server step owns this network now — a build is
    # not what a network's lifetime should be tied to, and creating one here
    # is why a failed build used to leave one behind.
    with {:ok, network} <- find_baseline_network(scope, name),
         {:ok, server} <- Hetzner.find_server(scope, box),
         # Attached here as well, because a box added after the baseline ran
         # would otherwise never join. `attach_to_network/3` treats an existing
         # attachment as success.
         {:ok, _attached} <- Hetzner.attach_to_network(scope, server["id"], network["id"]),
         # Re-read, because the attach does not report the address it assigned
         # and the copy we already hold predates it.
         {:ok, joined} <- Hetzner.find_server(scope, box),
         # Top level, not under `datacenter`. Read the wrong way it is always
         # nil, and every caller quietly falls back to its default — which is
         # how a fix for a zone mismatch changed nothing at all.
         location <- get_in(joined, ["location", "name"]),
         {:ok, ip} <- Hetzner.private_ip(joined, network["id"]) do
      {:ok,
       opts
       |> Keyword.put(:network_ids, [network["id"]])
       # `:builder_location`, not `:location`. This opts list is threaded to
       # `Storage` and `Registry`, where `:location` already means the
       # object-storage region — so setting it here sent S3 requests to
       # `ash.your-objectstorage.com` and signing blew up inside the crypto NIF
       # with `{:badarg, ~c"mac.c", ~c"Bad text"}`, which names nothing.
       #
       # Exactly the trap `:build` set earlier: one key, two meanings, in a bag
       # that gets passed through everything.
       |> Keyword.put(:builder_location, location)
       |> Keyword.put(:registry_bind, ip)
       |> Keyword.put(:registry_host, "#{ip}:#{Registry.port()}")
       |> Keyword.put(:network_resource, network_resource(name, network))}
    else
      # Named, because every one of these is a lookup and `:not_found` on its
      # own reads as "not found" — a whole step's failure rendered as two words
      # that say neither what was missing nor which environment wanted it.
      {:error, :not_found} ->
        {:error,
         "cannot build for #{environment}: no server named #{box}, and no private network " <>
           "named #{name} to reach a registry on"}

      {:error, reason} ->
        {:error, "cannot build for #{environment} on #{box}: #{format(reason)}"}
    end
  end

  # What `Builder.Remote.ssh_runner/2` needs to reach the box it just made:
  # somewhere to run `ssh`, and a private key on disk to run it with.
  #
  # Neither was ever supplied. `ssh_runner/2` fetches both with `fetch!`, so
  # the first drill to reach a real build died on
  # `key :env not found in: [architecture: :x86, reference: ...]` — proof that
  # nothing had run this path before, since any real build would have hit it.
  #
  # The key is written out under 0600 for the length of the build and removed
  # afterwards. It lives in `AccountSecrets` rather than on disk precisely so
  # it is not lying around, and `ssh` will refuse a key the whole machine can
  # read.
  defp with_builder_ssh(scope, opts) do
    case Keyword.get(opts, :ssh_key_path) do
      path when is_binary(path) ->
        {:ok, Keyword.put_new(opts, :env, env(scope))}

      _ ->
        write_builder_key(scope, opts)
    end
  end

  defp write_builder_key(scope, opts) do
    case AccountSecrets.fetch_value(scope, @access_key_private) do
      {:ok, private} when is_binary(private) and private != "" ->
        dir = Path.join(System.tmp_dir!(), "cms-build-#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir)
        path = Path.join(dir, "id_ed25519")
        File.write!(path, private)
        File.chmod!(path, 0o600)

        {:ok,
         opts
         |> Keyword.put(:ssh_key_path, path)
         |> Keyword.put(:builder_key_dir, dir)
         |> Keyword.put_new(:env, env(scope))}

      _ ->
        {:error,
         "no server access key on this account — the server step mints one, so run it first"}
    end
  end

  # One environment's bucket. Named rather than inline because the step already
  # branches on credentials and reduces over environments, and a third level
  # inside that is where a reader stops being able to see which branch they are
  # in.
  #
  # The buckets already made are carried in the failure, so a run that dies on
  # the second environment can still clean up the first.
  defp ensure_bucket_for(environment, {:ok, acc}, project, credentials, opts) do
    bucket = Storage.bucket_name(project, environment)

    case Storage.ensure_bucket(bucket, credentials, opts) do
      {:ok, created} -> {:cont, {:ok, acc ++ [bucket_created_resource(created)]}}
      {:error, reason} -> {:halt, {:error, format(reason), acc}}
    end
  end

  # Every environment or none: a project with a production bucket and no UAT
  # bucket is not done, and saying it is hides that until an upload fails.
  defp every_bucket_present(wanted, credentials, opts) do
    case Storage.list_buckets(credentials, opts) do
      {:ok, existing} -> buckets_verdict(wanted, existing, opts)
      {:error, reason} -> {:error, format(reason)}
    end
  end

  defp buckets_verdict(wanted, existing, opts) do
    if Enum.all?(wanted, &(&1 in existing)) do
      {:ok, :satisfied, Enum.map(wanted, &bucket_resource(&1, opts))}
    else
      {:ok, :absent}
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

  # Where a deploy lands is decided by the config in the checkout, not by
  # anything setup passes kamal — the `:host` above is only the health probe's
  # target. So a config naming another machine deploys this project's image
  # onto that machine, and then reports a health failure against a hostname it
  # never touched: the wrong server changed, and the error points elsewhere.
  #
  # A drill seeded from another app caught this with `proxy.host:
  # uat.astralbi.com` still in place while the project's own uat was
  # `uat.drill.astralbi.com`. The stale file was the drill's doing; acting on
  # it would not have been, and `image: ghcr.io/your-org/...` is the shipped
  # placeholder, so a wrong host here is an ordinary state for a real repo.
  #
  # Only `proxy.host` is compared. `servers.web` legitimately carries IPs,
  # which no hostname comparison can judge, and guessing there would refuse
  # correct configs — the opposite failure and a worse one.
  #
  # A config that cannot be read or parsed is left to kamal and to
  # `Generators.DeployBoilerplate`, which already owns missing and malformed
  # deploy files. This guard answers one question: does this file name a host
  # that is not ours.
  defp config_targets_this_project(scope, environment) do
    with {:ok, body} <- read_deploy_config(scope, environment),
         {:ok, %{"proxy" => %{"host" => named}}} when is_binary(named) <-
           parse_deploy_config(body),
         [_ | _] = expected <- expected_hosts(scope, environment) do
      # A config that reads its host from the environment cannot name the wrong
      # one: `CMS_DEPLOY_HOST` is set by this step, from this project's domain,
      # a few lines before the script runs. The generated config resolves it
      # that way precisely because the alternative — a committed hostname, and
      # a committed server IP that is not even knowable until setup creates the
      # box — is what the `<UAT_HOST>` placeholders were standing in for.
      #
      # So there is nothing here to disagree with, and reading the ERB as a
      # literal hostname would refuse every generated project.
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

  # kamal's service name, read from the config kamal itself reads.
  #
  # kamal refuses an image that does not carry a `service` label matching it —
  # `Image <ref> is missing the 'service' label` — and it normally stamps that
  # label itself while building. Setup builds on its own builder and deploys
  # with `--skip-push`, so nothing added it, and the deploy rejected the image
  # it had just pulled.
  #
  # Read rather than derived: the service is whatever the generated config
  # says, and reconstructing it here from the project name would be a second
  # opinion about a value that already exists in one place.
  defp with_kamal_service(opts, scope, environment) do
    with {:ok, body} <- read_deploy_config(scope, environment),
         {:ok, %{"service" => service}} when is_binary(service) <-
           parse_deploy_config(body) do
      Keyword.put(opts, :service, service)
    else
      _ -> opts
    end
  end

  # kamal's config is ERB before it is YAML, and the two disagree.
  #
  # A control-flow tag can sit at the start of a line and be followed by a real
  # key — `<% if ENV["CMS_SSH_KEY_PATH"] %>  keys_only: true` — which YAML
  # rejects outright with `Block mapping value not allowed here`. Every
  # generated config contains one, so every parse of one failed.
  #
  # That mattered more than it looks: `config_targets_this_project/2` tolerates
  # a failed parse by returning `:ok`, so the check that setup will not deploy
  # to a host the project does not own has never actually run on a generated
  # config. It looked like a passing check and was an unparsed file.
  #
  # Statement tags are removed outright. Output tags stay, because
  # `resolved_at_runtime?/1` recognises a host by the `<%` in it — but their
  # inner double quotes are swapped for single ones first: a value like
  #
  #     keys: [ "<%= ENV["CMS_SSH_KEY_PATH"] %>" ]
  #
  # closes its own YAML string on the inner quote and leaves `ENV[` dangling
  # as a second scalar. The tag's text survives, which is all either caller
  # reads it for.
  # Public for its own test: the rewrite is subtle enough that it is worth
  # asserting on directly rather than through two callers that both swallow a
  # failure.
  @doc false
  @spec parse_deploy_config(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_deploy_config(body) do
    body
    |> String.replace(~r/<%(?!=).*?%>/s, "")
    |> then(&Regex.replace(~r/<%=.*?%>/s, &1, fn tag -> String.replace(tag, "\"", "'") end))
    |> YamlElixir.read_from_string()
  end

  defp read_deploy_config(scope, environment) do
    Environments.read_file(env(scope), deploy_config_path(environment))
  end

  # Mirrors `bin/deploy`, which reaches for `config/deploy.uat.yml` when the
  # environment is uat and `config/deploy.yml` otherwise. Checking a different
  # file from the one kamal reads would verify nothing.
  defp deploy_config_path("uat"), do: "config/deploy.uat.yml"
  defp deploy_config_path(_), do: "config/deploy.yml"

  defp expected_hosts(scope, environment) do
    case domain(scope) do
      nil ->
        []

      name ->
        scope
        |> EnvironmentRepository.assign_hosts(name)
        |> Enum.filter(&(&1.name == environment and is_binary(&1.host)))
        |> Enum.map(& &1.host)
    end
  end

  defp content_proof(%{render: render, proven_at: proven_at} = result) do
    %{
      kind: "content_proof",
      location: render[:path] || render["path"] || "",
      identifier:
        "state=rendered status=#{render[:status] || render["status"]} " <>
          "title_present=#{title_present?(render)} proven_at=#{iso(proven_at)} " <>
          "version=#{content_version(result)}"
    }
  end

  # Which content is live, not merely that something is. A failed publish keeps
  # the proof of the last one that worked — `content_proof` is not run-scoped —
  # so this is what says the version visitors see did not change (8038).
  defp content_version(%{published: %{content_hash: hash}}) when is_binary(hash), do: hash
  defp content_version(_result), do: ""

  defp content_failure(state, reason, published) do
    %{
      kind: "content_failure",
      location: to_string(reason),
      identifier: "state=#{state} objects_uploaded=#{uploaded?(published)}"
    }
  end

  # One resource per object, because 8035 asks whose bucket each landed in and
  # a single summary line cannot answer that.
  defp content_objects(%{published: %{objects: objects}}) when is_list(objects) do
    Enum.map(objects, fn object ->
      %{
        kind: "content_object",
        location: object[:key] || object["key"] || "",
        identifier:
          "owner=#{object[:owner] || object["owner"] || "user"} " <>
            "bucket=#{object[:bucket] || object["bucket"]}"
      }
    end)
  end

  defp content_objects(_), do: []

  defp uploaded?(%{objects: objects}) when is_list(objects), do: objects != []
  defp uploaded?(_), do: false

  defp title_present?(render) do
    contains = render[:body_contains] || render["body_contains"]
    contains not in [nil, false, []]
  end

  # What the live site said when it was checked: the status, and whether the
  # widget was both present and openable. Present-but-not-openable is the shape
  # a broken bundle takes, so 8040 asks for them separately.
  defp widget_render(%{presence: %{} = presence}) do
    %{
      kind: "widget_render",
      location: to_string(presence[:status] || presence["status"]),
      identifier:
        "status=#{presence[:status] || presence["status"]} " <>
          "present=#{presence[:present] || presence["present"]} " <>
          "openable=#{presence[:openable] || presence["openable"]}"
    }
  end

  defp widget_render(_), do: nil

  # A message that actually travelled from the deployed site. `origin` is the
  # part that distinguishes it from one posted by hand, which is what 8044
  # means by "not by a script tag".
  # No nil fallback: the only call site is the `:proven` branch, where `proof`
  # is always a map. A clause for the impossible case is one the compiler
  # reports as unreachable, and an unreachable clause is a compiler warning —
  # which makes the analyzer skip exunit, credo and spex entirely.
  # Inbound widget messages for the project, each tagged with where it came
  # from relative to the site provisioning just deployed.
  #
  # Compared by host rather than by string: the app reports the base URL it
  # computed for itself, and that differs from what the operator typed in
  # scheme, port and trailing slash without meaning a different site. A
  # message with no origin at all predates the widget reporting one, and is
  # `unknown` rather than trusted — an untagged message proving the widget
  # works is exactly the false pass this step exists to prevent.
  defp widget_messages(scope, site_url) do
    host = uri_host(site_url)

    scope
    |> Conversations.list_widget_messages()
    |> Enum.map(&%{origin: origin_of(&1.origin, host), id: &1.id, at: &1.inserted_at})
  end

  defp origin_of(origin, host) when is_binary(origin) and is_binary(host) do
    case uri_host(origin) == host do
      true -> "deployed_site"
      false -> "elsewhere"
    end
  end

  defp origin_of(_origin, _host), do: "unknown"

  defp uri_host(url) when is_binary(url), do: URI.parse(url).host
  defp uri_host(_url), do: nil

  defp widget_proof(%{proof: %{} = proof, proven_at: proven_at}) do
    %{
      kind: "widget_proof",
      location: to_string(proof[:origin] || proof["origin"] || "deployed_site"),
      identifier:
        "state=#{proof[:state] || proof["state"]} " <>
          "origin=#{proof[:origin] || proof["origin"]} proven_at=#{iso(proven_at)}"
    }
  end

  defp build_image(scope, environment, opts) do
    # Injectable for the same reason the builder's own create/build/destroy
    # are: making the registry's bucket is a real call to object storage, and a
    # criterion about *what gets built* should not have to buy one to say so.
    # Retention is Registry's own claim and is proven where it lives.
    # The registry and its bucket belong to the server step now. A build should
    # find infrastructure, not create it — creating it here meant a project had
    # no registry until something tried to build, and a build that died left
    # behind a network and a container nobody had recorded.
    with {:ok, architecture} <- architecture_for(scope, environment, opts),
         {:ok, opts} <- with_access_key(scope, opts),
         opts = Keyword.put_new(opts, :environment, environment),
         {:ok, opts} <- with_private_network(scope, environment, opts),
         {:ok, opts} <- with_registry_credential(scope, opts),
         {:ok, opts} <- with_builder_ssh(scope, opts),
         opts = with_kamal_service(opts, scope, environment),
         {:ok, tag} <- image_tag(scope, opts),
         # Computed before the build, not after: it is where the image is
         # pushed *to*, so the builder needs it in hand. `Builder.docker_build`
         # reads it from `opts[:reference]` and refuses with `no_image_reference`
         # without it — which is what the first drill that got this far hit,
         # because this line used to sit below the build and derive a reference
         # for something already finished. Deriving it needs only the tag.
         {:ok, reference} <- Registry.reference(scope, tag, opts),
         opts = Keyword.put(opts, :reference, reference),
         {:ok, build} <- build_on_builder(scope, tag, architecture, opts) do
      {:ok,
       %{
         reference: reference,
         built: true,
         # Carried out so the step can record it. A network created inside the
         # build and never surfaced is one teardown cannot find.
         network: Keyword.get(opts, :network_resource),
         architecture: build.architecture,
         retention_days: Registry.retention_days(opts),
         builder: build.builder,
         builder_image: build.builder_image,
         builder_destroyed: build.builder_destroyed
       }}
    end
  end

  # A build that failed still made a box, so the failure carries what became of
  # it. Returned as partial resources, which is how every other step reports
  # "this did not finish, and here is what it made" — the same channel that
  # lets a run that died on the second environment still clean up the first.
  defp build_on_builder(scope, tag, architecture, opts) do
    case Builder.build(scope, tag, Keyword.put(opts, :architecture, architecture)) do
      {:ok, build} -> {:ok, build}
      {:error, reason, disposition} -> {:error, format(reason), builder_resource(disposition)}
      {:error, reason} -> {:error, format(reason)}
    end
  after
    # However the build went. A private key left in the system temp directory
    # is the kind of residue nobody looks for, and this one opens every box the
    # account owns.
    case Keyword.get(opts, :builder_key_dir) do
      dir when is_binary(dir) -> File.rm_rf(dir)
      _ -> :ok
    end
  end

  # The commit is the tag, because "which image is this" and "which code is
  # this" should not be two questions.
  defp image_tag(scope, opts) do
    case Keyword.get(opts, :tag) || head_commit(scope) do
      sha when is_binary(sha) and sha != "" -> {:ok, String.slice(sha, 0, 12)}
      _ -> {:error, "cannot tag an image: the project has no commit to build"}
    end
  end

  defp head_commit(scope) do
    case Environments.cmd(env(scope), "git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  # The architecture the environment's box runs, not a default. An image built
  # for the other one fails at container start, which is a deploy that looks
  # healthy until the swap.
  #
  # Asked of Hetzner rather than assumed, because what we requested and what
  # exists are different questions: the server step answers a sold-out region by
  # taking the other architecture. This used to return `:arm` regardless, which
  # made that fallback silently produce an unrunnable image.
  defp architecture_for(scope, environment, opts) do
    case Keyword.get(opts, :architecture) do
      nil -> environment_architecture(scope, environment)
      architecture -> {:ok, architecture}
    end
  end

  defp environment_architecture(scope, environment) do
    case EnvironmentRepository.get(scope, environment) do
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

  # The baseline network, or a refusal that names the step which makes it.
  defp find_baseline_network(scope, name) do
    case Hetzner.find_network(scope, name) do
      {:ok, network} ->
        {:ok, network}

      {:error, :not_found} ->
        {:error,
         "this project has no private network — the server step creates it, along with the " <>
           "registry the deploy pulls from. Run the server step first."}

      {:error, _} = error ->
        error
    end
  end

  # Kamal evaluates ERB in its config, so a host written that way is decided
  # when the deploy runs rather than when the file was committed.
  defp resolved_at_runtime?(value), do: String.contains?(value, "<%")

  # kamal refuses to render a config without a registry password, and then
  # performs a `docker login` with it — so the same credential the builder
  # pushes with has to reach the deploy script.
  # The key kamal connects with, on the same terms the builder's SSH gets it.
  #
  # `build_image` writes this key too, but into its own opts, which never come
  # back here — so kamal ran with nothing set, `CMS_SSH_KEY_PATH` was absent
  # from its environment, the generated config's `keys_only` branch was not
  # rendered, and net-ssh offered every identity the agent held. A box with
  # the default `MaxAuthTries` hung up first:
  #
  #   ERROR (Net::SSH::Disconnect): disconnected: Too many authentication
  #   failures (2)
  #
  # A deploy given a key explicitly must not fall through to the agent, and a
  # person running `bin/deploy` by hand still does.
  defp with_deploy_ssh(opts, scope) do
    case with_builder_ssh(scope, opts) do
      {:ok, opts} -> opts
      _ -> opts
    end
  end

  # Wrapped so the private key written for kamal is removed however the deploy
  # goes — the same reason `build_on_builder/4` cleans up after itself. This
  # one opens every box the account owns, and the system temp directory is not
  # where anybody would look for it.
  defp run_deploy(scope, environment, deploy_opts) do
    Deploy.run(env(scope), environment, deploy_opts)
  after
    case Keyword.get(deploy_opts, :builder_key_dir) do
      dir when is_binary(dir) -> File.rm_rf(dir)
      _ -> :ok
    end
  end

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

  # A box we just created has a host key nothing has seen before, and cloud
  # providers recycle addresses — so an address in `known_hosts` from a
  # destroyed server is not a warning about anything, it is a stale record of a
  # machine that no longer exists. kamal's net-ssh reads that file and refuses:
  #
  #   ERROR (Net::SSH::HostKeyMismatch): fingerprint SHA256:... does not match
  #
  # Our own SSH never saw it, using `UserKnownHostsFile=/dev/null` — which is
  # why this surfaced only once kamal started connecting.
  #
  # Removed rather than disabled. Dropping host key checking for every deploy
  # would trade a real protection for the convenience of not managing one
  # entry, and the entry is one this step is entitled to remove: it provisioned
  # the machine that holds the address.
  defp forget_stale_host_key(opts) do
    case Keyword.get(opts, :host_ip) do
      ip when is_binary(ip) and ip != "" ->
        System.cmd("ssh-keygen", ["-R", ip], stderr_to_stdout: true)
        :ok

      _ ->
        :ok
    end
  end

  # The registry's own credential, for the builder's push and for kamal's pull.
  # `Builder.Remote` has supported `docker login` since the shared-registry
  # design and never had anything to log in with.
  defp with_registry_credential(scope, opts) do
    case Registry.credential(scope) do
      {:ok, credential} ->
        {:ok, Keyword.put(opts, :registry_credentials, credential)}

      {:error, reason} ->
        {:error, "could not read or mint the registry password: #{format(reason)}"}
    end
  end

  # The key that opens this environment's encrypted env, handed to the deploy so
  # it can hand it to the container. Kept in `ProjectSecrets` rather than in the
  # repository, which is why the script cannot simply read it off disk.
  defp with_age_key(opts, scope, environment) do
    case fetch_age_key(scope, environment) do
      {:ok, key} -> Keyword.put(opts, :age_key, key)
      _ -> opts
    end
  end

  # The box this environment's traffic lands on. Not knowable when the deploy
  # config was written — the server is created by an earlier step, and a
  # different one on every provision — which is why the generated config
  # carries `<UAT_HOST_IP>` rather than an address.
  defp with_host_ip(opts, scope, environment) do
    case environment_ip(scope, %{name: environment}, opts) do
      ip when is_binary(ip) and ip != "" -> Keyword.put(opts, :host_ip, ip)
      _ -> opts
    end
  end

  # The architecture rides along because it is the claim worth checking: an
  # image built for the other one deploys cleanly and dies at container start,
  # so "which architecture did this get built for" has to be answerable from
  # the record rather than by rebuilding it.
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

  # Old images stop costing money because the registry's bucket expires them,
  # not because anything here runs on a schedule — the same shape as the
  # backups' retention, and recorded so it is visible without reading a
  # bucket policy.
  defp retention_resource(%{retention_days: days}) when is_integer(days),
    do: [
      %{
        kind: "image_retention",
        location: "#{days} days",
        identifier: "enforced_by=bucket_lifecycle"
      }
    ]

  defp retention_resource(_image), do: []

  # The box the image was built on, and what became of it. Recorded because a
  # builder that quietly stops being destroyed costs money every deploy and
  # changes nothing anyone can see — the image still arrives.
  #
  # `booted_from` is the pre-warmed image: the toolchain is already on it, so a
  # deploy does not pay to install Docker every time (8239).
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

  # One per environment, and that is the point rather than thoroughness:
  # sharing a sending domain makes a message from UAT indistinguishable from
  # a production one at the recipient, so a test send can be mistaken for the
  # real thing (criterion 8056).
  #
  # Partial results are carried through the failure so a run that registers
  # production and then fails on UAT can still clean up what it made.
  defp verify_sending_domains(scope, base, environments) do
    environments
    |> Enum.reduce_while({:ok, []}, fn environment, {:ok, acc} ->
      sending = Resend.sending_domain(base, environment)

      case Resend.find_domain(scope, sending) do
        {:ok, %{"status" => "verified"} = d} ->
          {:cont, {:ok, acc ++ [%{kind: "sending_domain", location: "resend/#{d["name"]}"}]}}

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

  defp register_sending_domains(scope, base, environments, opts) do
    Enum.reduce_while(environments, {:ok, []}, fn environment, {:ok, acc} ->
      case register_sending_domain(scope, base, environment, opts) do
        {:ok, resources} -> {:cont, {:ok, acc ++ resources}}
        # Carries what earlier environments already made, exactly as the error
        # path does — a pause on the second environment must not lose the
        # first's sending domain.
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
        # The domain now exists at the provider whether or not it verifies,
        # so it is named from here on. A verification timeout that reported
        # no resources left a real Resend domain nothing could find to
        # remove.
        # `adopted:` rather than `created:` when the domain already existed.
        # Teardown reads this and refuses to remove what setup only found —
        # deleting an adopted resource destroys something the user had before
        # setup ever ran.
        created = [
          %{
            kind: "sending_domain",
            location: "resend/#{sending}",
            identifier: "#{environment}:#{d["id"]}",
            origin: if(d["__adopted__"], do: "adopted", else: "created")
          }
        ]

        # Publish before polling. Resend will not verify a domain whose records
        # are not in DNS, so a run that registered and went straight to polling
        # could only ever time out — and it did, on every real project. The
        # spex missed it because a fixture published the records the step was
        # supposed to publish, which made the step look like it worked.
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

  # `ensure_domain/2` does not carry the records. The adopt path comes from
  # `list_domains`, which never includes them, and the create response is not to
  # be relied on either — so this re-reads the domain.
  #
  # Without it `Resend.records/1` returned `[]`, `publish_sending_records/3`
  # took the "nothing to publish" branch and reported success, and not one
  # record reached DNS. It looked exactly like a working step: no error, a
  # sending domain registered, and every name resolving `false` afterwards for
  # what appeared to be a propagation delay.
  # The domain as Resend describes it when asked for by id, which is the only
  # form that carries `records`.
  defp inbound_records_for(scope, %{"id" => id} = domain) do
    case Resend.get_domain(scope, id) do
      {:ok, body} -> body["data"] || body
      _ -> domain
    end
  end

  defp inbound_records_for(_scope, domain), do: domain

  defp sending_records_for(scope, %{"id" => id} = domain) do
    case Resend.get_domain(scope, id) do
      {:ok, body} -> Resend.records(body["data"] || body)
      _ -> Resend.records(domain)
    end
  end

  defp sending_records_for(_scope, domain), do: Resend.records(domain)

  # Write the records Resend asked for, into the zone that covers the sending
  # domain and no other.
  #
  # The zone comes from `sending` rather than from the project's domain or from
  # opts. That is the whole safety property here: a record can only land in a
  # zone that already covers its own name, so there is no argument that can
  # send a write somewhere unrelated. Resolving the zone from a separate value
  # is what once put `send.<label>.codemyspec.com` in the production zone while
  # the run was supposed to be confined to a throwaway domain.
  #
  # Names are qualified against the **zone**, because that is what Resend's are
  # relative to — it returns `send.<label>`, not the full name. Handing that
  # straight to Cloudflare works by accident when the zone happens to be right
  # and writes to the wrong name when it is not, which is the same defect
  # wearing a different hat.
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

    # Belt and braces. `find_zone` already matches on a label boundary, so this
    # should be unreachable — and it is cheap enough to keep, because the
    # failure it guards against is writing DNS to somebody's live domain and
    # only finding out from the residue.
    if covered_by?(name, zone["name"]) do
      publish_sending_record(scope, zone, name, record, existing, acc)
    else
      {:halt,
       {:error,
        "refusing to publish #{name}: it is not inside the #{zone["name"]} zone, and a " <>
          "record written outside its own zone lands on a domain nobody meant to touch"}}
    end
  end

  # No `ttl`. Resend reports it as the string "Auto" and Cloudflare answers
  # `9208 Failed to parse. ttl must be a number.`, so passing it through
  # rejected the very first record — the DKIM — and the step halted having
  # published nothing. Leaving it off lets Cloudflare apply its own default,
  # which is what "Auto" meant in the first place.
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

      # Naming the records at fault is the point: "verification timed out"
      # sends Sam to diff a record set by hand, which is the failure
      # criterion 8027 exists to prevent.
      {:error, {:unverified, faulted}} ->
        {:error,
         "the sending domain #{sending} did not verify — these records are not as Resend " <>
           "expects: " <> Enum.map_join(faulted, ", ", &"#{&1["type"]} #{&1["name"]}"), created}

      # Nothing is wrong yet, so this is a wait rather than a failure. Resend
      # verifies on its own schedule and a re-run picks it up; reporting these
      # as faulted named three correct records as broken on a real drill and
      # they verified minutes later untouched.
      {:error, {:still_verifying, pending}} ->
        {:paused,
         "#{sending} is registered and its records are published — Resend has not finished " <>
           "checking them yet (#{Enum.map_join(pending, ", ", &"#{&1["type"]} #{&1["name"]}")}). " <>
           "Nothing is wrong with them; run this step again in a few minutes.", created}

      {:error, reason} ->
        {:error, format(reason), created}
    end
  end

  # Setup writes the repository onto the project. Without this a re-run cannot
  # tell its own work from a repository Sam already had — which is the whole
  # distinction between adopting (8179) and stopping to ask (8185) — and every
  # later step that needs a remote has to re-derive it.
  defp record_repository(%{state: :pushed, repository: repo} = result, scope) do
    url = repo["clone_url"] || repo["html_url"]

    if is_binary(url) and url != "" do
      Projects.update_project(scope, project(scope), %{code_repo: url})
    end

    result
  end

  defp record_repository(result, _scope), do: result

  # Whether the project already records the repository this step would use.
  # Compared on the last path segment, because the recorded URL may be the SSH
  # or HTTPS form and either is the same repository.
  defp ours?(%{code_repo: url} = project, opts) when is_binary(url) and url != "" do
    name = Keyword.get(opts, :name) || Repository.default_name(project)

    recorded =
      url |> String.trim_trailing(".git") |> String.split("/") |> List.last()

    recorded == name
  end

  defp ours?(_project, _opts), do: false

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

  Criterion 7999 is that the decryption key travels as deploy configuration
  rather than as a file Sam places by hand, and 8000 is that a missing secret
  refuses the boot *by name*. Both are answered before anything is shelled
  out, so a deploy that cannot succeed does not first go and change the
  server.
  """
  @spec check_secrets(Scope.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  # No environment at all is a different failure from a missing secret, and it
  # belongs to whoever can fix it: nobody can set a secret for a project with
  # nowhere to check it out. Reporting "no age key" there would send Sam to
  # the secret form, which would fail for the same underlying reason.
  def check_secrets(%Scope{environment: nil}, _environment),
    do: {:error, no_environment_message()}

  def check_secrets(%Scope{} = scope, environment) do
    env = env(scope)

    with {:ok, private} <- fetch_age_key(scope, environment),
         {:ok, missing} <- Sops.missing_secrets(env, environment, private, @required_secrets) do
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

  # `data-via` and `data-manual-step-required` are the observable form of "the
  # deploy carries the key, Sam does not". The private half goes into the
  # deploy's environment from ProjectSecrets; nothing writes a keys.txt and
  # nobody logs in to place one.
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

  # The deploy's phases become resources so the page can show that migration
  # landed before the swap (8007), that a failed migration left the old
  # version serving (8008), and that an unhealthy version never went live
  # (8009). A failure keeps its resources via the partial-resource path, so
  # the record shows what happened rather than just an error string.
  defp with_output(reason, output) when is_binary(output) do
    case String.trim(output) do
      "" -> reason
      trimmed -> reason <> "\n\n" <> trimmed
    end
  end

  defp with_output(reason, _output), do: reason

  defp deploy_outcome(result, environment, host) do
    phases =
      [
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

        # With what the script said, not just that it failed. `Result` carries
        # the output in its own field and this reported only the sentence
        # around it — so "Migration failed (exit 1)" was the entire account of
        # a kamal run, and the reason sat in a struct nobody rendered.
        {:error, with_output(reason, result.output), [failure | phases]}

      %{swapped_at: _} ->
        {:ok, [%{kind: "deployment", location: "#{environment}/#{host}"} | phases]}
    end
  end

  # What the deploy shipped, recorded so the page can show the running version
  # is traceable to the commit CI built (8005). Absent when the caller did not
  # supply it — a real deploy derives it from git + the registry config.
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

  # Each resource carries its environment, the way every other fanned-out step
  # tags them. Without it a page showing three dumps cannot say which database
  # any of them holds — and "we have backups" is only worth anything if you can
  # tell which.
  defp put_age_key(opts, scope, environment) do
    case fetch_age_key(scope, environment) do
      {:ok, key} -> Keyword.put(opts, :age_key, key)
      # No key yet means the secrets step has not run. The dump will fail on
      # its own terms and say so, which is better than this deciding for it.
      {:error, :not_found} -> opts
    end
  end

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
  defp env(%Scope{environment: environment}), do: environment

  defp domain(%Scope{active_project: %{domain: d}}) when is_binary(d) and d != "", do: d
  defp domain(_), do: nil

  # The environment's own hostname, which is not the project's domain for any
  # environment but production.
  #
  # The deploy step used `domain/1` regardless, so a UAT deploy was handed
  # production's hostname: it went into `CMS_DEPLOY_HOST`, and from there into
  # the container's `PHX_HOST` and kamal's `proxy.host`, and the health check
  # then probed production's address — where nothing had been deployed, so it
  # answered `econnrefused` after a deploy that had actually succeeded.
  #
  # Falls back to the domain so a project whose environments predate hosts
  # behaves as it did.
  defp environment_host(scope, environment) do
    case EnvironmentRepository.get(scope, environment) do
      %{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  # The project's environments, by name. `opts` still wins so a spex or a
  # caller can narrow the fan-out, but the default now comes from the project
  # rather than from a literal — which is what lets a project have a `qa`
  # environment, or one per story, without a code change here.

  # Halts on the first failure rather than pressing on, for the reason
  # `serve_registries/5` does: a production deploy that runs after UAT failed
  # is a production deploy nobody has evidence for. Resources from the
  # environments that did land are kept, so a partial run is still recorded.
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
         # Before the build, not after: the builder is sent `git archive HEAD`
         # and `bin/deploy` versions the image by `git rev-parse HEAD`, so
         # committing afterwards built one SHA and deployed another.
         :ok <- commit_generated_configuration(scope),
         {:ok, image} <- image_for(scope, environment, opts),
         deploy_opts =
           opts
           |> deploy_opts(host, image)
           |> with_host_ip(scope, environment)
           |> with_age_key(scope, environment)
           |> with_registry_credential_for_deploy(scope)
           |> with_deploy_ssh(scope),
         :ok <- forget_stale_host_key(deploy_opts),
         result <- run_deploy(scope, environment, deploy_opts) do
      case deploy_outcome(result, environment, host) do
        {:ok, resources} ->
          # Recorded only here, on the success branch, because `deploy_outcome`
          # returns `{:ok, _}` only after the health probe passed. A deploy that
          # shipped and never answered must not read as done — criterion 1964 —
          # and writing the row anywhere earlier would make it exactly that.
          {:ok, _deploys} =
            Deploys.record_environment_deploy(
              scope,
              environment,
              deploy_record_attrs(image, version)
            )

          {:ok, [delivery | version_resources(version) ++ image_resources(image) ++ resources]}

        {:error, reason, resources} ->
          {:error, reason, [delivery | resources]}
      end
    end
  end

  defp environments(scope, opts) do
    Keyword.get(opts, :environments) || EnvironmentRepository.names(scope)
  end

  defp server_name(scope, opts) do
    Keyword.get(opts, :server_name) || Repository.default_name(project(scope))
  end

  # An environment's server is its own box: `<project>-<environment>`. Sharing
  # one between environments would mean UAT traffic reaching production, which
  # is the thing having environments is for.
  defp server_name(scope, opts, environment) do
    "#{server_name(scope, opts)}-#{environment}"
  end

  # The disposition rides on the resource because "adopted rather than
  # duplicated" is only checkable if the page can tell the two apart — and
  # `created` twice is exactly the failure the criterion is about.
  defp repo_resource(repo, disposition) do
    %{
      kind: "repository",
      location: repo["full_name"] || repo["name"],
      identifier: disposition && to_string(disposition)
    }
  end

  # The address, not the datacenter. Hetzner omits `datacenter` from the
  # create response, so that read rendered "hetzner/?/name" on the one run
  # that matters — the first. The IP is present on both create and find, and
  # it is the useful fact anyway: it is what DNS points at and what Sam SSHes
  # to when a step fails.
  # Carries what has been made so far alongside a failure, so the `else` above
  # can hand it to the recorder.
  defp made_or_error({:error, reason}, made), do: {:error, reason, made}
  defp made_or_error(result, _made), do: result

  # verify/3 re-derives a step's resources from what the provider actually
  # holds. A missing sub-resource is not an error here — it just contributes
  # nothing to the list.
  defp found_resource({:ok, thing}, build), do: [build.(thing)]
  defp found_resource(_, _build), do: []

  # One server per environment, recorded back onto the environment so the DNS
  # step and the deploy step have somewhere to look. A failure part-way keeps
  # what was already made in the error tuple — the recorder stores it, so a
  # re-run converges instead of stranding a box nothing remembers.
  # Read the environments once and thread that list through everything after
  # it, rather than each part asking again.
  #
  # A drill created a `-prod` box and never asked for `-uat`, while the verify
  # pass moments earlier and the check moments later both saw two environments
  # — the same read, three times, disagreeing. Which read was wrong barely
  # matters: a step that fans out over a list and then checks its work against
  # a *different* list can report a gap that is really a disagreement, or miss
  # one that is real. One read cannot disagree with itself.
  defp ensure_environment_servers(scope, opts, made) do
    environments = EnvironmentRepository.list(scope)

    Logger.info(
      "[Provisioning] server step provisioning #{length(environments)} environment(s): " <>
        Enum.map_join(environments, ", ", & &1.name)
    )

    environments
    |> Enum.reduce_while({:ok, made}, &ensure_environment_server(&1, &2, scope, opts))
    |> join_baseline_network(scope, opts, environments)
  end

  # The private network the registry answers on, and the app's boxes reach it
  # over. Baseline infrastructure, so it belongs to this step — it was created
  # inside `build_image` before, which is why a failed build left one behind:
  # a build is not what a network's lifetime should be tied to.
  #
  # After the servers rather than before, because a server's location is not
  # known until it exists: `create_server/3` falls back to the other
  # architecture when Hetzner has no capacity, and that fallback changes the
  # location — and therefore the zone the subnet has to be in.
  defp join_baseline_network({:ok, made}, scope, opts, environments) do
    name = server_name(scope, opts)
    servers = environment_servers(scope, opts, environments)

    with {:ok, [%{"location" => %{"name" => location}} | _] = servers} <- servers,
         {:ok, network} <-
           Hetzner.ensure_network(scope, name, network_zone: Hetzner.network_zone(location)),
         :ok <- attach_all(scope, servers, network),
         {:ok, registries} <- serve_registries(scope, servers, network, opts, environments) do
      {:ok, registries ++ [network_resource(name, network) | made]}
    else
      {:ok, []} -> {:ok, made}
      {:error, reason} -> {:error, format(reason), made}
    end
  end

  defp join_baseline_network(other, _scope, _opts, _environments), do: other

  # One registry per environment, on that environment's own box.
  #
  # Baseline infrastructure rather than a build artifact. Started inside
  # `build_image` before, which meant a project had no registry until something
  # tried to build, and a build that died left a container nobody recorded.
  #
  # Per environment because a binary cannot be promoted across architectures:
  # UAT may be arm and production x86, `Builder` refuses an image built for the
  # wrong one, so each environment builds its own and needs somewhere of its
  # own to put it.
  # Over the servers that exist, not over the environment rows. Those two can
  # disagree — an environment whose server was not created, or a name that does
  # not match — and when they did this failed with a bare `not found`, naming
  # neither the environment nor the server it wanted. Iterating what was
  # actually found cannot disagree with itself.
  defp serve_registries(scope, servers, network, opts, environments) do
    Enum.reduce_while(servers, {:ok, []}, fn server, {:ok, acc} ->
      case serve_one_registry(scope, server, network, opts, environments) do
        {:ok, resources} -> {:cont, {:ok, resources ++ acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp serve_one_registry(scope, server, network, opts, environments) do
    environment = environment_of(scope, server, opts, environments)

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
           # `put_new`, so a caller that supplied its own address keeps it. The
           # registry publishes on `-p <address>:5000:5000`, and the private IP
           # is right for a Hetzner box on a private network and meaningless on
           # anything else — a local box has no 10.x address, so the container
           # would refuse to start on an address the host does not carry.
           #
           # Pairs with `:run` above: together they are what lets the local
           # fleet stand in for the box, so this step runs its real docker
           # commands against something that exists instead of against a
           # server address that was released weeks ago.
           |> Keyword.put_new(:bind, ip),
         # Before any command runs on it. Hetzner returns a server the moment
         # it is scheduled, `status: initializing`, and SSH comes up somewhere
         # in the following minute — so this step used to reach the box about
         # thirty seconds after asking for it and fail with
         # `{:registry_start_failed, 255, "ssh: connect to host … timed out"}`.
         # `serve_registries/5` halts on that, so the whole run stopped at
         # `server` with the thirteen steps behind it reporting nothing.
         #
         # The builder has waited like this all along; this path never learned
         # to, which is why a drill's outcome depended on how quickly Hetzner
         # happened to boot that day.
         :ok <- await_box(run, opts),
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

  # The database the app talks to, and the URL it reads to find it.
  #
  # Nothing provisioned one before: `backups` ran `pg_dump` against a database
  # that did not exist and the generated kamal config put the app on a
  # `db_net` network with nothing else on it.
  #
  # The URL goes into the environment's encrypted env rather than anywhere the
  # working tree can see, which is where the app already looks for everything
  # else it needs to boot.
  defp serve_database(scope, environment, run, opts) do
    with {:ok, credential} <- Database.credential(scope, environment),
         {:ok, served} <-
           Database.serve(scope, environment, Keyword.put(opts, :run, run)),
         :ok <- write_database_url(scope, environment, credential) do
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

  # The bucket, as a bucket, when there is one.
  #
  # It used to be named only inside the registry resource's identifier, and
  # teardown matches on `kind`, so nothing ever removed it — a run that halted
  # between here and the storage step left `<project>-registry-<env>` behind
  # with no record that this step had made it. Recorded here rather than relied
  # on downstream, because the step that creates a resource is the one that
  # knows it exists.
  #
  # `origin` explicitly, because its default is "adopted" and teardown's first
  # clause returns adopted resources untouched — so a resource recorded without
  # one is reported as torn down and never deleted.
  #
  # Nothing at all under the default filesystem storage: recording a bucket
  # that was never created makes teardown report deleting something that does
  # not exist, which is the same lie pointing the other way.
  defp registry_bucket_resource(:none), do: []

  defp registry_bucket_resource(bucket) when is_binary(bucket),
    do: [%{kind: "bucket", location: bucket, identifier: "registry", origin: "created"}]

  # The same wait the builder does, with the same knobs, so a caller that
  # already tunes `:ssh_attempts` or `:ssh_interval_ms` for one tunes both.
  # A fixture that injects its own `:run` — a local box, already up — passes
  # this on the first attempt and pays nothing.
  defp await_box(run, opts) do
    Remote.await_ssh(run, Keyword.get(opts, :ssh_attempts, 90), opts)
  end

  # Which environment a box belongs to, from the name the server step gave it.
  # The alternative is passing the environment alongside every server and
  # keeping the two in step, which is the thing that just went wrong.
  defp environment_of(scope, server, opts, environments) do
    Enum.find_value(environments, "uat", fn environment ->
      environment.name == nil ||
        (server_name(scope, opts, environment.name) == server["name"] && environment.name)
    end)
  end

  # Every environment's box, or a refusal naming the ones missing.
  #
  # This used to drop what it could not find, so a run where one environment's
  # server was absent carried on and stood up a registry and a database for the
  # other — and the deploy then failed with "the provider has no such server",
  # which names the symptom two steps after the cause. A baseline that is
  # missing half of itself must say so where it happens.
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

  defp attach_all(scope, servers, network) do
    Enum.reduce_while(servers, :ok, fn server, :ok ->
      case Hetzner.attach_to_network(scope, server["id"], network["id"]) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ensure_environment_server(environment, {:ok, acc}, scope, opts) do
    name = server_name(scope, opts, environment.name)

    Logger.info("[Provisioning] #{environment.name}: ensuring server #{name}")

    case Hetzner.ensure_server(scope, name, opts) do
      {:ok, server} ->
        Logger.info("[Provisioning] #{environment.name}: got #{inspect(server["name"])}")
        record_environment_server(scope, environment, name, server, acc)

      {:error, reason} ->
        {:halt, {:error, format(reason), acc}}
    end
  end

  # The address, written back from what the provider just said.
  #
  # `run/3` records `server_name` and `ip` against the environment
  # (`record_environment_server/5`) and `verify/3` did not, so an adopted server
  # left the row holding whatever it held before — a stale address after a
  # rebuild, or none at all. Everything downstream reads that row: DNS points
  # the A record at it, the deploy SSHes to it, the TLS diagnostic reads the
  # proxy log over it. So the step reported done while the row it exists to
  # populate disagreed with the provider.
  #
  # Seen as "No address is recorded for this environment, so its proxy log could
  # not be read" on a walk whose server was up, adopted, and answering — the
  # observation was right and pointed at nothing, because the row was empty.
  #
  # A read from the provider is the one answer entitled to overrule what was
  # recorded before; `Provisioning.reverify/3` says so about resources and this
  # is the same claim about the address. Written only when it differs, since
  # every page load verifies.
  defp reconcile_environment_server(scope, environment, name, server) do
    ip = get_in(server, ["public_net", "ipv4", "ip"])
    recorded = EnvironmentRepository.get(scope, environment)

    if is_binary(ip) and (recorded == nil or recorded.ip != ip or recorded.server_name != name) do
      EnvironmentRepository.put(scope, environment, %{server_name: name, ip: ip})
    end

    server_resource(server, environment)
  end

  # Halting on a failed write-back rather than discarding it. The box exists at
  # this point; if the row does not record it, nothing can find it again — the
  # page cannot show it and teardown cannot remove it, so it leaks and the step
  # still says done. A silent write is the worst of the three outcomes.
  defp record_environment_server(scope, environment, name, server, acc) do
    ip = get_in(server, ["public_net", "ipv4", "ip"])

    case EnvironmentRepository.put(scope, environment.name, %{server_name: name, ip: ip}) do
      {:ok, _environment} ->
        {:cont, {:ok, [server_resource(server, environment.name) | acc]}}

      {:error, reason} ->
        {:halt,
         {:error,
          "provisioned #{name} but could not record it against the #{environment.name} " <>
            "environment: #{format(reason)}", acc}}
    end
  end

  # One record per environment, each pointing at that environment's own server.
  # Nothing here knows what an environment is called: the host was decided when
  # the environment was given one, so production landing on the apex is data
  # rather than a branch.
  #
  # An environment with no server yet is skipped rather than failed — a project
  # part-way through provisioning has real environments that are not live, and
  # pointing DNS at nothing would be worse than pointing at nothing yet.
  defp find_dns_zone(scope, name, opts) do
    case Keyword.get(opts, :zone) do
      nil -> Cloudflare.find_zone(scope, name)
      zone -> {:ok, zone}
    end
  end

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
    |> Enum.reduce_while({:ok, []}, fn environment, {:ok, acc} ->
      case apex_repoint(scope, environment, existing, opts) do
        :ok -> dns_record_for(scope, zone, environment, existing, acc, opts)
        {:paused, message} -> {:halt, {:paused, message}}
      end
    end)
  end

  # Refuse to move a live apex without being told to.
  #
  # `assign_hosts/2` gives production the apex and every other environment a
  # subdomain, and every project starts with a `prod` row — so once a domain is
  # set, a run points the apex at a freshly created, empty box. If that apex is
  # a live site, it goes dark. Nothing warned at the point of decision, and the
  # only opt-out was deleting the environment, which you have to already know
  # about.
  #
  # This codebase already has the argument for a second step: a domain purchase
  # will not proceed without one, because registration is not refundable.
  # Overwriting a live apex is less reversible in the way that matters — the
  # money comes back, the downtime does not.
  #
  # Only the apex, and only when a record is already there pointing somewhere
  # else. A subdomain is this run's to move, and a first run has nothing to
  # overwrite. Decided from the records already listed for the zone, so this
  # costs no extra call and knows exactly what it would replace.
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
         "other, so remove the `prod` environment to leave the apex alone, or confirm to " <>
         "repoint it."}
    else
      _ -> :ok
    end
  end

  defp dns_record_for(scope, zone, environment, existing, acc, opts) do
    case environment_ip(scope, environment, opts) do
      nil -> {:cont, {:ok, acc}}
      ip -> write_dns_record_for(scope, zone, environment, ip, existing, acc, opts)
    end
  end

  defp write_dns_record_for(scope, zone, environment, ip, existing, acc, opts) do
    write = Keyword.get(opts, :write_dns_record, &Cloudflare.ensure_dns_record/5)

    case write.(scope, zone["id"], environment.host, ip, records: existing) do
      {:ok, response} ->
        record = dns_resource(environment.host, ip, response, environment.name)
        confirm_dns_record(environment, ip, record, acc, opts)

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  # A record that does not resolve fails this step, rather than passing it.
  #
  # `dns_verification/2` returned `[]` when the lookup found nothing and the
  # step reported done anyway — and there is no `verify(:dns, …)` clause, so
  # nothing downstream noticed either. The comment on that check already says a
  # record which exists in the dashboard and does not resolve is the classic
  # DNS failure; it was checked and then discarded.
  #
  # What that cost: the failure surfaced ten minutes later at `tls`, as a
  # certificate problem, on a host teardown was about to destroy. This step
  # states what it did, so it should be the one to say it did not work.
  defp confirm_dns_record(environment, ip, record, acc, opts) do
    case dns_verification(environment, opts) do
      [] -> {:halt, {:error, unresolved_record_message(environment, ip)}}
      verification -> {:cont, {:ok, acc ++ [record] ++ verification}}
    end
  end

  defp unresolved_record_message(environment, ip) do
    "#{environment.host} was written as an A record for #{ip}, but no public " <>
      "resolver returns it. Everything after this step reaches the name rather " <>
      "than the address, so none of it can work until the record resolves."
  end

  # Confirmed against a public resolver, not against our own write. A record
  # that exists in the dashboard and does not resolve is the classic DNS
  # failure, and it looks identical to success from the API's answer alone.
  defp dns_verification(environment, opts) do
    if Dns.resolves_publicly?(environment.host, :a, resolver_opts(opts)) do
      [
        %{
          kind: "dns_verification",
          location: environment.host,
          identifier: "source=resolver environment=#{environment.name}",
          origin: "created"
        }
      ]
    else
      []
    end
  end

  # Against the **zone**, not the receiving domain. Resend names its records
  # relative to the zone — for a receiving domain of `c8033.astralbi.com` in
  # zone `astralbi.com` it returns `c8033`, and qualifying that against the
  # receiving domain produced `c8033.c8033.astralbi.com`: created successfully,
  # reported done, and no mail ever routed. Found in the residue of a real run.
  #
  # The `qualify/2` doc has warned about this exact shape since it was written;
  # the sending records were fixed for it and this call was not.
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

  # Recording waits on DNS actually propagating; replay waits on nothing.
  # Deliberately NOT inheriting the step-wide `attempts`/`interval_ms`. Those
  # are sized for a provider verifying a domain, which can take minutes; a
  # record with a 60s TTL appears in a public resolver in seconds. Inheriting
  # them made a recording poll for five minutes per host and hold its database
  # connection the whole time, which surfaced later as an ownership error in
  # teardown — a failure with nothing to do with what the spex asserted.
  defp resolver_opts(opts) do
    opts
    |> Keyword.take([:resolver, :interval_ms])
    |> Keyword.put_new(:interval_ms, 2_000)
    |> Keyword.put(:attempts, Keyword.get(opts, :resolver_attempts, 15))
  end

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

  # Recorded so teardown can find it. Teardown works from what a step recorded,
  # so a network created and not recorded leaks by construction — and a leaked
  # private network holds a subnet that the next run's network cannot reuse.
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

  defp server_resource(server) do
    %{
      kind: "server",
      location: "hetzner/#{server["name"]}",
      identifier: get_in(server, ["public_net", "ipv4", "ip"]),
      origin: origin(server)
    }
  end

  # Providers mark what they reused. Absent the mark a resource reads as
  # created — these are the `ensure_*` paths, and the only way to reach one
  # without the mark is to have made the thing.
  #
  # `verify/3`'s `find_*` calls carry no mark either, so everything the verify
  # path reports reads `created` even though finding a thing is the opposite of
  # making it. That is deliberately left alone. `run_step/3` replaces the
  # recorded list from a satisfied verify — it is the answer read back from the
  # provider, so it overrules — and teardown skips anything marked `adopted`.
  # Stamping the verify path `adopted` would therefore relabel a server setup
  # genuinely created on the next page load that verified it, and teardown would
  # walk past a box it was responsible for. A mislabel costs a wrong word on a
  # page; the tidier-looking version costs a running server nobody removes.
  defp origin(%{"__adopted__" => true}), do: "adopted"
  defp origin(_), do: "created"

  # `Environments.cmd/4` raises :enoent when the executable is missing, so a
  # project without its deploy boilerplate crashed the whole run instead of
  # recording one errored step. Story 970's premise is that the boilerplate
  # arrives with the project; when it has not, the useful answer names the
  # missing file and why it matters, which is precisely what `Generators` was
  # built to say.
  defp require_script(scope, path) do
    case env(scope) do
      nil -> {:error, no_environment_message()}
      environment -> require_script_in(scope, environment, path)
    end
  end

  # Steps that shell out need somewhere to run. A cloud scope has no
  # environment — `Scope.environment` is only populated for local scopes — and
  # `Environments.cmd/4` answers a nil with a FunctionClauseError several
  # frames down, which reports as a crashed LiveView rather than one errored
  # step. Naming it is the difference between "this project has nowhere to run
  # commands" and a stack trace.
  defp no_environment_message do
    "this project has no working environment, so setup cannot run commands for it. " <>
      "The steps that shell out — the repository push, the deploy, and backups — need a " <>
      "checkout on a machine setup can reach."
  end

  defp require_script_in(scope, environment, path) do
    if Environments.exec_file_exists?(environment, path) do
      :ok
    else
      missing =
        scope
        |> CodeMySpec.Generators.audit(router_path(scope))
        |> Enum.map(&CodeMySpec.Generators.explain/1)

      detail =
        case missing do
          [] -> "#{path} is not present or not executable"
          findings -> Enum.join(findings, "; ")
        end

      {:error,
       "this project is not deploy-ready: #{detail}. " <>
         "The boilerplate ships with `cms new`; a project generated another way has to add it."}
    end
  end

  # `bin/deploy` refuses a dirty tree — correctly, since the image it ships is
  # versioned by commit SHA — and setup is what dirties it: the secrets step
  # writes `.sops.yaml` and `envs/<env>.enc.env`, encrypted precisely so they
  # can be committed. So every first run failed on files setup had just
  # written, naming them as if the user had left them lying around.
  #
  # Only setup's own paths are staged. Whatever else is in flight belongs to
  # whoever is working in that checkout, and a deploy that swept it into a
  # commit would be a worse failure than the one it is fixing — they stay
  # uncommitted, and `bin/deploy` still refuses, now naming files setup did
  # not write.
  defp commit_generated_configuration(scope) do
    environment = env(scope)

    paths =
      [".sops.yaml", "envs"]
      |> Enum.concat(Enum.map(DeployBoilerplate.manifest(), & &1.path))
      |> Enum.filter(&Environments.file_exists?(environment, &1))

    with true <- work_tree?(environment),
         {_, 0} <- git(environment, ["add", "--"] ++ paths),
         false <- nothing_staged?(environment) do
      commit_staged(environment)
    else
      # Nothing of ours changed, or there is no repository to change. Both are
      # ordinary, and neither is a failure.
      #
      # The no-repository case is not hypothetical: this runs before the build
      # so that `git archive HEAD` and `bin/deploy`'s `git rev-parse HEAD`
      # agree, and a deploy whose build is injected has no tree to archive at
      # all. Reporting `not a git repository` as a deploy failure took out all
      # seven criteria in story 992, none of which are about committing
      # anything.
      false -> :ok
      true -> :ok
      {output, status} -> {:error, "could not stage setup's files (#{status}): #{output}"}
    end
  end

  # `git add` in a non-repository fails the same way a real staging error does,
  # so the two have to be told apart before the exit status is read. The
  # repository step asks this same question the same way.
  defp work_tree?(environment) do
    match?({_, 0}, git(environment, ["rev-parse", "--is-inside-work-tree"]))
  end

  defp nothing_staged?(environment) do
    match?({_, 0}, git(environment, ["diff", "--cached", "--quiet"]))
  end

  # `-c user.*` because the box setup runs on need not have a git identity, and
  # "Please tell me who you are" is not a deploy failure anybody can act on.
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
    do: Environments.cmd(environment, "git", args, stderr_to_stdout: true)

  # The keypair is generated here and the private half never leaves
  # ProjectSecrets — same argument as the age keys, and for the same reason:
  # whatever has to reach this box later reads it from there rather than from
  # a file somebody has to remember to protect.
  #
  # Generated rather than reusing the operator's own key, because setup runs on
  # our machines in the hosted case and the operator's laptop key is not there
  # to reuse.
  defp ensure_access_key(scope, name) do
    with {:ok, public} <- access_public_key(scope, name) do
      Hetzner.ensure_ssh_key(scope, name, public)
    end
  end

  # Account first, then the project. The key has to open every box the account
  # owns, including one created from `/app/servers` that belongs to no project
  # — a per-project key would lock a later deploy out of a box it can see. The
  # project read stays for installs that generated one before the account
  # grain existed.
  defp access_public_key(scope, name) do
    with :error <-
           stored_public_key(fn -> AccountSecrets.fetch_value(scope, @access_key_public) end),
         :error <-
           stored_public_key(fn -> ProjectSecrets.fetch_value(scope, @access_key_public) end) do
      generate_access_key(scope, name)
    end
  end

  defp stored_public_key(read) do
    case read.() do
      {:ok, public} when is_binary(public) and public != "" -> {:ok, public}
      _ -> :error
    end
  rescue
    _ -> :error
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

          # Written at the account grain to match where it is read from, so
          # one key opens every box the account owns.
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

  defp site_url(scope) do
    case domain(scope) do
      nil -> nil
      name -> "https://#{name}"
    end
  end

  defp router_path(scope) do
    app = Map.get(project(scope), :module_name) || "App"

    "lib/#{app |> to_string() |> Macro.underscore()}_web/router.ex"
  end

  # Receiving is at the **apex**, and that is a decision rather than a default:
  # story 969 owns the `send` subdomain MX for outbound, 974 owns the apex MX
  # for inbound, and the two must not fight. `Resend.inbound_records/2` already
  # selects apex records on that basis.
  #
  # Resend's own guidance is to prefer a subdomain, because enabling inbound
  # captures every address at the name. That is the right advice for a domain
  # whose owner also reads mail there, and it is not this case: the whole point
  # of 974 is that the app receives the domain's mail and acts on it.
  #
  # `:inbound_subdomain` is still honoured so a project that does read mail at
  # its apex can move inbound aside.
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

  # Where Resend POSTs a received message. Criterion 8048 is about the app
  # being able to act on the mail, which needs the delivery to reach the app
  # rather than a mailbox somewhere.
  defp webhook_endpoint(scope, opts) do
    Keyword.get(opts, :webhook_endpoint) ||
      "https://#{Keyword.get(opts, :app_host) || domain(scope)}/webhooks/resend"
  end

  # The MX Resend hands back, published at the priority it specifies. Resend
  # only receives when its MX is the lowest priority for the name, so the
  # value is copied from the provider rather than chosen here.
  defp publish_mx(scope, name, domain, opts) do
    # Re-read the domain, for the same reason `sending_records_for/2` does:
    # `/domains` omits `records` entirely, and `ensure_receiving_domain/3`
    # returns whatever `find_domain/2` found — which came from the list. So an
    # *adopted* domain carried no records, `mx_records/1` saw none, and the step
    # reported that Resend had not asked for an MX on a domain whose MX it will
    # name happily when asked by id. A freshly created domain does carry them,
    # which is why this only failed on the second run over the same domain.
    case Resend.mx_records(inbound_records_for(scope, domain)) do
      [] ->
        {:error,
         "Resend returned no MX record for #{name}, so there is nothing to publish — " <>
           "the domain cannot receive mail without one"}

      records ->
        base = base_domain(scope, opts)

        with {:ok, zone} <- Cloudflare.find_zone(scope, base) do
          Enum.reduce_while(records, {:ok, []}, &publish_mx_record(&1, &2, scope, zone))
        end
    end
  end

  # Resend names records relative to the **zone**, not to the domain they
  # belong to. For a receiving domain of `mail.example.com` in zone
  # `example.com` it returns `name: "mail"`, and for a receiving domain that
  # is the zone apex it returns `name: ""` — not nil, so `|| domain` does not
  # catch it either.
  #
  # Qualifying against the receiving domain therefore produces
  # `mail.mail.example.com`: created successfully, reported done, and it will
  # never receive mail. Found live; both halves of this were wrong.
  defp qualify(nil, domain), do: domain
  defp qualify("", domain), do: domain
  defp qualify("@", domain), do: domain
  defp qualify(name, domain), do: "#{name}.#{domain}"

  # The zone the MX is published into — the registrable domain, not the
  # receiving subdomain. Both names are read because `receiving_domain/2`
  # derives `mail.<base>` from the same value, and having one read `:domain`
  # while the other read `:inbound_domain` looked up a nil zone and failed
  # with a bare `:not_found` pointing nowhere near the cause.
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

  defp confirmation_message(name) do
    "#{name} is available. Registering it costs money and is not refundable, " <>
      "so setup will not buy it without an explicit confirmation."
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
         :ok <- Sops.write_config(env, recipients),
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

  # The key the deployed app authenticates back with, minted here and written
  # into every environment's encrypted env as `DEPLOY_KEY`.
  #
  # Nothing in the sequence used to write it, and three steps read it: `content`
  # and `widget` both refuse without it, and `content` also wants
  # `content_bucket` and `client_api_url`. A project that had never opened the
  # content settings form therefore could not finish setup at all — and since a
  # project that has never chosen options gets every option, that was the
  # default. The run reported `the widget step needs a deploy key, and this
  # project has none set` on a plan nobody had customised.
  #
  # Minted at the secrets step rather than at `callback_credential`, which is
  # the other step that places a shared secret in the encrypted env, for two
  # reasons. It sits at position 14, after both steps that need the value; and
  # the client reads `DEPLOY_KEY` from its own environment at boot, so a key
  # minted after the deploy would not reach the running app until the next one.
  #
  # Only when absent, like `SECRET_KEY_BASE` above: rotating on a re-run would
  # break a deployed app that is already authenticating with the old one.
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
      case put_secret(scope, environment, "DEPLOY_KEY", key) do
        {:ok, _} ->
          resource = %{
            kind: "secret",
            location: "#{environment}/DEPLOY_KEY",
            identifier: "generated=true"
          }

          {:cont, {:ok, acc ++ [resource]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # SECRET_KEY_BASE is entropy, not a decision, so setup mints it here rather
  # than halting the deploy to ask for a value nobody chooses. DATABASE_URL,
  # the other required secret, is genuinely knowable only once a database
  # exists, and `serve_database/4` writes it there.
  #
  # Only when absent. Rotating on a re-run would invalidate every signed
  # cookie and session the deployed app had issued — the same trap `key_for/2`
  # documents above, and `secrets_verify_test.exs` holds this to it.
  defp seed_secret_key_base(scope, env, recipients) do
    Enum.reduce_while(recipients, {:ok, []}, fn {environment, _public}, {:ok, acc} ->
      case secret_key_base_missing?(scope, env, environment) do
        {:ok, false} -> {:cont, {:ok, acc}}
        {:ok, true} -> mint_secret_key_base(scope, environment, acc)
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Present, as far as this can honestly tell.
  #
  # Anything that is not a clear "the file opens and the key is not in it" reads
  # as present. A missing age key, sops unavailable, an unreadable file — none of
  # those are evidence the database went away, and treating them as such would
  # re-serve a database and rewrite a connection string on the strength of a
  # local tooling failure. The secrets step is what reports a key that cannot
  # open its own file, and it says so in its own words.
  defp database_url_present?(scope, environment) do
    # Nothing here can tell without sops, and without sops nothing works
    # anyway — the deploy cannot read the file either. Re-running the server
    # step on every page load of a machine that lacks the binaries would be a
    # rebuild triggered by a missing tool.
    if Sops.available?() do
      with {:ok, private} <- fetch_age_key(scope, environment),
           {:ok, missing} <-
             Sops.missing_secrets(env(scope), environment, private, ["DATABASE_URL"]) do
        "DATABASE_URL" not in missing
      else
        # Anything short of proof that the value is there counts as absent.
        #
        # This read the other way first — a file that would not open was
        # "present", on the reasoning that a local failure is not evidence the
        # database went away. True, and beside the point: the consequence of an
        # unopenable file is identical to an absent value, because the app
        # cannot read `DATABASE_URL` out of it either. The charitable reading
        # made the step report done and the deploy fail two steps later, which
        # is the failure this check was added to prevent.
        _ -> false
      end
    else
      true
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

  # An environment's key is only replaced when the one on record cannot read
  # what it encrypted. Minting unconditionally made the secrets step destroy
  # data every time it ran: `.sops.yaml` was rewritten to fresh recipients
  # while the `.enc.env` files stayed encrypted to the old ones, whose private
  # halves had just been overwritten in `ProjectSecrets`. Nothing could open
  # them again, by anyone, ever.
  #
  # Re-running is not an edge case here — it is the whole shape of setup, and
  # the step re-runs whenever *any* environment needs attention. So adding a
  # second environment to a working project destroyed the first's secrets, and
  # a drill hit it on the ordinary path: cycle 1 encrypted to one key, cycle 2
  # rewrote the config to two new ones, and the deploy failed with "no
  # identity matched any of the recipients".
  #
  # `ensure_age_key/3` already had this right for `put_secret/4`; the step was
  # the one place that reached for `generate_key/0` directly.
  #
  # Genuine drift still mints — a key that no longer opens its file cannot
  # recover the contents, so replacing it is the only way forward and is what
  # makes the repair path in `verify(:secrets, ...)` work.
  defp key_for(scope, env, environment) do
    with true <- key_opens_its_own_file?(scope, environment),
         {:ok, private} <- ProjectSecrets.fetch_value(scope, age_key_name(environment)),
         {:ok, public} <- Sops.public_key(private) do
      {:ok, public}
    else
      _ -> mint_key(scope, env, environment)
    end
  end

  # Minting a fresh key leaves the old `.enc.env` encrypted to a recipient
  # whose private half no longer exists anywhere, so the file is unreadable by
  # anyone forever — and leaving it in place made the repair never converge:
  # `key_opens_its_own_file?/2` stayed false against it, `verify/3` kept
  # reporting absent, and every re-run minted another key over the same dead
  # file.
  #
  # Discarding it is not a choice to lose data. The data is already lost; this
  # only stops the project from being permanently undeployable because of it.
  # The next `put_secret/4` recreates the file against the new recipient, and
  # `seed_secret_key_base/3` puts a working boot secret back into it.
  defp mint_key(scope, env, environment) do
    with {:ok, {public, private}} <- Sops.generate_key(),
         {:ok, _} <- ProjectSecrets.put_value(scope, age_key_name(environment), private) do
      discard_unreadable_env(env, environment)
      {:ok, public}
    end
  end

  defp discard_unreadable_env(env, environment) do
    path = Sops.env_file(environment)

    case Environments.file_exists?(env, path) do
      true ->
        Logger.warning(
          "[Secrets] #{environment}'s encrypted env was written to a key that no longer " <>
            "exists — discarding #{path}, its contents cannot be decrypted by anyone."
        )

        Environments.delete_file(env, path)

      _ ->
        :ok
    end
  end

  @doc """
  Set one secret in an environment's encrypted file.

  Public because the setup page offers it: criterion 7997 is that a value Sam
  types lands in the repo as ciphertext, and that is only observable if there
  is somewhere to type it. The plaintext goes to `sops set` as an argument and
  is never written to the working tree.
  """
  @spec put_secret(Scope.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def put_secret(%Scope{} = scope, environment, key, value) do
    env = env(scope)

    with {:ok, private} <- ensure_age_key(scope, env, environment),
         :ok <- Sops.put_secret(env, environment, key, value, private) do
      {:ok, %{environment: environment, key: key, file: Sops.env_file(environment)}}
    else
      {:error, reason} -> {:error, to_string_reason(reason)}
    end
  end

  # Mints the environment's key if it has none rather than refusing. Making
  # this depend on the secrets step having run first is an ordering trap: the
  # error tells Sam to go and run something else, and the thing it tells him
  # to run is the thing this would have done.
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

  # The config names every environment's recipient, so writing one
  # environment's key must not drop another's.
  defp write_recipients(scope, env, environment, public) do
    others =
      for %{environment: e, fingerprints: [fp | _]} <- recipients(scope, ["prod", "uat"]),
          e != environment,
          into: %{},
          do: {e, fp}

    Sops.write_config(env, Map.put(others, environment, public))
  end

  @doc "The age recipients each environment's encrypted file names."
  @spec recipients(Scope.t(), [String.t()]) :: [
          %{environment: String.t(), fingerprints: [String.t()]}
        ]
  # A scope with no environment has no repository to read, which is an answer
  # rather than an error — the page renders for a cloud scope too.
  def recipients(%Scope{environment: nil}, _environments), do: []

  def recipients(%Scope{} = scope, environments) do
    env = env(scope)

    for environment <- environments,
        {:ok, keys} <- [Sops.recipients(env, environment)],
        keys != [] do
      %{environment: environment, fingerprints: keys}
    end
  end

  defp fetch_age_key(scope, environment) do
    case ProjectSecrets.fetch_value(scope, age_key_name(environment)) do
      {:ok, key} when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :not_found}
    end
  end

  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(reason), do: inspect(reason)

  defp age_key_name(environment), do: "age_private_key_#{environment}"

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

  # Transport failures in words. `inspect/1` is the right default for a term
  # nobody anticipated, and the wrong one for the two failures that show up
  # here constantly: a struct reached the setup page reading
  # `%Finch.TransportError{reason: :econnrefused, source: %Mint.TransportError{…}}`
  # — the same reason twice, nested, with the actionable half buried inside and
  # the layout truncating it mid-word.
  #
  # `:econnrefused` and `:nxdomain` are exactly the two states the surrounding
  # advice is already about, so saying them plainly makes the sentence answer
  # its own question.
  defp format(%{reason: reason}) when is_atom(reason), do: format_transport(reason)
  defp format({:error, reason}), do: format(reason)
  defp format(reason) when is_atom(reason), do: format_transport(reason)

  # `printable_limit: :infinity`, because the default cuts a binary at 4096
  # characters and appends `<> ...` — and for the errors that carry a build
  # log, everything worth reading is at the *end*. A failing `docker build`
  # reported nine thousand characters of apt-get output and then
  # `"Building depe" <> ...`, so the reason it failed was removed by the
  # formatter rather than never produced. Two drills were spent looking for it
  # elsewhere.
  #
  # `limit: :infinity` for the same reason one level up: the log arrives inside
  # a tuple, and the default also truncates the container's elements.
  defp format(reason), do: inspect(reason, printable_limit: :infinity, limit: :infinity)

  defp format_transport(reason), do: Transport.describe(reason)
end
