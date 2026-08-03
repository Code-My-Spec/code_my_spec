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

  alias CodeMySpec.{Environments, ProjectSecrets, Projects}

  alias CodeMySpec.Provisioning.{
    Backups,
    Builder,
    Cloudflare,
    ContentPublishing,
    Deploy,
    Dns,
    EnvironmentRepository,
    Hetzner,
    Registry,
    Repository,
    Resend,
    Sops,
    Storage,
    Widget
  }
  alias CodeMySpec.Users.Scope

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
          {:ok, server} <- [Hetzner.find_server(scope, server_name(scope, opts, environment))],
          do: server_resource(server, environment)

    cond do
      # Satisfied only when EVERY environment has its box. One environment
      # missing is not "done" — it is a project that cannot deploy that
      # environment, and reporting done hides it until the deploy fails.
      length(found) == length(environments) and found != [] ->
        # The step also makes a firewall and an ssh_key, shared across
        # environments. A second run takes this satisfied path instead of
        # `run/3`; returning only the servers would drop those two from the
        # step's resources (7965: "running twice leaves one of everything").
        {:ok, :satisfied,
         found ++
           found_resource(Hetzner.find_firewall(scope, name), &firewall_resource(name, &1)) ++
           found_resource(Hetzner.find_ssh_key(scope, name), &ssh_key_resource(name, &1))}

      true ->
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

    # Satisfied only when EVERY environment has a key. A partially-keyed
    # project is not done — the environment without one cannot be deployed,
    # and reporting done would hide that until the deploy failed.
    case Enum.all?(environments, &ProjectSecrets.has_value?(scope, age_key_name(&1))) do
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
         %{"status" => "enabled"} <- Enum.find(webhooks, &(&1["endpoint"] == webhook_endpoint(scope, opts))) do
      {:ok, :satisfied,
       [
         %{kind: "receiving_domain", location: "resend/#{name}"},
         %{kind: "webhook", location: webhook_endpoint(scope, opts)}
       ]}
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
        wanted = Enum.map(environments, &Storage.bucket_name(project, &1))

        case Storage.list_buckets(credentials, opts) do
          {:ok, existing} ->
            # Every environment or none: a project with a production bucket and
            # no UAT bucket is not done, and saying it is hides that until an
            # upload fails.
            if Enum.all?(wanted, &(&1 in existing)) do
              {:ok, :satisfied, Enum.map(wanted, &bucket_resource(&1, opts))}
            else
              {:ok, :absent}
            end

          {:error, reason} ->
            {:error, format(reason)}
        end
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
           |> Keyword.put(:ssh_key_ids, [ssh_key["id"]]) do
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
          {:paused, instructions} -> {:paused, instructions}
          {:error, :confirmation_required} -> {:paused, confirmation_message(name)}
          {:error, reason} -> {:error, format(reason)}
        end
    end
  end

  def run(:dns, %Scope{} = scope, opts) do
    with name when is_binary(name) <- domain(scope),
         {:ok, zone} <- Cloudflare.find_zone(scope, name),
         environments <- EnvironmentRepository.assign_hosts(scope, name),
         {:ok, resources} <- dns_records_for(scope, zone, environments, opts) do
      {:ok, resources}
    else
      nil -> {:error, "no domain set on the project"}
      {:error, reason} -> {:error, format(reason)}
    end
  end

  def run(:email, %Scope{} = scope, opts) do
    environments = environments(scope, opts)

    case domain(scope) do
      nil -> {:error, "no domain set on the project"}
      base -> register_sending_domains(scope, base, environments, opts)
    end
  end

  # Required before the app can boot at all. Checked here rather than
  # discovered on the server, because a missing secret found at boot is a
  # deploy that swapped and then failed — and the message a crashed release
  # gives is not the name of the thing that was missing.
  @required_secrets ~w(SECRET_KEY_BASE DATABASE_URL)

  def run(:deploy, %Scope{} = scope, opts) do
    environment = Keyword.get(opts, :environment, "uat")
    host = Keyword.get(opts, :host) || domain(scope)
    version = Keyword.get(opts, :deployed_version)

    with {:ok, delivery} <- check_secrets(scope, environment),
         {:ok, image} <- image_for(scope, environment, opts),
         :ok <- require_script(scope, "bin/deploy"),
         result <- Deploy.run(env(scope), environment, deploy_opts(opts, host, image)) do
      case deploy_outcome(result, environment, host) do
        {:ok, resources} ->
          {:ok, [delivery | version_resources(version) ++ image_resources(image) ++ resources]}

        {:error, reason, resources} ->
          {:error, reason, [delivery | resources]}

        other ->
          other
      end
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
        {:paused, "Add a notification target before installing monitors — a monitor nobody hears is not monitoring."}

      {:error, reason} ->
        {:error, format(reason)}
    end
  end

  def run(:content, %Scope{} = scope, opts) do
    case ContentPublishing.run(scope, opts) do
      %{state: :rendered} -> {:ok, [%{kind: "content", location: "published and rendered"}]}
      %{reason: reason} -> {:error, reason}
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
           require_value(Keyword.get(opts, :deploy_key) || Map.get(project, :deploy_key), "a deploy key") do
      opts = opts |> Keyword.put(:site_url, site) |> Keyword.put(:deploy_key, key)

      case Widget.run(scope, env(scope), opts) do
        %{state: :proven} -> {:ok, [%{kind: "widget", location: "installed and proven"}]}
        %{reason: reason} -> {:error, reason}
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
    case host(scope, opts) do
      nil ->
        {:error, "no domain set on the project — nothing to issue a certificate for"}

      h ->
        # Issuance is kamal-proxy's job during deploy; this step verifies it
        # actually happened. A certificate nobody checked is a certificate
        # that fails on a visitor rather than during setup. The probe is
        # injectable so a spex can verify the recording without a live host.
        probe = Keyword.get(opts, :probe, &Deploy.probe/2)

        case probe.(h, opts) do
          :ok ->
            # A successful probe is a 200 over HTTPS with `redirect: false` and a
            # valid chain — so scheme, status and cert validity are all implied
            # by it succeeding, and recorded so the page can show them (8006).
            {:ok,
             [
               %{kind: "certificate", location: "https://#{h}"},
               %{
                 kind: "environment_verification",
                 location: h,
                 identifier: "scheme=https status=200 cert_valid=true"
               }
             ]}

          {:error, reason} ->
            {:error,
             "#{h} did not answer over HTTPS with a valid certificate (#{reason}). " <>
               "Issuance needs DNS resolving to the server and the proxy reachable on 80."}
        end
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
         {:ok, domain} <- Resend.ensure_receiving_domain(scope, name, opts),
         {:ok, webhook} <- Resend.ensure_webhook(scope, endpoint, opts),
         {:ok, mx} <- publish_mx(scope, name, domain, opts) do
      {:ok,
       [
         %{kind: "receiving_domain", location: "resend/#{name}"},
         %{kind: "webhook", location: endpoint, identifier: webhook["id"]}
       ] ++ mx}
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
        |> Enum.reduce_while({:ok, []}, fn environment, {:ok, acc} ->
          bucket = Storage.bucket_name(project, environment)

          case Storage.ensure_bucket(bucket, credentials, opts) do
            {:ok, created} ->
              {:cont,
               {:ok,
                acc ++
                  [
                    %{
                      kind: "bucket",
                      location: created.location,
                      identifier: created.owner,
                      origin: created.origin
                    }
                  ]}}

            # The buckets already made are named in the failure, so a run
            # that dies on the second environment can still clean up the
            # first.
            {:error, reason} ->
              {:halt, {:error, format(reason), acc}}
          end
        end)
    end
  end

  def run(:backups, %Scope{} = scope, opts) do
    environment = Keyword.get(opts, :environment, "prod")
    project = project(scope)

    case Storage.credentials(scope, opts) do
      :none ->
        {:paused, Storage.credentials_instructions()}

      {:ok, credentials} ->
        bucket = Storage.bucket_name(project, environment)

        opts =
          opts
          |> Keyword.put(:bucket, bucket)
          |> Keyword.put(:credentials, credentials)

        with :ok <- require_script(scope, "bin/backup") do
          backups_outcome(Backups.run(env(scope), environment, opts), bucket)
        end
    end
  end


  # Named rather than silently succeeding — see the moduledoc.
  def run(key, _scope, _opts), do: {:error, {:not_implemented, key}}

  # The image a deploy runs, built now rather than when the project was made.
  #
  # Three ways in, and the order matters. An explicit `:image` wins, because a
  # criterion about deploying is not a criterion about building and should not
  # buy a builder to prove its point. Otherwise a build happens — but only when
  # one is configured: the deploy step predates the builder, and a project
  # whose image is already somewhere must keep deploying rather than start
  # failing on a builder nobody asked it to use.
  defp image_for(scope, environment, opts) do
    case {Keyword.get(opts, :image), Keyword.get(opts, :build)} do
      {reference, _} when is_binary(reference) ->
        {:ok, %{reference: reference, built: false}}

      {nil, nil} ->
        {:ok, :not_built}

      {nil, _build} ->
        build_image(scope, environment, opts)
    end
  end

  defp build_image(scope, environment, opts) do
    with {:ok, architecture} <- architecture_for(scope, environment, opts),
         {:ok, _bucket} <- Registry.ensure(scope, opts),
         {:ok, tag} <- image_tag(scope, opts),
         {:ok, build} <- Builder.build(scope, tag, Keyword.put(opts, :architecture, architecture)),
         {:ok, reference} <- Registry.reference(scope, tag, opts) do
      {:ok, %{reference: reference, built: true, architecture: build.architecture}}
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

  defp image_resources(%{reference: reference, built: true}),
    do: [%{kind: "published_image", location: reference, identifier: "built=true"}]

  defp image_resources(%{reference: reference}),
    do: [%{kind: "published_image", location: reference, identifier: "built=false"}]

  defp image_resources(:not_built), do: []

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

        {:ok, _unverified} -> {:halt, :absent}
        {:error, :not_found} -> {:halt, :absent}
        {:error, reason} -> {:halt, {:error, reason}}
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

        verify_sending_domain(scope, d, sending, created, opts)

      {:error, reason} ->
        {:error, format(reason)}
    end
  end

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
           "expects: " <> Enum.map_join(faulted, ", ", &"#{&1["type"]} #{&1["name"]}"),
         created}

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
  defp deploy_outcome(result, environment, host) do
    phases =
      [
        result.migrated_at && %{kind: "deploy_phase", location: "migrate", identifier: iso(result.migrated_at)},
        result.health_ok_at && %{kind: "deploy_phase", location: "swap", identifier: iso(result.health_ok_at)},
        %{kind: "live_version", location: to_string(result.live_version)}
      ]
      |> Enum.reject(&is_nil/1)

    case result do
      %{swapped_at: nil, reason: reason} ->
        failure = %{kind: "deploy_failure", location: reason, identifier: to_string(result.failed_phase)}
        {:error, reason, [failure | phases]}

      %{swapped_at: _} ->
        {:ok, [%{kind: "deployment", location: "#{environment}/#{host}"} | phases]}
    end
  end

  # What the deploy shipped, recorded so the page can show the running version
  # is traceable to the commit CI built (8005). Absent when the caller did not
  # supply it — a real deploy derives it from git + the registry config.
  defp version_resources(%{commit: commit, image: image, source: source}) do
    [%{kind: "deployed_version", location: image, identifier: "commit=#{commit} source=#{source}"}]
  end

  defp version_resources(_), do: []

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(_), do: nil

  defp backups_outcome({:ok, %{proof: proof} = result}, bucket) do
    {:ok,
     [
       %{kind: "dump", location: "#{bucket}/#{result.key}"},
       %{
         kind: "restore_proof",
         location: proof.target,
         identifier: "rows=#{proof.rows} proven_at=#{DateTime.to_iso8601(proof.proven_at)}"
       },
       %{kind: "retention", location: "#{result.retention_days} days"}
     ]}
  end

  defp backups_outcome({:error, reason}, _bucket), do: {:error, format(reason)}

  defp project(%Scope{active_project: project}), do: project
  defp env(%Scope{environment: environment}), do: environment

  defp domain(%Scope{active_project: %{domain: d}}) when is_binary(d) and d != "", do: d
  defp domain(_), do: nil

  # The project's environments, by name. `opts` still wins so a spex or a
  # caller can narrow the fan-out, but the default now comes from the project
  # rather than from a literal — which is what lets a project have a `qa`
  # environment, or one per story, without a code change here.
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
  defp repo_resource(repo, disposition \\ nil) do
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
  defp ensure_environment_servers(scope, opts, made) do
    scope
    |> EnvironmentRepository.list()
    |> Enum.reduce_while({:ok, made}, fn environment, {:ok, acc} ->
      name = server_name(scope, opts, environment.name)

      case Hetzner.ensure_server(scope, name, opts) do
        {:ok, server} ->
          ip = get_in(server, ["public_net", "ipv4", "ip"])

          # Halting on a failed write-back rather than discarding it. The box
          # exists at this point; if the row does not record it, nothing can
          # find it again — the page cannot show it and teardown cannot remove
          # it, so it leaks and the step still says done. A silent write is the
          # worst of the three outcomes.

          case EnvironmentRepository.put(scope, environment.name, %{server_name: name, ip: ip}) do
            {:ok, _environment} ->
              {:cont, {:ok, [server_resource(server, environment.name) | acc]}}

            {:error, reason} ->
              {:halt,
               {:error,
                "provisioned #{name} but could not record it against the #{environment.name} " <>
                  "environment: #{format(reason)}", acc}}
          end

        {:error, reason} ->
          {:halt, {:error, format(reason), acc}}
      end
    end)
  end

  # One record per environment, each pointing at that environment's own server.
  # Nothing here knows what an environment is called: the host was decided when
  # the environment was given one, so production landing on the apex is data
  # rather than a branch.
  #
  # An environment with no server yet is skipped rather than failed — a project
  # part-way through provisioning has real environments that are not live, and
  # pointing DNS at nothing would be worse than pointing at nothing yet.
  defp dns_records_for(scope, zone, environments, opts) do
    # Listed once for the whole zone, not once per environment.
    existing =
      case Cloudflare.list_dns_records(scope, zone["id"]) do
        {:ok, records} -> records
        _ -> []
      end

    environments
    |> Enum.filter(& &1.host)
    |> Enum.reduce_while({:ok, []}, fn environment, {:ok, acc} ->
      case environment_ip(scope, environment, opts) do
        nil ->
          {:cont, {:ok, acc}}

        ip ->
          case Cloudflare.ensure_dns_record(scope, zone["id"], environment.host, ip,
                 records: existing
               ) do
            {:ok, response} ->
              record = dns_resource(environment.host, ip, response, environment.name)

              # Confirmed against a public resolver, not against our own write.
              # A record that exists in the dashboard and does not resolve is
              # the classic DNS failure, and it looks identical to success from
              # the API's answer alone.
              verification =
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

              {:cont, {:ok, acc ++ [record] ++ verification}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
      end
    end)
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

  defp access_public_key(scope, name) do
    case ProjectSecrets.fetch_value(scope, "server_ssh_public_key") do
      {:ok, public} when is_binary(public) and public != "" ->
        {:ok, public}

      _ ->
        generate_access_key(scope, name)
    end
  end

  defp generate_access_key(scope, name) do
    dir = Path.join(System.tmp_dir!(), "cms-ssh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "id_ed25519")

    try do
      case System.cmd("ssh-keygen", ["-t", "ed25519", "-N", "", "-C", name, "-f", path],
             stderr_to_stdout: true
           ) do
        {_out, 0} ->
          private = File.read!(path)
          public = File.read!(path <> ".pub")

          ProjectSecrets.put_value(scope, "server_ssh_private_key", private)
          ProjectSecrets.put_value(scope, "server_ssh_public_key", public)

          {:ok, public}

        {out, status} ->
          {:error, "could not generate an access key (ssh-keygen exit #{status}): #{String.trim(out)}"}
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
    case Resend.mx_records(domain) do
      [] ->
        {:error,
         "Resend returned no MX record for #{name}, so there is nothing to publish — " <>
           "the domain cannot receive mail without one"}

      records ->
        base = base_domain(scope, opts)

        with {:ok, zone} <- Cloudflare.find_zone(scope, base) do
          Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
            record_name = qualify(record["name"], base)

            case Cloudflare.ensure_dns_record(scope, zone["id"], record_name, record["value"],
                   type: "MX",
                   priority: record["priority"]
                 ) do
              {:ok, _} ->
                {:cont,
                 {:ok,
                  acc ++
                    [
                      %{
                        kind: "mx_record",
                        location: "cloudflare/#{record_name}",
                        identifier: "#{record["value"]} priority #{record["priority"]}"
                      }
                    ]}}

              {:error, reason} ->
                {:halt, {:error, format(reason)}}
            end
          end)
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
    %{kind: "bucket", location: "#{location}.your-objectstorage.com/#{bucket}", identifier: "user"}
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
        case Sops.generate_key() do
          {:ok, {public, private}} ->
            ProjectSecrets.put_value(scope, age_key_name(environment), private)
            {:cont, {:ok, Map.put(acc, environment, public)}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    with {:ok, recipients} <- keys,
         :ok <- Sops.write_config(env, recipients) do
      {:ok,
       Enum.map(recipients, fn {environment, public} ->
         %{kind: "age_key", location: "secrets/#{environment}", identifier: public}
       end)}
    else
      {:error, reason} -> {:error, format(reason)}
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
  @spec recipients(Scope.t(), [String.t()]) :: [%{environment: String.t(), fingerprints: [String.t()]}]
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

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end
