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

  alias CodeMySpec.{
    AccountSecrets,
    Configurations,
    Conversations,
    Deploys,
    Environments,
    Projects,
    ProjectSecrets
  }

  alias CodeMySpec.Generators.DeployBoilerplate
  alias CodeMySpec.Repo
  alias CodeMySpec.Servers.Server
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

  # Where the backup script and the encrypted env are delivered on the
  # environment's own box. Fixed rather than per-run: the nightly systemd unit
  # `bin/backup schedule` installs names it as its WorkingDirectory, so a path
  # that changed every run would leave the timer pointing at a deleted tree.
  @backup_dir "/opt/cms-backup"

  @type outcome ::
          {:ok, [map()]}
          | {:paused, String.t()}
          # Paused, but something real was made first — a sending domain
          # registered while it verifies, a widget installed while it waits for
          # its first message. `run_and_record/4` records these for the same
          # reason it records a failure's: a pause that dropped them would leak.
          | {:paused, String.t(), [map()]}
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
    #
    # The registry is the fourth instance of the identical shape, named as
    # such in c1d8eaff: `run/3` is what starts it (`serve_one_registry/5`),
    # so `run/3` is the only place that ever finds out it did not come up.
    # Reproduced live — a box created by a run that errored before
    # provisioning still carried `DATABASE_URL` left over from a previous
    # domain's checkout, so both cheap checks above passed, `run/3` was
    # skipped, and the failure surfaced two steps later at `deploy` as a
    # bare connection refused that never named the registry.
    #
    # Checked last and only when the cheap checks already agree: a curl
    # through SSH costs real time per environment, and a project with no box
    # yet has nothing worth reaching for it — `found != []` above already
    # answers that case for free. Run on every verify rather than only for a
    # box this walk just created, because the reproduced failure is a box
    # from an *earlier* run — nothing about this walk would distinguish it.
    if length(found) == length(environments) and found != [] and
         Enum.all?(environments, &database_url_present?(scope, &1)) and
         registries_reachable?(scope, name, environments, opts) do
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

  # There was no `verify(:dns, …)` clause, so dns fell to the catch-all at the
  # bottom and always reported absent. A step whose records existed and
  # resolved therefore read `not_started` after any page load — the mount
  # re-verifies, and `{:ok, :absent}` overwrote a perfectly good `done` without
  # asking Cloudflare anything (44905320).
  #
  # Criterion 2007 is "a step's state is checked against the provider, not
  # remembered", and assumed-absent is neither. It also made a provisioned
  # project indistinguishable from an untouched one for this step, and left the
  # readback claiming records under a step that said it had never run.
  #
  # Asked of the zone rather than of a resolver. The step already confirms
  # publication when it writes, and what verify needs to know is narrower and
  # cheaper: does the record Cloudflare holds still point where this project
  # put it. One zone lookup and one record list, whatever the environment
  # count.
  def verify(:dns, %Scope{} = scope, _opts) do
    case {domain(scope), pointable_environments(scope)} do
      {nil, _} -> {:ok, :absent}
      # No environment has an address yet, so there is nothing dns could have
      # written. Absent rather than satisfied: the server step has not run.
      {_domain, []} -> {:ok, :absent}
      {domain, environments} -> verify_dns_records(scope, domain, environments)
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
    # `Enum.all?/2` on an empty list is `true` — a project whose devops level
    # filtered out every environment row it has would otherwise read
    # "satisfied" for a set of zero environments, none of which anything was
    # ever checked against. `environments != []` closes that off the same way
    # `verify(:server, …)`'s `found != []` guard does for the same shape of
    # bug (402f9439): the devops-drill project has a `prod` row and
    # `devops: :uat`, `permitted_environment_rows/1` filters `prod` out, and
    # this reported every one of zero environments satisfied.
    case environments != [] and Enum.all?(environments, &secrets_ready?(scope, &1)) do
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
        #
        # Through the same injectable probe `run(:tls, …)` uses, rather than
        # `Deploy.probe/2` directly. `run_step/3` verifies before it executes,
        # so a spex that staged a probe for the run still met the real client
        # here — and the run never happened, because verify raised first. Three
        # criteria failed that way (965/7996, 966/8006 and 8010), each
        # reporting `no mock or stub for CodeMySpec.Provisioning.Deploy` from a
        # step whose probe was staged two lines earlier.
        probe = Keyword.get(opts, :probe, &Deploy.probe/2)

        case probe.(h, opts) do
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
      # So a proof a previous run recorded **for this domain** is what satisfies
      # this. Absent one, the step runs and proves it.
      #
      # For *this* domain's current incarnation, not merely its name. A full
      # teardown-and-rebuild deletes the Resend domain object and creates a
      # new one at the same name — new DKIM, new MX, receiving nothing has
      # proven yet — and `proof_on_domain?/2` alone cannot tell that apart
      # from the one the proof was earned against. One level deeper than the
      # domain-name check: a proof stamped for a Resend domain id that no
      # longer answers to this name is treated the same as no proof at all,
      # the same way a rebuilt environment's stale proof once certified a
      # receiving setup that had just failed ten minutes earlier (1040172a).
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
    else
      # Anything short of "receiving domain plus an ENABLED webhook" is absent.
      # A disabled webhook is the case worth being strict about: it looks
      # configured from every angle except the one that counts.
      _ ->
        {:ok, :absent}
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
        |> record_content_bucket(scope, credentials, opts)
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

    with :ok <- storage_credentials_ready(scope, opts),
         {:ok, firewall} <- Hetzner.ensure_firewall(scope, name),
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

          # `register_domain/3`'s `:confirmation_required` is never reachable
          # here as an actual confirm-then-buy round trip — `opts` never
          # carries `confirmed: true` on this path, so the atom always means
          # the same thing: the account does not hold `name`, and the
          # Registrar API cannot sell it one it doesn't already have. That is
          # an errand for Sam, not a decision for setup to wait on, so it
          # still pauses (`resume/2` re-verifies rather than assuming he
          # bought it) — only the message was wrong about what it was
          # pausing for.
          {:error, :confirmation_required} ->
            {:paused, not_owned_message(name)}

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
         # `[_ | _] =`, not a bare bind: `dns_records_for/4` over an empty
         # list is `Enum.reduce_while([], {:ok, []}, …)`, which returns
         # `{:ok, []}` having asked Cloudflare for nothing — done, with no
         # record published. `permitted_hosts/2` is empty only when every
         # environment row is filtered out by the project's devops level
         # (402f9439), never because the server step merely hasn't run yet —
         # that case is `pointable_environments/1`'s, checked by `verify/3`.
         [_ | _] = environments <- permitted_hosts(scope, name),
         {:ok, resources} <- dns_records_for(scope, zone, environments, opts) do
      record_client_api_url(scope, environments, opts)
      {:ok, resources}
    else
      nil ->
        {:error, "no domain set on the project"}

      [] ->
        {:error, no_permitted_environments_message(scope)}

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
    # `base_domain/2` rather than `domain/1`, so this reads the same value its
    # neighbours do. Reading the project directly meant a caller that narrowed
    # every other step to one domain had this one still working from the
    # project's — two domains in one run, each believing it was the only one.
    case {base_domain(scope, opts), mail_environments(scope, opts)} do
      {nil, _} -> {:error, "no domain set on the project"}
      {base, []} -> run_no_permitted_mail_environments(scope, base)
      {base, environments} -> register_sending_domains(scope, base, environments, opts)
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
    # `ContentPublishing.run/2` already computes everything story 972 asks
    # about — which objects landed in whose bucket, what the live site returned
    # for the post's path, when it was proven. Collapsing all of it to
    # `%{kind: "content", location: "published and rendered"}` meant the page
    # had nothing to show and the criteria had nothing to read, which is why
    # every one of them selected on markup that could not exist.
    #
    # Shaped like `inbound_proof` and `restore_proof`: the claim in `kind`, the
    # thing it is about in `location`, and the evidence in `identifier`.
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
    # `Widget.run/3` requires both and says so with `fetch!`, which is the
    # right contract for a module that cannot do anything useful without them.
    # Supplying them is this adapter's job — letting the KeyError escape turns
    # a missing domain into a crashed run instead of one errored step.
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

        # Installed and openable, with no message yet: waiting on a person, not
        # broken. The proof this step wants is a message *from the deployed
        # site*, which only a visitor's browser can send — `message_proof/2`
        # looks for one and nothing in the sequence can manufacture it, so on a
        # site nobody has used yet this errored forever and took the run with
        # it.
        #
        # Paused rather than errored, the same shape as the storage step
        # waiting for console-only keys. It still does not report done — the
        # widget is not
        # proven until a message arrives, and resuming re-checks (7967) — but a
        # run stops calling a working install a failure.
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

    # `Enum.reduce_while([], …)` inside `generate_keys/3` returns `{:ok, %{}}`
    # without minting anything, and the step reported `{:ok, []}` — done,
    # having done nothing — for the same reason `verify/3` above needs its own
    # guard: an empty environment list is not zero work remaining, it is every
    # environment this project has being filtered out from under it.
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
    # Issuance is kamal-proxy's job during deploy; this step verifies it
    # actually happened. A certificate nobody checked is a certificate that
    # fails on a visitor rather than during setup. The probe is injectable so a
    # spex can verify the recording without a live host.
    probe = Keyword.get(opts, :probe, &Deploy.probe/2)

    case tls_targets(scope, opts) do
      :no_domain ->
        {:error, "no domain set on the project — nothing to issue a certificate for"}

      # `Enum.filter([], …)` on an empty `permitted_hosts/2` reads exactly
      # like a project with no domain — both are `[]` — and 402f9439's own
      # shape: devops-drill has a `prod` row and `devops: :uat`, so the
      # project's *only* environment is filtered out, `permitted_hosts`
      # returns nothing, and this reported "no domain set" for a project
      # whose domain was confirmed set (b45f7ff8). Named separately so the
      # message points at the actual gap instead of sending the reader to
      # re-check a domain that was never the problem.
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
         {:ok, secret_resources} <- seed_webhook_secret(scope, webhook),
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

      # 22b0e27c: a name already has an MX pointing somewhere Resend did not
      # just hand back, and `ensure_dns_record/5` would replace rather than
      # add to it. Paused the same way `apex_repoint/4` is — a decision only
      # Sam can make, not a failure to retry.
      {:error, {:competing_mx, record_name, current}} ->
        {:paused,
         "#{record_name} already has an MX record pointing at #{current}, and publishing " <>
           "Resend's here would replace it rather than add alongside it — if mail for this " <>
           "name already routes through #{current}, that redirects or breaks it silently. " <>
           "Confirm to publish anyway, or resolve it at the provider first."}

      # Paused, because the likeliest cause is a thing only a person can do and
      # nothing here can rule it out.
      #
      # Resend delivers only to addresses configured for the domain, offers no
      # API to ask which those are, and drops the rest in silence — so an
      # unconfigured address produces exactly this, and so does a genuinely
      # broken webhook. The two branches above already pause for the address
      # being absent or on another domain; this is the same question one step
      # later, and answering it "failed" put a ten-minute error at the end of
      # every run whose only remedy was in a dashboard.
      #
      # It still does not report done: the inbox is unproven until a message
      # arrives, and resuming re-sends and re-checks (7967).
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

    case Storage.credentials(scope, opts) do
      :none ->
        # Hetzner issues object-storage keys in the console and nowhere else,
        # so there is no call to make here. Pausing states the real limit and
        # re-checks on resume rather than pretending it can be automated.
        {:paused, Storage.credentials_instructions()}

      {:ok, credentials} ->
        environments
        |> Enum.reduce_while({:ok, []}, &ensure_bucket_for(&1, &2, project, credentials, opts))
        |> record_content_bucket(scope, credentials, opts)
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
            |> put_database_url(scope, environment)

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

  # `Content.PullClient` (generated by `cms_gen.content`) reads the manifest
  # and blob back with the deployed app's own S3 credentials — deliberately,
  # so the bucket never has to be world-readable for the handoff to work
  # (see the template's own moduledoc). Nothing delivered those credentials
  # to the deployed app: `write_content_bucket/3` sets `aws_access_key_id` /
  # `aws_secret_access_key` / `s3_endpoint` / `aws_region` on the *project*
  # row for this backend's own signing, but a generated app has no route to
  # that row. Its `Content.S3Client` fell back to ExAws's bare defaults —
  # `s3.amazonaws.com`, EC2 instance-identity auth — and hung for 30s against
  # a host that was never going to answer before crashing the pull. From
  # outside that reads exactly like "published but not served", with no
  # trace of why.
  #
  # Same four values the write side already resolved, carried the same way
  # `callback_credential` carries its own secret: through the encrypted env,
  # never typed in by hand. Best-effort — a project with no S3 credentials
  # yet already paused earlier in the sequence, so this has nothing to send.
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
    # Bare host, not the `https://`-prefixed value `write_content_bucket/3`
    # stores on the project row — ExAws's `:host` option is composed with a
    # separate `:scheme`, and a value carrying both would double up.
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

  # What the render proof will fetch back, what has to be in it, and where to
  # fetch it from. `verify_render/2` reads `:path`/`:expect` with `fetch!` —
  # correctly, since it can prove nothing without them — and `:site_url` falls
  # back to `published.site_url`, which nothing sets either. Every one of the
  # three was missing here, and the step died with `key :path not found` on a
  # run where every step before it had succeeded and the site was live.
  # Supplying them is this adapter's job, the same argument the widget step
  # below makes about its own two.
  #
  # `:path` and `:expect` are derived from the content itself rather than
  # configured: the post that will be published is the post to ask the site
  # for. `/<content_type>/<slug>` is what `cms_gen.content` routes, and the
  # title is what a rendered post certainly contains — a 200 alone would pass
  # on a styled 404. `:site_url` is the same `client_api_url` the pull trigger
  # already posts to — the deployed app answers the reader-facing routes on
  # the same host it answers the publishing endpoints on.
  #
  # A project with no content is the ordinary state of a freshly generated
  # application, not a failure. There is nothing to publish and nothing to
  # prove, and saying so is the honest answer; erroring would make every new
  # project's first setup report a broken step it cannot fix by trying again.
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

  # `content_bucket` is not a field Sam types in — `write_content_bucket/3`
  # sets it as a side effect of the storage step finding or creating a
  # bucket, which for a Hetzner project waits on his console-only key pair
  # the same way `run(:storage, ...)` itself pauses. Reporting this step
  # `:done` with "no content to publish yet" when the bucket is unset would
  # hide that storage is the thing actually still waiting on him — the
  # `:email` step's fix for the same silently-vacuous shape.
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

  # Fully qualified: the `ContentPublishing` aliased above is
  # `Provisioning.ContentPublishing`, which orchestrates the publish. The
  # snapshot rows belong to the context of the same name one level up, and
  # aliasing both here would make every call site ambiguous to a reader.
  defp publishable_content(scope) do
    scope
    |> CodeMySpec.ContentPublishing.list_snapshot()
    |> Enum.filter(
      &(&1.parse_status == :success and (&1.metadata || %{})["slug"] not in [nil, ""])
    )
  end

  defp publish_content(scope, opts) do
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
  defp record_content_bucket({:ok, :satisfied, _resources} = outcome, scope, credentials, opts) do
    write_content_bucket(scope, credentials, opts)
    outcome
  end

  defp record_content_bucket({:ok, _resources} = outcome, scope, credentials, opts) do
    write_content_bucket(scope, credentials, opts)
    outcome
  end

  defp record_content_bucket(other, _scope, _credentials, _opts), do: other

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
  defp write_content_bucket(scope, credentials, opts) do
    project = project(scope)
    location = Keyword.get(credentials, :region) || Keyword.get(opts, :location, "fsn1")

    with true <- blank?(Map.get(project, :content_bucket)),
         environment when is_binary(environment) <- primary_environment(scope, opts) do
      Projects.update_project(scope, project, %{
        content_bucket: Storage.bucket_name(project, environment),
        s3_endpoint: "https://#{location}.your-objectstorage.com",
        aws_region: location,
        # The same keys this step just used to make the bucket.
        #
        # They live in two places for two readers: `ProjectSecrets` holds
        # `hetzner_s3_*` for provisioning, and the project row holds `aws_*` for
        # publishing, which signs per-request without a global :ex_aws config.
        # Nothing copied one to the other, so publishing presented no key at all
        # and Hetzner answered `InvalidAccessKeyId` — a 403 about credentials,
        # for a bucket this step had made with credentials that worked.
        #
        # Named `aws_*` and not AWS-specific; the comment on
        # `ContentPublishing.aws_credentials/1` says so and had already fixed
        # the endpoint half of this exact problem.
        aws_access_key_id: Keyword.get(credentials, :access_key_id),
        aws_secret_access_key: Keyword.get(credentials, :secret_access_key)
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

  # Production sends mail. Nothing else does.
  #
  # Every environment used to get its own verified sending domain, on the
  # reasoning that reporting done with production verified and UAT missing hides
  # the gap that lets a test message go out looking like a real one. The
  # stronger form of that argument is that UAT should not be able to send mail
  # at all: the failure worth preventing is a staging box mailing real
  # customers, and a verified `uat.<domain>` is what makes that possible.
  #
  # It also unblocks inbound, without inbound needing to know about it.
  # `Resend.sending_domain/2` maps production to the apex, so production's
  # sending records are the apex's — which is the domain the inbound step
  # receives on. Without them the apex carries only a Receiving MX, sits at
  # `pending`, and Resend bounces mail to it however verified that one record
  # is. Measured: a probe to a pending domain bounced while the same probe to a
  # fully verified one was delivered.
  #
  # Deliberately not applied to the inbound step itself. Making that a no-op
  # without production would have it report satisfied having proved nothing,
  # which is the failure `verify(:inbound, …)` already refuses for a configured
  # domain with no delivery proof — criterion 8033 exactly.
  defp mail_environments(scope, opts) do
    Enum.filter(environments(scope, opts), &(&1 in ["prod", "production"]))
  end

  # `mail_environments/2` filters to the *permitted* prod-shaped rows, so an
  # empty list means either nothing has ever touched Resend for this project,
  # or the devops level narrowed after something already had (4dc83128: a
  # project provisioned with prod on, then switched to `devops: :uat`, kept a
  # real Resend domain object sitting unverified/failed while every later run
  # skipped it entirely — the page's own live Resend read showed "failed" next
  # to a step badge that had reported "done"). One `find_domain` call per
  # otherwise-filtered row, same cost `verify_sending_domains/3` already pays
  # when the row is permitted.
  defp mail_orphans(scope, base) do
    for environment <- EnvironmentRepository.names(scope),
        environment in ["prod", "production"],
        sending = Resend.sending_domain(base, environment),
        match?({:ok, _}, Resend.find_domain(scope, sending)) do
      sending
    end
  end

  # Verify's half: satisfied only when nothing was ever registered anywhere.
  # An orphan is not satisfied — reporting it that way is exactly the
  # false-positive 4dc83128 found live — so `run_step/3` falls through to
  # `run(:email, …)` instead of marking this step done unchecked.
  defp verify_no_permitted_mail_environments(scope, base) do
    case mail_orphans(scope, base) do
      [] -> {:ok, :satisfied, []}
      _orphans -> {:ok, :absent}
    end
  end

  # Run's half, reached only because verify above found an orphan (a clean
  # project never gets here — verify already reported satisfied). Nothing
  # here can register a domain the devops level now refuses, and nothing here
  # should silently discard the fact that one already exists, so this pauses
  # by name rather than the `{:ok, []}` no-op done was standing in for.
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
      Enum.all?(minted_secrets(), &present?(scope, environment, &1))
  end

  # Everything `generate_keys/3` puts in the encrypted env, listed once.
  #
  # Third time this has bitten. `run_step/3` verifies before it executes, so a
  # value the check does not know about is a value nothing ever writes: the step
  # reports done and the failure surfaces steps away. `DATABASE_URL` did it,
  # then `DEPLOY_KEY`, then `CODEMYSPEC_WIDGET_URL` — which verified satisfied
  # in 0.0s and left the deployed application pointed at nothing while setup
  # said the secrets were in place.
  #
  # A list, so adding a secret to the step adds it to the check by construction
  # rather than by anyone remembering to.
  defp minted_secrets, do: ["DEPLOY_KEY", "CODEMYSPEC_WIDGET_URL"]

  defp present?(scope, environment, name) do
    with {:ok, private} <- fetch_age_key(scope, environment),
         {:ok, missing} <- Sops.missing_secrets(env(scope), environment, private, [name]) do
      name not in missing
    else
      _ -> true
    end
  end

  # Absent only when the file opens and the value is not in it. Anything this
  # cannot read — no age key, no sops — is somebody else's error to report, and
  # `key_opens_its_own_file?/2` above reports it in its own words.
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
  # The proof a previous run recorded **for this domain**, as a plain map.
  #
  # Filtered on the address, because a proof is about one inbox and the step row
  # outlives the domain. Pointed at a new domain, the row still held
  # `inbound_proof inbox@spex-drill.legwork.ca` from a torn-down one, and
  # `verify/3` reported satisfied in 0.2s — earwitness's receiving domain and
  # webhook listed beside legwork's proof, with nothing having been proven about
  # the inbox that was actually being set up. That is proof by residue, which is
  # what `send_and_await/4` identifies the arriving message by id to avoid.
  #
  # `Step` embeds its resources, so what comes back is a `%Resource{}` struct,
  # and handing one to `verify/3` puts it on the path to
  # `cast_embed(:resources)` — which wants params and raises `expected params to
  # be a :map`.
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

  defp plain_resource(%CodeMySpec.Provisioning.Resource{} = resource),
    do: Map.from_struct(resource)

  defp plain_resource(resource), do: resource

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
      " " <>
      acme_path_observation(target.host, probe, opts) <>
      " " <>
      dns_observation(target.host, reason, opts) <>
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
  defp prove_delivery(scope, name, domain_id, opts) do
    probe = Keyword.get(opts, :inbound_probe, &default_inbound_probe/3)
    # Carried through opts rather than added to the probe's own arity, so an
    # injected probe — the shape a spex stages — keeps the three-argument
    # contract `prove_delivery/4` has always offered it.
    probe.(scope, name, Keyword.put(opts, :resend_domain_id, domain_id))
  end

  defp default_inbound_probe(scope, _name, opts) do
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
    case Keyword.get(opts, :inbound_probe_to) do
      to when is_binary(to) and to != "" ->
        with {:ok, message} <- send_and_await(scope, to, token, opts) do
          {:ok, inbound_proof(to, message, Keyword.get(opts, :resend_domain_id))}
        end

      _ ->
        {:error, :no_probe_address}
    end
  end

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

    # Before sending, or the step cannot recover from its own first failure.
    # A probe that bounced — which is what the first one does on a domain whose
    # receiving is not verified yet — puts this address on the account's
    # suppression list, and every later send to it is dropped before delivery.
    # The step then reports "the message never arrived" forever, which is true
    # and which no amount of fixing the configuration changes.
    #
    # Measured on the drill: two cold rebuilds failed, and
    # `inbox@spex-drill.earwitness.app` was suppressed with `origin: "bounce"`
    # timestamped at the first of them.
    #
    # Ignored rather than checked, because there is usually nothing to clear
    # and a failure to clear is not a reason to skip the probe — the send
    # itself reports whether the address can be delivered to.
    _ = Resend.clear_suppression(scope, to)

    with {:ok, from} <- probe_sender(scope, domain_of(to)),
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
  #
  # Stamped with the Resend domain id it was earned against, tokenised the
  # same way `environment=` already is on other resources. `verify/3` reads
  # it back through `proof_current?/2` and refuses a proof whose domain no
  # longer exists — a teardown-and-rebuild deletes and recreates the Resend
  # domain object under the same name, so the name alone cannot tell a live
  # proof from one earned against servers that are gone (1040172a). `nil` is
  # written the same as any other value: absent on read, `proof_current?/2`
  # treats it as not current rather than crash on a probe run without one.
  defp inbound_proof(to, message, domain_id) do
    %{
      kind: "inbound_proof",
      location: to,
      identifier:
        "state=delivered message_id=#{message["id"]} proven_at=#{message["created_at"]} " <>
          "resend_domain_id=#{domain_id}"
    }
  end

  # Whether a recorded proof was earned against *this* Resend domain, not
  # merely a domain of the same name. See `inbound_proof/3` for why the id
  # travels with the proof rather than the name alone.
  #
  # A proof with no stamp — recorded before this check existed — is treated
  # as not current rather than grandfathered in. `verify/3` already treats
  # anything a provider cannot answer for as absent (see the moduledoc); an
  # unstamped proof is exactly that, and the cost of being wrong the unsafe
  # way is a false "satisfied" this step exists to prevent.
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

        # The domain under test first, when it can send.
        #
        # Any verified domain can carry the probe and the claim is about where
        # mail *arrives*, so this used to take whichever came back first that
        # was not the product's own. That makes the probe's outcome depend on
        # what sorts first in a shared account: 974's 8030 sent from its own
        # domain and delivered, 8048 sent from an unrelated drill domain and
        # never arrived, minutes apart with identical code. A criterion that
        # passes or fails on unrelated work in the same account is not testing
        # what it says (3262205a).
        #
        # Still a preference rather than a requirement: at `inbound` the domain
        # is verified for *receiving* and may not be verified for sending, which
        # is why the fallback exists at all.
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
        |> permitted_hosts(name)
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
         opts = with_deploy_execution(opts, scope, environment, reference),
         {:ok, build} <- build_on_builder(scope, tag, architecture, opts) do
      {:ok,
       %{
         reference: reference,
         built: true,
         # Carried out so the step can record it. A network created inside the
         # build and never surfaced is one teardown cannot find.
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

  # The deploy runs on the same box the image was just built and pushed on —
  # never a second box, and never wherever the caller of `run_provisioning_step`
  # happens to be connected from. A harness cannot shell out at all, and even a
  # real local checkout would mean the deploy is no longer reproducibly the
  # platform's own (see `Deploy`'s own moduledoc). `Builder`'s `opts[:then]` is
  # exactly this hook: called with the box's own runner and the directory the
  # source landed in, after the push, while the box still exists.
  #
  # Built here from the same pieces `deploy_environment/3` used to assemble
  # for its own, separate call to `Deploy.run/3` — `with_host_ip`/`with_age_key`/
  # `with_registry_credential_for_deploy` need only `scope`/`environment`, so
  # nothing here depends on the build having finished. `with_deploy_ssh`/
  # `forget_stale_host_key` are not needed: `with_builder_ssh` already set
  # `opts[:env]` earlier in this same pipeline, and `Deploy.remote_command/3`'s
  # own `trust_host/1` replaces what `forget_stale_host_key/1` did for a local
  # run.
  defp with_deploy_execution(opts, scope, environment, reference) do
    host = Keyword.get(opts, :host) || environment_host(scope, environment) || domain(scope)

    deploy_opts =
      opts
      |> deploy_opts(host, %{reference: reference})
      |> with_host_ip(scope, environment)
      |> with_age_key(scope, environment)
      |> with_registry_credential_for_deploy(scope)

    Keyword.put(opts, :then, fn run, dir ->
      Deploy.run(env(scope), environment, Keyword.merge(deploy_opts, run: run, remote_dir: dir))
    end)
  end

  # Retention's claim is proven by what just happened, not assumed from
  # config (6dcb62b8). `:s3` storage already got a bucket lifecycle rule from
  # `Registry.ensure/2` back when the server step ran — the days are the
  # claim, and nothing more to do here. `:filesystem` — local-volume storage,
  # the real and final design (1b4af45c) — has no such rule, so this is what
  # makes retention true there: prune the registry down to `keep_images`
  # right after the push that may have made it too big.
  #
  # The claim is only made if the prune actually ran. A deploy that just
  # shipped must not fail because its own cleanup could not reach the box
  # afterward, but a claim rendered from `retention_days`/`keep_images` alone
  # — regardless of whether pruning succeeded — is exactly the bug this
  # replaces: a number with no mechanism behind it.
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

  # A second, independent `Hetzner.find_server` lookup rather than threading
  # the app server's IP down from wherever else it gets read — `build_image`
  # runs before `with_host_ip` sets one on `deploy_opts`, and the registry
  # this prunes lives on the app server, not on the ephemeral builder box
  # `with_builder_ssh` was written for. The SSH key material it wrote to
  # `opts` reaches any box the account owns, so this only needs the address.
  #
  # `Keyword.get(opts, :run)` wins over a freshly built SSH runner for the
  # same reason `serve_one_registry/5` checks it first: a caller — the local
  # fleet standing in for a box, or a test — that already supplied one is
  # answering "how do I reach it" more specifically than an IP this scope
  # happens to have, and building a second runner from a provider's fake
  # address would try to reach a box that was never made.
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

  # Old images stop costing money because something here actually enforces
  # it, not because anything here runs on a schedule (6dcb62b8). Two
  # mechanisms, two honest shapes: `:s3` storage gets its claim from the
  # bucket's own lifecycle rule, the same shape as the backups' retention;
  # `:filesystem` — local-volume storage, the real and final design — has no
  # bucket, so its claim comes from `retention_claim/3` having actually run
  # `Registry.prune/2` this build. `nil` (no enforcement happened) yields no
  # resource at all, the same absence-over-false-claim shape
  # `image_resources(:not_built)` uses. `ProvisioningLive` reads `enforced_by`
  # off whichever resource shows up rather than asserting either string
  # itself — this is the one place that decides it.
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
  # Only environments the server step has given an address. One without an ip
  # has no record to check, and treating it as unsatisfied would keep dns
  # permanently absent on a half-built project.
  defp pointable_environments(scope) do
    scope
    |> permitted_environment_rows()
    |> Enum.filter(&(is_binary(&1.ip) and &1.ip != "" and is_binary(&1.host) and &1.host != ""))
  end

  defp verify_dns_records(scope, domain, environments) do
    with {:ok, %{"id" => zone_id}} <- Cloudflare.find_zone(scope, domain),
         {:ok, records} <- Cloudflare.list_dns_records(scope, zone_id) do
      dns_records_satisfied(records, environments)
    else
      # A zone we cannot read is a question unanswered, not a record missing.
      # Absent is the safe reading: the step re-runs and `ensure_dns_record`
      # converges rather than duplicating.
      _ -> {:ok, :absent}
    end
  end

  defp dns_records_satisfied(records, environments) do
    case Enum.all?(environments, &record_points_at?(records, &1)) do
      true -> {:ok, :satisfied, Enum.flat_map(environments, &dns_resources_for/1)}
      false -> {:ok, :absent}
    end
  end

  # Present *and* pointing at this environment's server. A record left over
  # from a previous build points at an address the project no longer holds, and
  # reporting that as satisfied is how a name keeps resolving to a machine
  # somebody else was given.
  defp record_points_at?(records, environment) do
    Enum.any?(records, fn record ->
      record["name"] == environment.host and record["content"] == environment.ip
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
          # The check counts. Without it a step that asked the provider and was
          # told "verified" rendered "0 check(s)" — it did look, and said it
          # had not, which is indistinguishable from assuming. One call to
          # `find_domain` is one check, so that is what it reports.
          #
          # And the provider's answer is not the whole answer. "Verified" is
          # Resend's memory of a check it ran, not a statement about the zone
          # now, and `Dns`'s moduledoc is written about exactly this gap: "a
          # provider holds a verification long after the record behind it is
          # deleted, so a domain reads verified while its DKIM is gone and mail
          # is being rejected somewhere else."
          #
          # Measured, after an unrelated teardown removed every record in the
          # zone: Resend still said verified, this returned satisfied, and
          # `run_step/3` therefore never called `run(:email, …)` — so the one
          # action that rebuilds the records was skipped precisely because it
          # was "already done", and the domain kept reporting healthy with no
          # DKIM at all (5dfd6eff). The `secrets` verify above documents the
          # same trap in its own words: checking one half made the failure
          # unrecoverable rather than merely broken, because re-running the
          # step was the obvious remedy and it did nothing.
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

  # Whether the records Resend requires are actually in the zone.
  #
  # Asked of the provider's own list rather than a hand-built one: the DKIM
  # public key is generated per domain, so a name derived here would be wrong
  # for exactly the record that matters most. `Resend.records/1` says the same
  # thing about deriving them.
  #
  # Existence only, not content. A record whose value drifted is a different
  # failure from one that is absent, and rewriting on a value mismatch would
  # fight anyone who edited a record deliberately. Absence is the case that
  # left a domain sending unsigned mail.
  #
  # Authoritative rather than recursive, because this runs immediately after a
  # write often enough to matter — a recursive resolver holding a negative from
  # before the record existed would report a healthy zone as broken and rewrite
  # records that were already correct.
  defp sending_published?(scope, sending, domain) do
    records =
      scope
      |> sending_records_for(domain)
      |> Resend.sending_records(sending)

    case {records, find_sending_zone(scope, sending)} do
      # Nothing required is trivially satisfied — and is the normal answer when
      # the provider hands back a domain with no record list.
      {[], _} ->
        true

      {records, {:ok, zone}} ->
        Enum.all?(records, &record_published?(&1, zone))

      # Cannot tell. Reporting absent here would make a zone lookup failure
      # rewrite every record on every verify, which is churn against a live
      # domain for a question that was never answered. The provider's verified
      # stands when there is nothing better.
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
    case sending_published?(scope, sending, domain) do
      true ->
        {:cont,
         {:ok,
          acc ++
            [
              %{kind: "sending_domain", location: "resend/#{domain["name"]}"},
              %{kind: "verification", location: "1 attempts"}
            ]}}

      false ->
        {:halt, :absent}
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
  # The connection string, handed over rather than left to be decrypted.
  #
  # We already know it — the server step composed it and `Database.credential/2`
  # can say it again — and the box this now runs on has docker and curl and
  # deliberately nothing else, so asking it to decrypt meant
  # `sops: command not found` for a value that was already in hand. With this
  # (and the bucket and keys beside it) `load_env` has nothing left to do.
  defp put_database_url(opts, scope, environment) do
    case Database.credential(scope, environment) do
      {:ok, credential} -> Keyword.put_new(opts, :database_url, Database.url(credential))
      _ -> opts
    end
  end

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
  #
  # `Enum.reduce_while([], {:ok, []}, …)` never enters the loop and returns
  # `{:ok, []}` — a deploy that shipped nothing, reported as one that shipped
  # (402f9439). Empty only ever means the devops level filtered out every
  # environment this project has; a caller naming one environment explicitly
  # takes the `deploy_environment/3` path in `run(:deploy, …)` above instead
  # of this one, so that legitimate single-environment call is untouched.
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
         # Before the build, not after: the builder is sent `git archive HEAD`
         # and `bin/deploy` versions the image by `git rev-parse HEAD`, so
         # committing afterwards built one SHA and deployed another.
         :ok <- commit_generated_configuration(scope),
         {:ok, image} <- image_for(scope, environment, opts),
         result <- deploy_result(scope, environment, host, image, opts) do
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

  # A build already ran the deploy on its own box, over its own ssh — see
  # `with_deploy_execution/4` — so `image.deploy` carries that result back
  # rather than this running it a second time, on a second, different
  # environment. Only a caller that skipped the build entirely (an explicit
  # `:image`, or `build: false` — a redeploy of what is already running)
  # still reaches the old path here, against whatever `env(scope)` is.
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

  # What the project asked for, not what it has rows for.
  #
  # `ProjectConfiguration` states the levels plainly: `:uat` is "stand up
  # staging only; the user promotes to prod themselves". Nothing consulted it —
  # `EnvironmentRepository.seed/1` creates prod and uat for every project and
  # every step fanned out over both, so a project set to `:uat` finished setup
  # holding a production server, a DNS record and a database it had explicitly
  # opted out of. Against real providers that is a box somebody pays for.
  #
  # It hid behind a green, too: the prod steps *succeeded*, so `devops_status`
  # reported complete and 841/1962 — the criterion whose whole subject is this
  # — passed for the wrong reason.
  #
  # Filtered here rather than in the seed, because a row is not infrastructure.
  # Seeding both keeps promotion a matter of changing one setting, which is
  # what "the user promotes to prod themselves" means.
  defp permitted_environments(scope) do
    scope |> permitted_environment_rows() |> Enum.map(& &1.name)
  end

  # The rows, filtered by the same rule. The server step fans out over structs
  # rather than names, and the comment on `ensure_environment_servers/3` is
  # about precisely this hazard: a step that fans out over one list and checks
  # its work against another reports gaps that are really disagreements. It
  # took the unfiltered list, so the `:uat` filter above stopped the *later*
  # steps touching prod while the server step went on building the box.
  defp permitted_environment_rows(scope) do
    rows = EnvironmentRepository.list(scope)

    case devops_level(scope) do
      :uat -> Enum.reject(rows, &(&1.name == "prod"))
      _ -> rows
    end
  end

  # The same rule again, for the three steps that need each environment's
  # *host* rather than its name — dns publishes them, tls certifies them, and
  # the deploy config check compares against them.
  #
  # All three read `assign_hosts/2` straight, so on a UAT-only project the tls
  # step tried to certify the production apex: a name the dns step had
  # correctly not published, on a box that had correctly not been built. The
  # report then blamed certificate issuance, which is three steps away from the
  # decision that caused it.
  defp permitted_hosts(scope, domain) do
    permitted = MapSet.new(permitted_environments(scope))

    scope
    |> EnvironmentRepository.assign_hosts(domain)
    |> Enum.filter(&MapSet.member?(permitted, &1.name))
  end

  # No row, or a row predating the column, means nobody has said this project
  # ships — the same answer the schema default gives. Mirrors
  # `Resources.devops/2`, which reads it for the same reason.
  defp devops_level(scope) do
    case Configurations.get(scope) do
      %{devops: devops} when not is_nil(devops) -> devops
      _ -> :off
    end
  end

  # Shared by every run/3 clause that fans out over environments and must
  # refuse rather than report done for a project whose devops level filtered
  # every environment row out from under it (402f9439: devops-drill has a
  # `prod` row and `devops: :uat`, so `permitted_environment_rows/1` — and
  # everything derived from it, `permitted_environments/1` and
  # `permitted_hosts/2` — comes back empty). `Enum.all?/2` over `[]` is
  # `true` and `Enum.reduce_while/3` over `[]` never enters the loop, so a
  # step that trusted either was one call away from reporting success on
  # zero servers, zero DNS records, zero minted keys. This names what
  # actually went wrong rather than the generic "no domain set" a caller
  # would otherwise have to guess at from a step that quietly did nothing.
  defp no_permitted_environments_message(scope) do
    "no environment is permitted for this project's devops level (#{devops_level(scope)}) — " <>
      "every environment row this project has was filtered out. Add the missing environment " <>
      "before this step can provision anything."
  end

  defp server_name(scope, opts) do
    Keyword.get(opts, :server_name) || Repository.default_name(project(scope))
  end

  # An environment's server is its own box: `<project>-<environment>`. Sharing
  # one between environments would mean UAT traffic reaching production, which
  # is the thing having environments is for.
  #
  # Unless the environment is linked to an account-level server (the re-grain
  # story 879 deferred) — then it already has a real name, and deriving a
  # fresh one from the project would search for a box that was never going
  # to exist under that name.
  defp server_name(scope, opts, environment) do
    case linked_server_name(scope, environment) do
      nil -> "#{server_name(scope, opts)}-#{environment}"
      name -> name
    end
  end

  defp linked_server_name(scope, environment_name) do
    with %{server_id: server_id} when is_binary(server_id) <-
           EnvironmentRepository.get(scope, environment_name),
         %Server{name: name} <- Repo.get(Server, server_id) do
      name
    else
      _ -> nil
    end
  end

  # The disposition rides on the resource because "adopted rather than
  # duplicated" is only checkable if the page can tell the two apart — and
  # `created` twice is exactly the failure the criterion is about.
  # Asked before anything is built, because the answer is already on disk.
  #
  # `Generators.audit/2` reads files in the checkout and needs nothing from the
  # box, yet its only call site here was inside `require_script_in/3`'s `else`
  # branch — so it ran only when `bin/deploy` was *missing*, purely to explain
  # why. A project whose `bin/deploy` existed and whose config the audit could
  # prove would fail went the whole way instead: a builder box, an image build
  # and push, a migration against the real database, a container start, and a
  # 30-second health timeout, ending in "target failed to become healthy" —
  # which reads as an application fault rather than a config one.
  #
  # The `force_ssl` case is the one that cost a QA session. `exclude:
  # ["/health", …]` excludes a *host* named "/health", matches nothing, and
  # leaves the proxy's plain-HTTP probe redirected; `explain/1` has had the
  # sentence for it all along.
  # A scope with no environment has nowhere to read the checkout from, and
  # `Generators.audit/2` is guarded `when not is_nil(env)` — so asking it here
  # raised a FunctionClauseError and the deploy step crashed instead of
  # reporting one errored row. That is the exact failure
  # `no_environment_message/0` exists to prevent, and the path below already
  # produces it: `deploy_environment/3` reaches `require_script/2`, which names
  # the missing environment. Passing through is what lets it.
  defp deploy_ready(%Scope{environment: nil}), do: :ok

  defp deploy_ready(%Scope{} = scope) do
    case CodeMySpec.Generators.audit(scope, router_path(scope)) do
      [] ->
        :ok

      findings ->
        {:error,
         "this project is not deploy-ready: " <>
           Enum.map_join(findings, "; ", &CodeMySpec.Generators.explain/1) <>
           ". Setup will not build and ship an image it can already tell will not come up."}
    end
  end

  # Asked before the firewall, because everything after it costs money.
  #
  # Every environment's box serves the registry the deploy pulls from, and
  # `Registry.ensure/2` needs the object-storage key pair to do it. That call
  # sits behind `await_box/2`, which waits for SSH on a machine Hetzner has
  # already started billing for — so a project with no keys paid for a server,
  # waited a minute for it to boot, and then failed with the bare atom
  # `:no_storage_credentials`. `Credentials`' moduledoc names that outcome as
  # the one the credential check exists to prevent: "by which point Sam has a
  # server he did not want yet".
  #
  # Nothing here needs the box, so it can all be answered first.
  #
  # Paused, not errored: a console-only credential that has not been pasted yet
  # is a step waiting on Sam, not a broken one — and `credentials_instructions/0`
  # is already what the storage step says in the same situation, so he reads one
  # answer rather than two that disagree.
  #
  # `opts[:credentials]` wins, matching `Registry.credentials/2`, so a caller
  # that supplies its own pair is not asked to have stored one.
  defp storage_credentials_ready(%Scope{} = scope, opts) do
    case Keyword.get(opts, :credentials) || Storage.credentials(scope, opts) do
      :none -> {:paused, Storage.credentials_instructions()}
      _credentials -> :ok
    end
  end

  # `origin` set from the disposition, not left to the schema default.
  #
  # It defaulted to "adopted", so a repository setup had just created recorded
  # itself as one Sam already had — the field teardown keys on saying the
  # opposite of what happened, with the truth sitting one key over in
  # `identifier`. Nothing acts on it today (teardown lists "repository" among
  # the kinds with nothing provider-side to remove), which is exactly why it
  # went unnoticed; it would be found by whoever first wrote a rule that
  # trusted it.
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
    case permitted_environment_rows(scope) do
      # `Enum.reduce_while([], {:ok, made}, …)` returns `{:ok, made}`
      # unchanged, and `join_baseline_network/4` treats zero servers to
      # attach as nothing to do — so the step reported `:done` having built a
      # firewall and an ssh key and not one box (402f9439). This is the same
      # shape `verify(:server, …)`'s `found != []` guard already exists to
      # stop the *verify* side from making, now stopped on the *run* side too.
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
         :ok <- attach_all(scope, servers, network) do
      finish_baseline_network(scope, servers, network, opts, environments, name, made)
    else
      {:ok, []} -> {:ok, made}
      {:error, reason} -> {:error, format(reason), made}
    end
  end

  defp join_baseline_network(other, _scope, _opts, _environments), do: other

  # Split from `join_baseline_network/4` only so `network` is a plain
  # parameter here rather than a `with`-bound variable an `else` clause
  # cannot see — `serve_registries/5` can fail two different ways
  # (`{:ok, []}`-shaped nothing-to-do doesn't apply to it; it is either
  # `{:ok, registries}` or `{:error, reason, registries}`) and both need
  # `network` to build the network's own resource entry.
  defp finish_baseline_network(scope, servers, network, opts, environments, name, made) do
    case serve_registries(scope, servers, network, opts, environments) do
      {:ok, registries} ->
        {:ok, registries ++ [network_resource(name, network) | made]}

      # One environment's registry/database failing is not evidence about
      # any other environment's — `serve_registries/5` already tried every
      # server independently, so whatever it did build is recorded here
      # rather than thrown away because a *different* environment's write
      # failed. Found live against MarketMySpec: prod's known
      # local-checkout secrets-write wall halted the whole loop before uat
      # was ever attempted, on every single rerun — uat's database could
      # never be created as long as prod kept failing first, because two
      # genuinely independent boxes were treated as one dependent sequence.
      {:error, reason, registries} ->
        {:error, format(reason), registries ++ [network_resource(name, network) | made]}
    end
  end

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
  #
  # Every server is attempted regardless of another's outcome, not halted at
  # the first failure — a `reduce_while` here made one environment's failure
  # (prod's secrets-write wall, say) permanently block every environment
  # after it in the list, on every rerun, since the failing one always fails
  # first. Servers do not depend on each other the way pipeline steps do;
  # nothing here should stop uat from ever being attempted because prod keeps
  # erroring.
  defp serve_registries(scope, servers, network, opts, environments) do
    results = Enum.map(servers, &{&1, serve_one_registry(scope, &1, network, opts, environments)})

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
    case Dns.resolution_status(environment.host, :a, resolver_opts(opts)) do
      :resolves ->
        {:cont, {:ok, acc ++ [record] ++ dns_verification(environment)}}

      # A counting-down TTL on a negative is a fact about a resolver's cache,
      # not about the record. The write went to Cloudflare and was accepted;
      # what a recursive resolver remembers from before that is not the step's
      # to fail on, and no amount of retrying inside one step outlasts a
      # half-hour negative TTL. Failing here stopped a run whose record `dig`
      # was answering correctly the whole time, and every name that gets
      # created, destroyed and created again — every spex label, every drill
      # domain, every retried setup — walks into it (8fb98c23).
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

  # Which of the two it is decides whether Sam goes looking for a mistake or
  # waits. A resolver still holding "this name does not exist" from before the
  # record was written says nothing about the record, and no amount of retrying
  # inside one step outlasts it — the zone publishes a negative TTL of half an
  # hour. Reported as a missing record it sent me hunting a publish bug for a
  # name `dig` was answering correctly the whole time.
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

  # Confirmed against a public resolver, not against our own write. A record
  # that exists in the dashboard and does not resolve is the classic DNS
  # failure, and it looks identical to success from the API's answer alone.
  #
  # The asking moved to `confirm_dns_record/5`, which needs to know *why* a
  # name did not resolve rather than only that it did not; this records the
  # answer once that call has already been made.
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
    interval = Keyword.get(opts, :interval_ms, 2_000)

    opts
    |> Keyword.take([:resolver])
    |> Keyword.put(:interval_ms, interval)
    |> Keyword.put(:attempts, Keyword.get(opts, :resolver_attempts, 15))
    |> Keyword.put(:settle_ms, settle_ms(opts, interval))
  end

  # A record written a moment ago has not reached a public resolver yet, and
  # asking before it has is what caches the "no" the retries then cannot get
  # past. Waiting once costs a few seconds; not waiting cost a half-hour
  # lockout on the name and fifteen retries that could never succeed.
  #
  # Nothing on replay, where the cassette answers instantly and there is no
  # propagation to wait for — the same reason `interval_ms` is zeroed there.
  # Reading it off the interval keeps the two from drifting apart, which is how
  # a replay ends up sleeping five seconds per record for no reason.
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
      findings = CodeMySpec.Generators.audit(scope, router_path(scope))

      case {findings, Environments.file_exists?(environment, path)} do
        # Nothing else looks wrong, and this environment cannot see the
        # plain file either — a harness-scoped caller's environment, the
        # same shape every other check tonight already treats as "cannot
        # prove it," not "definitely wrong." `Generators.audit/2` already
        # asked the project's own `Files` sync table whether the boilerplate
        # is there; asking harder than that needs a live checkout, which
        # this call does not have.
        {[], false} ->
          :ok

        # The plain file really is there — a live, reachable checkout says
        # so — and still fails the executable check. That is a real
        # permission problem, not an absent one.
        {[], true} ->
          deploy_not_ready_error("#{path} is not present or not executable")

        {findings, _} ->
          detail = Enum.map_join(findings, "; ", &CodeMySpec.Generators.explain/1)
          deploy_not_ready_error(detail)
      end
    end
  end

  defp deploy_not_ready_error(detail) do
    {:error,
     "this project is not deploy-ready: #{detail}. " <>
       "The boilerplate ships with `cms new`; a project generated another way has to add it."}
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

  # The site this project actually serves, which is an environment's host and
  # not the project's domain.
  #
  # This returned `https://<domain>` — the apex — regardless of which
  # environments exist. On a project with production turned off, the apex has no
  # record at all, so the widget step probed a name nothing resolves and
  # reported the widget "not usable" with `nxdomain`, on a site that was up and
  # serving it at `uat.<domain>`.
  #
  # Exactly the fault the deploy step was fixed for: it used `domain/1` too, and
  # handed a UAT deploy production's hostname, so its health check probed an
  # address nothing had been deployed to. `environment_host/2` is the answer
  # there and is the answer here. The domain remains the fallback for a project
  # whose environments predate hosts.
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

  # Point the backup at the box its database is on, and put the script there.
  #
  # `bin/backup` has to run where `cms-postgres` resolves, which is the
  # environment's own server and its private docker network — from anywhere else
  # `pg_dump` reports `could not translate host name "cms-postgres" to address`.
  # `install_schedule` matters even more: it writes a systemd unit with sudo, so
  # running it locally installs a nightly job on the machine that ran setup.
  #
  # The tree is delivered the same way the build gets its source — `git archive`
  # over the ssh we already hold — because the app host runs a container rather
  # than a checkout, so `bin/backup` and `envs/<env>.enc.env` are not there
  # otherwise. `@backup_dir` is stable, so a re-run replaces the tree rather
  # than accumulating copies, and the nightly unit's WorkingDirectory keeps
  # pointing at something real.
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
    EnvironmentRepository.get(scope, environment) || %{name: environment}
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

  # `lib/app_web/router.ex`, `lib/app/release.ex` — the fallback this used to
  # be — is Phoenix's own generator template path, before a project's real
  # name is substituted in. It is never actually right for a real project, so
  # falling back to it reported the WRONG file as missing rather than saying
  # the app name could not be determined: MarketMySpec's `module_name` never
  # arrived, and every deploy-readiness check built on this path checked
  # `lib/app_web/...` against a project whose real files are
  # `lib/market_my_spec_web/...`.
  #
  # `Environments.mix_exs_app_name/1` reads `mix.exs`'s own `app:` atom
  # directly — never ambiguous, but only answerable when `scope.environment`
  # can actually be read from. For a project reached only through a live
  # harness connection, `scope.environment` here resolves through
  # `Resources.project_scope/2`'s fallback to `Environment.new(:local,
  # project.local_path)` — a path on *the machine the checkout is on*, not
  # this server's — so this returns `nil` for exactly that shape of project,
  # same as any other environment nothing here can actually reach.
  # `module_name` is the fallback for that case: `CmsHarness.Sync` derives it
  # from the SAME `mix.exs`, on the machine that can actually read it, and
  # keeps it corrected on every sync (see `HarnessProjectChannel`'s
  # `"module_name"` handler) — so a harness-only project still gets the real
  # answer, just relayed rather than read here directly. A project with
  # neither degrades to the same "not found" honesty every check downstream
  # already reports for a file that genuinely does not exist, rather than to
  # a wrong guess.
  defp app_path(scope) do
    Environments.mix_exs_app_name(scope.environment) || module_name_app_path(scope)
  end

  defp module_name_app_path(scope) do
    case project(scope) |> Map.get(:module_name) do
      name when is_binary(name) and name != "" -> Macro.underscore(name)
      _ -> nil
    end
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

  # Resend hands back `signing_secret` only from the create call, never from
  # list or get — the deployed app's own ResendWebhookController needs it to
  # verify a request genuinely came from Resend rather than skip verification
  # entirely (its own documented graceful degradation for exactly the case
  # where nothing was ever threaded here). `ensure_webhook/3` returns the same
  # shape either way, so a re-run that only *adopts* an already-enabled
  # webhook carries no secret to seed — nothing was lost, there was never
  # anything here to place. 04349864.
  #
  # Best-effort, deliberately: this only makes the controller's own
  # already-safe fallback unnecessary, it does not make inbound work — a
  # sops failure seeding it (a fresh environment whose secrets file was never
  # touched, a runner sops genuinely cannot reach) must not fail the step
  # that just finished proving a real message was delivered end to end. Logged
  # rather than silent, so it does not vanish the way a swallowed error would.
  defp seed_webhook_secret(scope, %{"signing_secret" => secret})
       when is_binary(secret) and secret != "" do
    resources =
      scope
      |> EnvironmentRepository.names()
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

        with {:ok, zone} <- Cloudflare.find_zone(scope, base),
             :ok <- check_competing_mx(scope, zone, records, opts) do
          Enum.reduce_while(records, {:ok, []}, &publish_mx_record(&1, &2, scope, zone))
        end
    end
  end

  # `Cloudflare.ensure_dns_record/5` matches on name AND type: an existing MX
  # at this name with different content is not "already right", so its own
  # `%{"id" => id} -> update_dns_record(...)` branch overwrites it. For an A
  # record that is `apex_repoint/4`'s whole concern; for MX it is worse,
  # because MX genuinely supports several records at once (a domain split
  # across two providers is not automatically wrong the way two apex A
  # records would be) — so overwriting one is not "repointing what was
  # already ours", it can be silently taking over somebody else's inbox.
  #
  # 22b0e27c: found live, never checked. `ensure_receiving_domain/3` and
  # `run(:inbound, …)` went straight to publishing Resend's MX with nothing
  # anywhere reading what a name already resolved to first — the same class
  # of gap `apex_repoint/4` closed for the A record, missed here for MX.
  defp check_competing_mx(scope, zone, records, opts) do
    if Keyword.get(opts, :confirm_inbound_mx_repoint, false) do
      :ok
    else
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

  # `owned?/2` returning false means "not in this account", not "available to
  # register" — Cloudflare's registrar API only answers availability, price,
  # and current registrar for a domain the account already holds; for
  # anything else (including a name nobody could ever buy, like google.com)
  # it returns just the name and whether the extension is supported, and
  # `check_availability/2` reads that absence as `:unknown` rather than
  # inventing a verdict. Reusing that same absence here as "is available" was
  # the defect — this app cannot register a name it does not already hold, so
  # the honest answer is the dashboard errand `Steps.run(:domain, ...)`
  # otherwise sends every unsupported-TLD and payment-method failure to
  # (`classify_registration_error/1`), and the one the domain panel already
  # gives (`CodeMySpecWeb.ProvisioningLive`'s `domain-dashboard-handoff`).
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

  # `.sops.yaml` names every environment the project has a stored key for,
  # not only the ones a caller just touched. `environments` here is
  # `permitted_environments/1`'s output — filtered by devops level, so a
  # project set to `devops: :uat` only mints/repairs uat this run — but that
  # scoping is about what gets *provisioned*, not about what the config file
  # describes. `age_private_key_prod` outlives a uat-only run untouched, and
  # a `.sops.yaml` rewritten from `recipients` alone dropped prod's rule
  # while the key stayed on record: nothing left to encrypt `envs/prod.enc.env`
  # to, and the stored key opened nothing (af60405c).
  #
  # Derived from `ProjectSecrets`, not read back from each environment's
  # `.enc.env` file — a key that exists but has no file yet (minted, nothing
  # written through it) would otherwise vanish from the config the same way,
  # and the derivation works whether or not the file exists.
  defp with_other_environment_recipients(scope, recipients) do
    names = EnvironmentRepository.names(scope) -- Map.keys(recipients)

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

  # Which CodeMySpec the deployed application talks back to.
  #
  # `config/runtime.exs` in every generated app falls back to
  # `wss://codemyspec.com/widget` when `CODEMYSPEC_WIDGET_URL` is unset, and
  # nothing used to set it — so an application provisioned by a self-hosted or
  # development server opened its widget socket against the hosted service,
  # authenticating with a deploy key that server had never issued. Rejected, but
  # attempted, on the client's reconnect backoff, from every deployed app.
  #
  # It also meant the widget could never be proven anywhere but production: the
  # loopback drives the app's real client, and the message goes wherever that
  # client points. Setup knows the answer — it is the server running the
  # sequence — so it writes it down beside the key the same socket authenticates
  # with.
  defp widget_socket_url do
    base = Application.get_env(:code_my_spec, :base_url) || "https://codemyspec.com"

    case URI.parse(base) do
      %URI{scheme: "http"} = uri -> %{uri | scheme: "ws", path: "/widget"}
      uri -> %{uri | scheme: "wss", path: "/widget"}
    end
    |> URI.to_string()
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

  # Every environment's registry, reached over SSH the way `serve_one_registry`
  # reaches it — a curl through the credential `Registry.credential/1` mints,
  # asked once rather than the fifteen times `await_registry/5` allows a
  # freshly-started container.
  #
  # One SSH identity for every environment in the walk, not one per box: the
  # key is the account's and opens all of them, so minting it once and reusing
  # it is the same key `with_builder_ssh/2` already writes for a build. Cleaned
  # up in `after`, the same guard `build_on_builder/4` uses, because this runs
  # on every `devops_status` read rather than once per setup click — a key
  # written and never removed here would litter the temp directory on a
  # cadence a build never has.
  #
  # No network, no registry to ask about: a project whose server step has
  # never run has nothing `Hetzner.find_network/2` can find, and that is
  # `{:ok, :absent}` already, by the same `found != []` guard this sits
  # behind.
  defp registries_reachable?(scope, name, environments, opts) do
    case with_builder_ssh(scope, opts) do
      {:ok, ssh_opts} -> registries_reachable_with_ssh(scope, name, environments, ssh_opts)
      _ -> false
    end
  end

  defp registries_reachable_with_ssh(scope, name, environments, ssh_opts) do
    case Hetzner.find_network(scope, name) do
      {:ok, network} ->
        Enum.all?(environments, &registry_reachable?(scope, network, &1, ssh_opts))

      _ ->
        false
    end
  after
    case Keyword.get(ssh_opts, :builder_key_dir) do
      dir when is_binary(dir) -> File.rm_rf(dir)
      _ -> :ok
    end
  end

  # The box's own address to SSH into, and the private address the registry
  # would answer on — the same two lookups `serve_one_registry/5` makes before
  # starting one, asked here to find out whether it already answers.
  #
  # `Keyword.get(opts, :run)` wins over a runner built from the box's address,
  # for the same reason `serve_one_registry/5` and `prune_registry/3` check it
  # first: a caller standing in a local fleet, or a fake, for the box is
  # answering "how do I reach it" more specifically than an IP this scope
  # happens to have.
  defp registry_reachable?(scope, network, environment, opts) do
    name = server_name(scope, opts, environment)

    with {:ok, server} <- Hetzner.find_server(scope, name),
         public when is_binary(public) and public != "" <-
           get_in(server, ["public_net", "ipv4", "ip"]),
         {:ok, bind} <- Hetzner.private_ip(server, network["id"]) do
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
  # environment's key must not drop another's. Shares
  # `with_other_environment_recipients/2` with `generate_keys/3` rather than
  # the `["prod", "uat"]` literal this used to carry — the same magic list
  # `EnvironmentRepository`'s moduledoc already names as the seven-file bug
  # this module exists to avoid, and it would have gone stale the moment a
  # project gained a third environment.
  defp write_recipients(scope, env, environment, public) do
    recipients = with_other_environment_recipients(scope, %{environment => public})
    Sops.write_config(env, recipients)
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

  @doc """
  Record an environment's age key when it was generated somewhere this
  server cannot reach, not minted by `ensure_age_key/3` itself.

  A project with no local checkout on this side (reached only through the
  light harness, with nothing behind it that can write `.sops.yaml` or an
  environment's `.enc.env` file) still needs its checkout's real key on
  file here — a caller who generated the pair on a real checkout and
  committed `.sops.yaml`'s public half has to hand this the private half,
  or the next thing that needs to decrypt (`:deploy`, another secret write)
  mints a *different* key under the same name, and every ciphertext already
  committed under the real one becomes unreadable to it.

  Returns the derived public key rather than trusting the input blind, so a
  caller can confirm it matches what was actually committed to `.sops.yaml`
  before relying on it — a mismatched key fails much later, decrypting
  nothing, with no way to tell which of several inputs was wrong.
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

  # Named rather than left to `inspect/1`, the same way every other reason
  # here already reads as a sentence rather than a term: a harness-scoped
  # caller's scope carries no working directory to write this secret into
  # — an ordinary, expected shape now that `Environments.Local`/`Cli`
  # answer it as a clean error instead of raising, not a term worth making
  # the reader decode.
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
