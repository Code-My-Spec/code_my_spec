defmodule CodeMySpecSpex.Fixtures do
  @moduledoc """
  Approved bridge from spex tests into app-level DB setup.

  Specs can only reach into the app through this module. The boundary
  enforces it: `CodeMySpecSpex` depends on `CodeMySpecSpex.Fixtures`,
  not on `CodeMySpec` or `CodeMySpecTest` directly.

  Only surfaces fixtures for state that **originates server-side and
  syncs into the local app** — users, accounts, projects. Components
  and stories are surface-creatable through MCP tools, so spex tests
  drive them directly via `CodeMySpecSpex.ComponentHelpers` and
  `CodeMySpecSpex.StoryHelpers`. Local-only state
  (ProjectConfiguration, etc.) must be set up through the UI like
  any other user action.
  """
  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec,
      CodeMySpec.AgentHarness,
      CodeMySpec.Environments,
      CodeMySpec.Repo,
      CodeMySpecTest,
      CodeMySpecWeb
    ]

  alias CodeMySpec.{
    AccountsFixtures,
    AgentTasks,
    ArchitectureFixtures,
    BddSpecs,
    CodeGenerationFixtures,
    Components,
    EmbeddingsFixtures,
    EnvironmentFixtures,
    Environments,
    IntegrationsFixtures,
    IssuesFixtures,
    OauthFixtures,
    Paths,
    ProblemsFixtures,
    ProjectSecrets,
    ProjectsFixtures,
    ProjectSync,
    QaFixtures,
    QaIntegrationPlanFixtures,
    Sessions,
    SessionsFixtures,
    SetupFixtures,
    Stories,
    TechnicalStrategyFixtures,
    UserPreferences,
    Users,
    UsersFixtures
  }

  alias CodeMySpec.AgentHarness.ConversationRecorder
  alias CodeMySpec.AgentTasks.QaStory
  alias CodeMySpec.Analytics.GoogleAnalytics
  alias CodeMySpec.Architecture.SpecStub
  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Configurations
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Integrations.Integration
  alias CodeMySpec.Integrations.IntegrationRepository
  alias CodeMySpec.Mail.Email
  alias CodeMySpec.Mail.Mailbox
  alias CodeMySpec.Permissions.TapOut
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Provisioning.Cloudflare
  alias CodeMySpec.Provisioning.Dns
  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Provisioning.Repository
  alias CodeMySpec.Provisioning.Resend
  alias CodeMySpec.Provisioning.Resend
  alias CodeMySpec.Provisioning.Sequence
  alias CodeMySpec.Provisioning.StepRepository
  alias CodeMySpec.Provisioning.Steps
  alias CodeMySpec.Provisioning.Storage
  alias CodeMySpec.Provisioning.Teardown
  alias CodeMySpec.Provisioning.Wait
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.SetupFixtures.ErroringStep
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Conversations
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Users.User
  alias CodeMySpec.Workspaces.PreviewAddress
  alias CodeMySpec.Workspaces.Workspace
  alias CodeMySpec.Workspaces.WorkspacesRepository
  alias CodeMySpecTest.FakeWorkspaceRunner
  alias CodeMySpecTest.LocalPreviewRunner
  alias CodeMySpecTest.PreviewApp
  alias CodeMySpecTest.PreviewWsClient

  @doc """
  Register a sending domain and publish everything except its DKIM record.

  Produces the state criterion 8027 is about: a domain that is genuinely stuck
  with a *specific* fault, rather than one where nothing resolves. Reading a
  healthy account and asserting the unhappy path proves nothing, and inventing
  the record set would encode what I think Resend asks for rather than what it
  does.

  Returns the resources it created so the caller can remove them — the Resend
  domain and every DNS record published for it.
  """
  @spec publish_all_records_except_dkim(Scope.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def publish_all_records_except_dkim(scope, sending_domain) do
    publish_records(scope, sending_domain, :except_dkim)
  end

  @doc """
  Register a sending domain at Resend and publish nothing.

  The split criterion 8029 needs: the domain has to exist for the page to show
  a mail section at all, but its records must not be published, because
  publishing them is the step's job and the criterion is about what that
  publishing disturbs.
  """
  @spec register_sending_domain_only(Scope.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def register_sending_domain_only(scope, sending_domain) do
    Resend.ensure_domain(scope, sending_domain)
  end

  @doc """
  A project whose blog can actually be published.

  `ensure_publishable/1` refuses to start without a content bucket, a client
  API url and a deploy key — sync is trigger-only, so publishing into a project
  with no reachable client would put files in a bucket nothing is ever told
  about. A criterion whose premise is "Sam has a post ready" is asserting those
  exist; without them the publish reports `trigger_failed` and the criterion
  fails on its own setup rather than on what it is testing.
  """
  # One bucket, named the same every run.
  #
  # This used to be `spex-content-#{unique_integer}`, and the bucket name goes
  # into the request URI — so every recording baked in a name that could never
  # occur again, and the cassette it produced could not match anything on
  # replay. A per-run name is right for a resource a spex creates and destroys;
  # it is wrong for one that has to be recognisable in a recording.
  #
  # Publishing signs against the global `:ex_aws` config, which is the user's
  # own AWS account by design (story 712 — the local CLI is the publisher).
  # This is the bucket a recording session writes to there.
  @content_bucket "cms-spex-content"

  # The bucket lives on Hetzner, so the publish has to be told to sign against
  # Hetzner. Without an endpoint ExAws defaults to Amazon, and a recording of a
  # publish captured `NoSuchBucket` from a provider that had never heard of the
  # bucket — a 404 written into a cassette as the story's expected behaviour.
  #
  # Same host `record_content_bucket/2` reports the bucket at, so the thing
  # that makes it and the thing that writes to it cannot disagree.
  @content_endpoint "fsn1.your-objectstorage.com"

  @spec publishable_project(map(), map(), map()) :: map()
  def publishable_project(scope, project, attrs \\ %{}) do
    {:ok, project} =
      CodeMySpec.Projects.update_project(
        scope,
        project,
        Map.merge(
          Map.merge(
            %{
              # Where the posts are. Without it the publish's snapshot pass
              # has nowhere to read from and returns `:no_source_path`, so the
              # post a criterion just wrote to the environment was never in
              # what got published.
              content_source_path: "content",
              content_bucket: @content_bucket,
              s3_endpoint: @content_endpoint,
              client_api_url: "https://#{project.domain || "example.com"}/api",
              deploy_key: "dk_spex_#{System.unique_integer([:positive])}"
            },
            content_s3_credentials()
          ),
          attrs
        )
      )

    record_content_bucket(scope, project)

    project
  end

  # The keys the publish signs with, on the project itself.
  #
  # `ContentPublishing` reads the project's own columns — a published install
  # signs uploads without a global `:ex_aws` env — while `Storage.credentials/2`
  # reads project *secrets*. Seeding only the secrets left the bucket created on
  # Hetzner and the publish signed with nothing, which Hetzner answers
  # `InvalidAccessKeyId`. Both halves have to point at the same account.
  #
  # Real values when recording, placeholders otherwise: on replay the cassette
  # answers and the credential never leaves the VM, and a recording made with a
  # placeholder is a cassette full of 403s that replays perfectly and proves
  # nothing.
  defp content_s3_credentials do
    %{
      aws_access_key_id: System.get_env("HETZNER_S3_ACCESS_KEY_ID", "spex-placeholder-id"),
      aws_secret_access_key:
        System.get_env("HETZNER_S3_SECRET_ACCESS_KEY", "spex-placeholder-secret"),
      aws_region: "fsn1"
    }
  end

  # The bucket this names does not exist yet — the first publish creates it —
  # and until now nothing recorded that, so `tear_down_after(scope, [:storage])`
  # found no resource and removed nothing. Recording a spex left a real bucket
  # on the account with a random name and no owner, once per recording.
  #
  # Written as a `:storage` step resource rather than as bespoke cleanup in each
  # spex, because that is where `Provisioning.Teardown` already looks and it
  # knows how to empty a bucket before deleting it. Every spex using this
  # fixture gets the cleanup by asking for the step it already implies.
  defp record_content_bucket(_scope, %{content_bucket: nil}), do: :ok

  defp record_content_bucket(scope, project) do
    location = "#{endpoint_host(project.s3_endpoint)}/#{project.content_bucket}"

    maybe_create_bucket(scope, project)

    StepRepository.upsert(scope, :storage, %{
      state: :done,
      position: Sequence.position(:storage),
      resources: [%{kind: "bucket", location: location, identifier: "user"}]
    })

    :ok
  end

  # Recording needs the bucket to exist; replay does not.
  #
  # The fixture names a bucket and marks the `:storage` step done, which on
  # replay is the whole truth — the cassette answers the publish and no bucket
  # is involved. Recording puts real objects, so the bucket has to be there or
  # the publish fails with `publish_failed`, which is what it did.
  #
  # Creating it only while recording keeps replay offline. It is created *and*
  # recorded as a resource in the same breath, so teardown removes exactly what
  # this made — the pairing is the point, and doing one without the other is
  # how the account collected orphans in the first place.
  defp maybe_create_bucket(scope, project) do
    cond do
      System.get_env("SPEX_CASSETTE_MODE") != "record" ->
        :ok

      # Storage that is not Hetzner's has its own bucket and its own keys, and
      # provisioning them is not this fixture's job. `publishing_to_the_fleet/1`
      # points at the local MinIO, and this reached for Hetzner regardless — so
      # recording a purely local publish refused for want of an account it never
      # touches, and would have created the bucket in the wrong place if it had
      # one.
      not hetzner_storage?(project.s3_endpoint) ->
        :ok

      true ->
        seed_storage_secrets!(scope)
        create_bucket!(scope, project.content_bucket)
    end
  end

  defp hetzner_storage?(endpoint) when is_binary(endpoint),
    do: String.contains?(endpoint, "your-objectstorage.com")

  defp hetzner_storage?(_endpoint), do: true

  defp endpoint_host(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{host: host, port: port} when is_binary(host) and is_integer(port) ->
        "#{host}:#{port}"

      %URI{host: host} when is_binary(host) ->
        host

      _ ->
        endpoint
    end
  end

  defp endpoint_host(_endpoint), do: "fsn1.your-objectstorage.com"

  # `Storage.credentials/2` reads project secrets, not the environment — Hetzner
  # issues object-storage keys only in its console, so the project is where they
  # live and `envs/.env` is where a recording keeps them. A fresh spex project
  # has neither, which is why `credentials/2` answered `:none` and the publish
  # failed as `publish_failed` without anything saying why.
  defp seed_storage_secrets!(scope) do
    for {key, env} <- [
          {"hetzner_s3_access_key_id", "HETZNER_S3_ACCESS_KEY_ID"},
          {"hetzner_s3_secret_access_key", "HETZNER_S3_SECRET_ACCESS_KEY"}
        ] do
      case System.get_env(env) do
        value when is_binary(value) and value != "" ->
          {:ok, _} = ProjectSecrets.put_value(scope, key, value)

        _ ->
          raise "recording needs #{env}; export envs/.env first (`set -a; source envs/.env`)"
      end
    end

    :ok
  end

  # Loud on every branch. A silent `:ok` when credentials are missing leaves the
  # publish to fail later as `publish_failed`, which names the symptom and hides
  # that nothing ever tried to make the bucket.
  defp create_bucket!(scope, bucket) do
    credentials =
      case Storage.credentials(scope, []) do
        :none ->
          raise "recording needs Hetzner S3 credentials to create #{bucket}, and " <>
                  "Storage.credentials/2 returned :none — check envs/.env is exported"

        {:ok, credentials} ->
          credentials

        credentials when is_list(credentials) ->
          credentials
      end

    case Storage.ensure_bucket(bucket, credentials, []) do
      {:ok, _} -> :ok
      :ok -> :ok
      other -> raise "could not create #{bucket} for recording: #{inspect(other)}"
    end
  end

  @doc """
  An app access token for the project, minted the way the deployed app gets one.

  Provisioning hands the app a refresh secret (the `callback_credential`
  step); the app exchanges it for a short-lived access token and uses that to
  ask for a browser-safe socket token. Going through `exchange/1` rather than
  reaching for the private mint keeps a spex on the same path the app takes —
  and the boundary requires it either way, since `CodeMySpecSpex` may not
  reference `CodeMySpec` directly.
  """
  @spec app_access_token(map()) :: String.t()
  def app_access_token(project) do
    secret = "cms_refresh_#{System.unique_integer([:positive])}"
    {:ok, _project} = CodeMySpec.AppTokens.put_refresh_secret(project, secret)
    {:ok, token, _expires_in} = CodeMySpec.AppTokens.exchange(secret)
    token
  end

  @doc """
  Give the account an SSH access key, generated for real.

  The server step generates one when the account has none, and generation
  shells out to `ssh-keygen` — which a shell cassette replays as exit 0 without
  creating the key files, so the `File.read!` that follows fails with "could
  not read file". The command is recorded; its side effect on disk is not.

  Staging the key means the step adopts one instead of generating one, which is
  also the truthful precondition: an account that has provisioned anything
  before already has this. Generated rather than hardcoded because a recording
  hands it to a real Hetzner box.
  """
  @spec account_access_key(Scope.t()) :: :ok
  def account_access_key(scope) do
    dir = Path.join(System.tmp_dir!(), "spex-ssh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "id_ed25519")

    try do
      {_out, 0} =
        System.cmd("ssh-keygen", ["-t", "ed25519", "-N", "", "-C", "spex", "-f", path],
          stderr_to_stdout: true
        )

      CodeMySpec.AccountSecrets.put_value(scope, "server_ssh_private_key", File.read!(path))

      CodeMySpec.AccountSecrets.put_value(
        scope,
        "server_ssh_public_key",
        File.read!(path <> ".pub")
      )

      :ok
    after
      File.rm_rf(dir)
    end
  end

  @doc "Remove a sending domain from Resend, for the register-only teardown."
  @spec remove_sending_domain(Scope.t(), String.t()) :: :ok
  def remove_sending_domain(scope, sending_domain) do
    alias CodeMySpec.Provisioning.Resend

    with {:ok, %{"id" => id}} <- Resend.find_domain(scope, sending_domain) do
      Resend.delete_domain(scope, id)
    end

    :ok
  end

  @doc """
  Publish every record, then delete the DKIM — the state 8027 is now grounded
  on.

  The deletion is what makes this stick. The step publishes whatever is
  missing, so a record that was merely never written comes straight back and
  the domain verifies; a record that was *deleted* leaves its absence in a
  recursive resolver's cache for the zone's SOA negative TTL, which outlasts
  the verification window. That is also the real story — somebody tidying DNS
  who does not recognise `resend._domainkey`.

  Returns the same shape as `publish_all_records_except_dkim/2`, with the DKIM
  still listed: it existed, so teardown should still look for it.
  """
  @spec publish_then_delete_dkim(Scope.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def publish_then_delete_dkim(scope, sending_domain) do
    alias CodeMySpec.Provisioning.Cloudflare

    with {:ok, created} <- publish_records(scope, sending_domain, :all),
         {:ok, records} <- Cloudflare.list_dns_records(scope, created.zone_id) do
      records
      |> Enum.filter(&String.contains?(&1["name"], "_domainkey"))
      |> Enum.each(&Cloudflare.delete_dns_record(scope, created.zone_id, &1["id"]))

      {:ok, created}
    end
  end

  # Resend labels the inbound MX `Receiving`, and only that. An earlier version
  # also treated a record with an empty or missing name as inbound, which
  # excused a *sending* record whose name Resend had not sent — so a domain
  # that had not verified was reported ready and criterion 8032 failed on the
  # premise that sending works.
  defp inbound_record?(record), do: record["record"] == "Receiving"

  defp publish_records(scope, sending_domain, which, opts \\ []) do
    alias CodeMySpec.Provisioning.{Cloudflare, Resend}

    zone_name = sending_domain |> String.split(".") |> Enum.take(-2) |> Enum.join(".")

    # Receiving is granted at creation or not at all — `POST /domains` takes
    # `capabilities`, and `PATCH /domains/:id` has no field to turn it on
    # afterwards. So a criterion that needs an inbox has to say so *here*,
    # before the domain exists. Registering it sending-only first and asking
    # later is unrecoverable: story 974's probes were accepted and then
    # silently dropped, because the domain they were addressed to had
    # `receiving: "disabled"` from the moment it was made.
    ensure =
      if Keyword.get(opts, :receiving, false),
        do: &Resend.ensure_receiving_domain/2,
        else: &Resend.ensure_domain/2

    with {:ok, domain} <- ensure.(scope, sending_domain),
         {:ok, full} <- Resend.get_domain(scope, domain["id"]),
         {:ok, zone} <- Cloudflare.find_zone(scope, zone_name) do
      records = Resend.records(full["data"] || full)

      keep =
        case which do
          :all -> records
          :except_dkim -> Enum.reject(records, &dkim?/1)
        end

      published =
        keep
        |> Enum.map(fn record ->
          name = qualify(record["name"], zone_name)

          # Raise rather than ignore. This used to discard the result, so a
          # record Cloudflare refused simply never existed — and every
          # assertion downstream failed with "does not resolve", which is true
          # and says nothing about why.
          case Cloudflare.ensure_dns_record(scope, zone["id"], name, record["value"],
                 type: record["type"],
                 priority: record["priority"]
               ) do
            {:ok, _} ->
              :ok

            other ->
              raise "could not publish #{record["type"]} #{name}: #{inspect(other, limit: 5)}"
          end

          %{kind: "dns_record", location: "cloudflare/#{name}", type: record["type"]}
        end)

      # Deliberately NOT probing the records over DNS-over-HTTPS here. Asking a
      # recursive resolver for a record that was written a moment ago caches
      # the *absence* of it for the zone's SOA negative TTL — 1800s — so the
      # probe intended to confirm propagation was the very thing that hid the
      # record from every check afterwards.

      # Resend evaluates a record only when asked. Without this the domain sits
      # at "pending" on every record — including the ones that are published
      # and resolving — so a criterion about *which* record is at fault sees no
      # difference between them. Triggering once lets the provider mark the
      # propagated records verified and leave the withheld one pending, which
      # is the state under test.
      Resend.verify_domain(scope, domain["id"])
      await_partial_verification(scope, domain["id"])

      {:ok,
       %{
         domain_id: domain["id"],
         zone_id: zone["id"],
         published: published,
         withheld: (records -- keep) |> Enum.map(& &1["name"])
       }}
    end
  end

  # Resend does not update record statuses synchronously with the verify call.
  # Wait until at least one record has flipped to verified, re-triggering as we
  # go — that is the state the withheld-record criteria are about, and reading
  # too early shows everything pending, which is indistinguishable from nothing
  # having been published.
  defp await_partial_verification(scope, domain_id, attempts \\ 20) do
    Enum.reduce_while(1..attempts, :ok, fn attempt, _acc ->
      case Resend.get_domain(scope, domain_id) do
        {:ok, body} ->
          body["data"]
          |> Kernel.||(body)
          |> Resend.records()
          |> Enum.any?(&(&1["status"] == "verified"))
          |> verified_or_wait(scope, domain_id, attempt)

        _ ->
          wait_a_beat()
          {:cont, :ok}
      end
    end)
  end

  defp verified_or_wait(true, _scope, _domain_id, _attempt), do: {:halt, :ok}

  defp verified_or_wait(false, scope, domain_id, attempt) do
    nudge_every_fifth(rem(attempt, 5), scope, domain_id)
    wait_a_beat()
    {:cont, :ok}
  end

  defp nudge_every_fifth(0, scope, domain_id), do: Resend.verify_domain(scope, domain_id)
  defp nudge_every_fifth(_remainder, _scope, _domain_id), do: :ok

  # Through `Wait`, like every other pause in the provisioning path. A direct
  # sleep here waited three seconds per attempt on replay too, where the answer
  # is already recorded and there is nothing to wait for — twenty-one seconds
  # per domain, which was the whole of story 969's runtime and hid behind
  # provider calls that turned out to cost under half a second.
  defp wait_a_beat, do: Wait.sleep(3_000)

  defp dkim?(record) do
    String.contains?(String.upcase(to_string(record["record"] || "")), "DKIM") or
      String.contains?(to_string(record["name"] || ""), "_domainkey")
  end

  defp qualify(name, zone) when name in [nil, "", "@"], do: zone
  defp qualify(name, zone), do: "#{name}.#{zone}"

  @doc "The sending domain an environment uses, so spex need not know the rule."
  @spec sending_domain(String.t(), String.t()) :: String.t()
  def sending_domain(base, environment),
    do: Resend.sending_domain(base, environment)

  @doc """
  Register a sending domain and publish every record it asks for.

  The happy-path counterpart: a domain that genuinely verifies, because its
  records genuinely resolve. Needed because setup registers a sending domain
  per environment and is not satisfied until all of them verify — so a
  recording of the successful path has to make UAT real too, not just
  production.
  """
  @spec publish_all_records(Scope.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def publish_all_records(scope, sending_domain, opts \\ []) do
    with {:ok, created} <- publish_records(scope, sending_domain, :all, opts) do
      # Publishing is not verifying. A `given_` that says "the domain is
      # verified" and only publishes records leaves it pending, and Resend
      # answers 403 to a send from a pending domain — so the spex fails on an
      # assertion about sending for a reason that is entirely about setup.
      #
      # Resend does not re-check on its own either; `poll_until_verified`
      # triggers the check and waits for it.
      case Resend.poll_until_verified(scope, created.domain_id, opts) do
        {:ok, _} ->
          {:ok, created}

        # Enabling receiving adds a `Receiving` MX to the domain's records, and
        # it verifies on its own schedule — slower than the sending set, and
        # sometimes past any window worth waiting in a recording. Blocking on
        # it here is also the wrong shape: what this fixture owes its callers
        # is a domain that can *send* so the mail section renders, and proving
        # the inbox is the inbound step's job (`await_inbound_verified/4`),
        # which is the criterion under test.
        #
        # So an inbound record still verifying is not a failed premise. A
        # sending record still verifying is.
        {:error, {:still_verifying, pending}} ->
          if Enum.all?(pending, &inbound_record?/1) do
            {:ok, created}
          else
            {:error, {:never_verified, sending_domain, {:still_verifying, pending}}}
          end

        {:error, reason} ->
          {:error, {:never_verified, sending_domain, reason}}
      end
    end
  end

  @doc """
  Publish every record the provider asks for, but do **not** wait for it to
  verify.

  For "setup waits for verification rather than assuming it": if the fixture
  verifies the domain first, the step finds it already verified on its first
  look and there is nothing left to wait for — the criterion then asserts
  polling against a run that never had to poll.
  """
  @spec publish_all_records_unverified(Scope.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def publish_all_records_unverified(scope, sending_domain) do
    publish_records(scope, sending_domain, :all)
  end

  @doc "Remove what `publish_all_records_except_dkim/2` created."
  @spec remove_published_records(Scope.t(), map()) :: :ok
  def remove_published_records(scope, %{
        domain_id: domain_id,
        zone_id: zone_id,
        published: published
      }) do
    alias CodeMySpec.Provisioning.{Cloudflare, Resend}

    with {:ok, records} <- Cloudflare.list_dns_records(scope, zone_id) do
      names = MapSet.new(published, &String.replace(&1.location, "cloudflare/", ""))

      for %{"id" => id, "name" => name} <- records, MapSet.member?(names, name) do
        Cloudflare.delete_dns_record(scope, zone_id, id)
      end
    end

    Resend.delete_domain(scope, domain_id)
    :ok
  end

  @doc """
  Publish an MX at the zone apex, as a domain already receiving mail would
  have. Returns the record so a caller can assert it survived.
  """
  @spec publish_apex_mx(Scope.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def publish_apex_mx(scope, domain) do
    alias CodeMySpec.Provisioning.Cloudflare

    # The *project's* apex, not the Cloudflare zone root. These used to be the
    # same thing, so a spex asserting "Sam already receives mail here" published
    # an MX on `astralbi.com` itself — a record shared by every other spex in
    # the account, left behind afterwards, and read by them as an apex MX of
    # their own. Criterion 8025 saw it as a bounce MX at `@` and failed on a
    # record it had never written.
    with {:ok, zone} <- Cloudflare.find_zone(scope, domain),
         {:ok, _} <-
           Cloudflare.ensure_dns_record(scope, zone["id"], domain, "inbound-smtp.spex.invalid",
             type: "MX",
             priority: 10
           ) do
      {:ok, %{zone_id: zone["id"], name: domain}}
    end
  end

  @dns_table "test/cassettes/dns_resolutions.json"

  @doc """
  A resolver for `ProvisioningLive` that is honest while recording and
  deterministic while replaying.

  DNS resolution cannot go in a cassette: the authoritative lookup setup needs
  is a syscall, not HTTP, and it has to stay authoritative because a recursive
  resolver caches the *absence* of a record for the zone's negative TTL (1800s
  here) — long after setup published it. So while recording, this asks real
  DNS and writes the answer down; while replaying, it reads the answer back.
  The recorded claim is a real one, and it stops being re-asked of the world
  once the records it was about have been torn down.
  """
  @spec dns_resolver(:record | :replay) :: (String.t(), atom() -> boolean())
  def dns_resolver(:record) do
    fn name, type ->
      resolved = Dns.lookup_authoritative(name, type) != []
      remember_resolution(name, type, resolved)
      resolved
    end
  end

  def dns_resolver(:replay) do
    table = read_resolutions()
    fn name, type -> Map.get(table, key(name, type), false) end
  end

  defp key(name, type), do: "#{name}|#{type}"

  defp read_resolutions do
    case File.read(@dns_table) do
      {:ok, body} -> Jason.decode!(body)
      _ -> %{}
    end
  end

  defp remember_resolution(name, type, resolved) do
    table = read_resolutions() |> Map.put(key(name, type), resolved)
    File.mkdir_p!(Path.dirname(@dns_table))
    File.write!(@dns_table, Jason.encode_to_iodata!(table, pretty: true))
  end

  @doc "Remove the apex MX `publish_apex_mx/2` wrote, so it does not outlive the spex."
  @spec remove_apex_mx(Scope.t(), String.t()) :: :ok
  def remove_apex_mx(scope, domain) do
    alias CodeMySpec.Provisioning.Cloudflare

    with {:ok, zone} <- Cloudflare.find_zone(scope, domain),
         {:ok, records} <- Cloudflare.list_dns_records(scope, zone["id"]) do
      for %{"id" => id, "name" => name, "type" => "MX"} <- records, name == domain do
        Cloudflare.delete_dns_record(scope, zone["id"], id)
      end
    end

    :ok
  end

  @doc """
  Register a refresh secret against the project, as the `callback_credential`
  step does when it provisions one.

  Story 971's spex POST a known secret to `/api/token`. Until it is registered
  the exchange refuses it, and every one of those spex fails in `given_` with
  a 401 that reads like the endpoint is broken.
  """
  @spec register_refresh_secret(Scope.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def register_refresh_secret(scope, secret) do
    CodeMySpec.AppTokens.put_refresh_secret(scope.active_project, secret)
  end

  @doc "The domain currently on a project, for diagnosing setup preconditions."
  def project_domain(project_id) do
    CodeMySpec.Repo.get!(CodeMySpec.Projects.Project, project_id).domain
  end

  @doc """
  Remove everything the named provisioning steps recorded creating.

  Here rather than in the spex Case because the boundary says so: spex reach
  the app only through this module. That is worth keeping for teardown
  especially — it is the one operation that destroys, so having exactly one
  door to it is the point rather than an inconvenience.
  """
  @spec tear_down_steps(Scope.t(), [atom()], keyword()) :: [{atom(), term()}]
  def tear_down_steps(scope, keys, opts \\ []) do
    Enum.map(keys, fn key ->
      {key, Teardown.step(scope, key, opts)}
    end)
  end

  @doc """
  Connect an OAuth provider for the scope's user.

  ## Why this is a fixture rather than a UI action

  Every other piece of spex setup is driven through the app's own surface.
  This cannot be: connecting a provider means a redirect to Cloudflare or
  GitHub, a human consent screen, and a callback carrying a code only they can
  mint. The alternative to a fixture is not "drive it properly" — it is having
  no spex for anything that touches a provider.

  The token is deliberately a placeholder. Provider HTTP in spex is served
  from a cassette, so what matters is that the credential *lookup* succeeds;
  a real token here would be a secret in the repository for no benefit.
  """
  @spec connect_provider(Scope.t(), atom(), keyword()) :: {:ok, term()}
  def connect_provider(scope, provider, opts \\ []) do
    IntegrationRepository.upsert_integration(scope, provider, %{
      access_token: Keyword.get(opts, :access_token, "spex-placeholder-token"),
      refresh_token: Keyword.get(opts, :refresh_token, "spex-placeholder-refresh"),
      expires_at: Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 3600, :second)),
      granted_scopes: Keyword.get(opts, :granted_scopes, []),
      provider_metadata: %{
        provider_user_id: "spex",
        email: "spex@example.com",
        name: "Spex User"
      }
    })
  end

  @doc "Remove a provider connection, for the revoked-credential cases."
  @spec disconnect_provider(Scope.t(), atom()) :: :ok
  def disconnect_provider(scope, provider) do
    CodeMySpec.Integrations.delete_integration(scope, provider)
    :ok
  end

  def generate_user_session_token(user), do: Users.generate_user_session_token(user)

  def select_active_account(scope, account_id),
    do: UserPreferences.select_active_account(scope, account_id)

  def select_active_project(scope, project_id),
    do: UserPreferences.select_active_project(scope, project_id)

  defdelegate google_integration_fixture(user, attrs \\ %{}), to: IntegrationsFixtures

  defdelegate find_or_register_oauth_user(provider, attrs), to: Users
  defdelegate find_or_register_oauth_user(provider, attrs, opts), to: Users

  defdelegate dispatch_analytics_event(event, payload), to: CodeMySpec.Analytics, as: :dispatch

  defdelegate mark_cli_first_connected(user), to: UsersFixtures

  # -- Environments --
  defdelegate memory_environment_fixture(opts \\ []), to: EnvironmentFixtures
  defdelegate local_environment_fixture(opts \\ []), to: EnvironmentFixtures
  defdelegate register_environment(project_id, env), to: Environments, as: :register
  defdelegate unregister_environment(project_id), to: Environments, as: :unregister

  @doc """
  Returns the framework rule filenames the harness ships in `priv/rules/`.

  Bridges the real package directory so install spex can assert "every
  framework rule was copied" without reaching into `File` themselves.
  """
  @spec framework_rule_files() :: [String.t()]
  def framework_rule_files do
    :code_my_spec
    |> Application.app_dir("priv/rules")
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".md"))
    |> Enum.sort()
  end

  # -- Paths (conventional project resource paths) --
  defdelegate base_dir(), to: Paths
  defdelegate proposal_path(), to: Paths
  defdelegate spec_file(module_path), to: Paths

  # -- Project Sync (file-change events) --
  @doc """
  Synthesizes the "a file changed" event the file watcher fires in
  production. Takes a relative path inside the scope's project tree;
  resolves to absolute via `scope.cwd`. Runs the same orchestration
  the OS watcher would: classify + upsert/delete the File row, refresh
  fingerprint, fan out to ComponentSync, broadcast on the watcher
  PubSub topic.
  """
  @spec notify_file_changed(Scope.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def notify_file_changed(%Scope{} = scope, rel_path) when is_binary(rel_path) do
    ProjectSync.Sync.sync_path(scope, Path.join(scope.cwd, rel_path))
  end

  @doc """
  The harness's side of the wire, for Story 987.

  Scans the working copy with the real `Scanner.observe/2` — the same function
  the harness runs, kept identical by cms_scan's drift test — serialises the
  result the way the harness does, and pushes it through the **real channel
  handler**.

  Going through the channel is the whole point. An earlier version of this
  bridge called `FileSync.reconcile/2` and `ComponentSync.sync_from_files/1`
  directly, which meant it reimplemented the behaviour under test: the spex
  passed against code where the channel never called `ComponentSync` at all, so
  they proved the bridge worked and nothing else.

  The read model defaults to **empty**, because that is what a sprite holds. It
  fetches once on join, before the project has any stories or components, so
  every ownership decision made from the harness's copy is made against nothing.
  Passing a populated one would hide exactly the bug this story is about.
  """
  def deliver_manifest(%Scope{} = scope, opts \\ []) do
    read_model = Keyword.get(opts, :read_model, %Scanner.ReadModel{})

    {:ok, entries} = Scanner.observe(scope.environment, read_model)
    observations = Enum.map(entries, &serialize_observation/1)

    socket = %Phoenix.Socket{assigns: %{scope: scope}}

    {:reply, reply, _socket} =
      CodeMySpecWeb.HarnessProjectChannel.handle_in(
        "observations",
        %{"observations" => observations},
        socket
      )

    reply
  end

  @doc """
  Deliver a completed model turn the way a sprite's harness does.

  The proxy that produces this lives in `cms_harness` and runs on the sprite,
  so a spec here cannot dispatch to it — and should not want to. What the
  server owns is what it does with a turn once it arrives, which is exactly
  what arrives on this channel. Same reasoning as `deliver_manifest/2`.
  """
  def record_turn(%Scope{} = scope, request, response, opts \\ []) do
    socket = %Phoenix.Socket{assigns: %{scope: scope}}

    {:noreply, _socket} =
      CodeMySpecWeb.HarnessProjectChannel.handle_in(
        "record_turn",
        %{
          "session_id" => Keyword.get(opts, :session_id, "sprite"),
          "agent_role" => Keyword.get(opts, :agent_role, "main"),
          "request" => request,
          "response" => response
        },
        socket
      )

    :ok
  end

  @doc """
  Store a tool call the way the in-app chat does, rather than the way the
  recorder does.

  Two writers put a call in a conversation and disagree about its shape: the
  recorder writes a `role: :tool` message whose text is the tool and its
  arguments; the chat path writes an assistant message with a `tool_calls`
  array. A spex about both has to produce both, and reaching the domain
  directly from a spex crosses a boundary the analyzer forbids — so the bridge
  does it.
  """
  @spec chat_tool_call(Scope.t(), String.t(), String.t(), map()) :: :ok
  def chat_tool_call(%Scope{} = scope, call_id, name, arguments) do
    {:ok, conversation} = spex_agent_conversation(scope)
    {:ok, _} = Conversations.add_tool_call(conversation, call_id, name, arguments)
    :ok
  end

  @doc """
  Store a tool result the way the chat path does — `role: :tool`, the same role
  the recorder uses for a *call*. That collision is what criterion 2374 is
  about, so a spex has to be able to create it.
  """
  @spec chat_tool_result(Scope.t(), String.t(), String.t(), String.t()) :: :ok
  def chat_tool_result(%Scope{} = scope, call_id, name, text) do
    {:ok, conversation} = spex_agent_conversation(scope)
    {:ok, _} = Conversations.add_tool_result(conversation, call_id, name, text)
    :ok
  end

  defp spex_agent_conversation(%Scope{} = scope) do
    Conversations.find_or_create_agent_conversation(
      scope.active_account_id,
      scope.active_project_id,
      "sprite"
    )
  end

  @doc """
  Report a turn whose recording fails.

  Exercises the recorder directly rather than through the channel: the failure
  under test is the store's, and the channel has no opinion about it.
  """
  def record_turn_with_broken_store(%Scope{} = scope, request, response) do
    ConversationRecorder.record_turn(
      scope.active_account_id,
      scope.active_project_id,
      "sprite",
      request,
      response,
      "main",
      store: :unwritable
    )
  end

  @doc "An Anthropic-shaped response body, for a spec that needs one."
  def model_response(blocks) when is_list(blocks) do
    %{
      "id" => "msg_spex",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-opus-5",
      "content" => blocks,
      "stop_reason" => "end_turn"
    }
  end

  def text_block(text), do: %{"type" => "text", "text" => text}

  def tool_block(name, input),
    do: %{"type" => "tool_use", "id" => "toolu_spex", "name" => name, "input" => input}

  def user_request(content) do
    %{
      "model" => "claude-opus-5",
      "max_tokens" => 256,
      "messages" => [%{"role" => "user", "content" => content}]
    }
  end

  # -- Migration (Story 991) --------------------------------------------------

  @doc """
  Build the payload a local harness sends when migrating a project.

  Local ids are whatever the caller says they are — the point of the wire
  format is that the cloud does not trust them, so a spec is free to use small
  integers and strings that make the references readable.
  """
  def migration_payload(opts \\ []) do
    %{
      "stories" => stringify_all(Keyword.get(opts, :stories, [])),
      "rules" => stringify_all(Keyword.get(opts, :rules, [])),
      "criteria" => stringify_all(Keyword.get(opts, :criteria, [])),
      "personas" => stringify_all(Keyword.get(opts, :personas, [])),
      "persona_stories" => stringify_all(Keyword.get(opts, :persona_stories, [])),
      "epics" => stringify_all(Keyword.get(opts, :epics, []))
    }
  end

  @doc """
  Author a story the way Sam does, so a spec can migrate real records rather
  than a payload it wrote itself.
  """
  def authored_story(%Scope{} = scope, title, opts \\ []) do
    {:ok, story} =
      CodeMySpec.Stories.create_story(scope, %{
        title: title,
        story: Keyword.get(opts, :story, "As Sam, I want #{title}, so that reasons.")
      })

    story
  end

  @doc """
  A second project to migrate into.

  Story 991 has two ends and they are different projects. A spec that uses one
  project as both cannot observe anything the migration does — the rows it
  reads and the rows it writes are the same rows.
  """
  def other_project_scope(%Scope{} = scope, name) do
    project = CodeMySpec.ProjectsFixtures.project_fixture(scope, %{name: name})
    %{scope | active_project: project, active_project_id: project.id}
  end

  @doc "Read the local project the way the migration does."
  def exported(%Scope{} = scope), do: CodeMySpec.Migration.export_project(scope)

  @doc "The kinds the cloud recomputes instead of carrying over."
  def derived_kinds, do: CodeMySpec.Migration.derived_kinds()

  @doc "Read a story back off the local harness."
  def local_story(%Scope{} = scope, id), do: CodeMySpec.Stories.get_story(scope, id)

  @doc "Put an account on a paid plan — story 991's precondition."
  def paid(%Scope{} = scope) do
    account =
      scope.active_account |> Ecto.Changeset.change(%{plan: :paid}) |> CodeMySpec.Repo.update!()

    %{scope | active_account: account}
  end

  @doc "Migrate a project the way the local harness does — through the endpoint."
  def migrate(%Scope{} = scope, payload) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.assign(:current_scope, scope)
    |> CodeMySpecWeb.MigrationsController.create(payload)
  end

  def cloud_stories(%Scope{} = scope) do
    case CodeMySpec.Stories.list_project_stories(scope) do
      {:ok, stories} -> stories
      stories when is_list(stories) -> stories
      _ -> []
    end
  end

  def cloud_story(%Scope{} = scope, title),
    do: scope |> cloud_stories() |> Enum.find(&(&1.title == title))

  def cloud_rule(%Scope{} = scope, story, statement) do
    scope
    |> CodeMySpec.BddRules.list_rules_for_story(story.id)
    |> Enum.find(&(&1.statement == statement))
  end

  def cloud_criteria(%Scope{} = scope, story),
    do: CodeMySpec.AcceptanceCriteria.list_story_criteria(scope, story.id)

  defp stringify_all(records), do: Enum.map(records, &stringify/1)

  defp stringify(record) when is_map(record),
    do: Map.new(record, fn {k, v} -> {to_string(k), v} end)

  defp serialize_observation(entry) do
    %{
      "path" => entry.path,
      "role" => to_string(entry.role),
      "mtime" => entry.mtime && DateTime.to_iso8601(entry.mtime),
      "size" => entry.size,
      "fingerprint" => entry.fingerprint,
      "valid" => entry.valid,
      "validation_errors" => entry.validation_errors || %{},
      "component_id" => entry[:component_id],
      "story_id" => entry[:story_id]
    }
  end

  # Paths and domain calls a spex needs. Re-exported rather than referenced
  # directly, because `CodeMySpecSpex` may not depend on `CodeMySpec` — the
  # bridge is the sanctioned crossing.
  defdelegate qa_plan_path(), to: CodeMySpec.Paths, as: :qa_plan
  defdelegate qa_journey_plan_path(), to: CodeMySpec.Paths, as: :qa_journey_plan
  defdelegate qa_journey_result_path(), to: CodeMySpec.Paths, as: :qa_journey_result
  defdelegate persona_summary_path(slug), to: CodeMySpec.Personas, as: :summary_path
  defdelegate persona_sources_path(slug), to: CodeMySpec.Personas, as: :sources_path
  defdelegate create_persona(scope, attrs), to: CodeMySpec.Personas
  defdelegate list_components(scope), to: CodeMySpec.Components

  @doc "Attempt to write a component's stub spec through the scope's environment."
  defdelegate write_component_stub(scope, attrs),
    to: SpecStub,
    as: :write_for_scope

  @doc """
  Whether a named requirement is satisfied for an entity, read off the computed
  graph — the same graph `get_next_requirement` serves an agent from.

  Read from the whole graph rather than a single check because that is what an
  agent sees: a checker returning true while the graph still lists the
  requirement open is exactly the disagreement this story exists to catch.
  """
  def requirement_satisfied?(%Scope{} = scope, name, entity_type, entity_id) do
    scope
    |> CodeMySpec.Requirements.compute_all()
    |> Enum.any?(fn r ->
      to_string(r.name) == name and
        to_string(r.entity_type) == to_string(entity_type) and
        to_string(r.entity_id) == to_string(entity_id) and
        r.satisfied
    end)
  end

  @doc """
  The full computed requirement, not just whether it is satisfied.

  Story 988 is about the *shape* of a verdict — whether an agent can tell "not
  yet known" from "not done" — so a boolean is exactly the thing that cannot be
  asserted on.
  """
  def requirement(%Scope{} = scope, name, entity_type, entity_id) do
    scope
    |> CodeMySpec.Requirements.compute_all()
    |> Enum.find(fn r ->
      to_string(r.name) == name and
        to_string(r.entity_type) == to_string(entity_type) and
        to_string(r.entity_id) == to_string(entity_id)
    end)
  end

  @doc "Record a problem against a project, as an analyzer's reconciler would."
  def record_problem(%Scope{} = scope, source, attrs \\ %{}) do
    CodeMySpec.Problems.create_problems(scope, [
      Map.merge(
        %{
          source: source,
          severity: :error,
          message: "nesting too deep",
          file_path: "lib/my_app/accounts.ex",
          category: "readability",
          line: 61
        },
        attrs
      )
    ])
  end

  @doc """
  Set an analyzer's blocking mode.

  `:block_all` isolates the question a freshness scenario is asking. The default
  is `:block_changed`, which additionally scopes blocking to files touched this
  turn — real behaviour, and a different rule; leaving it on would make a
  freshness scenario pass or fail for reasons that have nothing to do with
  freshness.
  """
  def set_analyzer_mode(%Scope{} = scope, field, mode) do
    CodeMySpec.Configurations.get_or_create(scope)
    {:ok, config} = CodeMySpec.Configurations.update(scope, %{field => mode})
    config
  end

  @doc "The stop hook's blocking decision, as the hook itself asks for it."
  # Drops the block key. `validate_stop/3` returns `{:error, reason, key}` — the
  # key is R8's repeat identity for the finding set, not something a spec has an
  # opinion about, and every one of these asserts on the reason.
  def validate_stop(%Scope{} = scope) do
    case CodeMySpec.Validation.validate_stop(scope, nil) do
      {:error, reason, _key} -> {:error, reason}
      other -> other
    end
  end

  @doc "Files the harness scanned but could classify into no role."
  def unclassified_files(%Scope{} = scope),
    do: Scanner.unclassified(scope.environment)

  # -- Project Setup (Story 124) --
  defdelegate satisfy_setup_steps(env, steps), to: SetupFixtures, as: :satisfy
  defdelegate reset_setup_env(env), to: SetupFixtures, as: :reset
  defdelegate setup_steps(), to: AgentTasks.ProjectSetup
  defdelegate step_name(mod), to: AgentTasks.ProjectSetup
  defdelegate find_setup_step(id), to: AgentTasks.ProjectSetup, as: :find_step

  @doc "Returns the stub setup-step module that always errors. Used by Story 124's error-path spex."
  def erroring_setup_step, do: ErroringStep

  # -- Technical Strategy (Story 80) --
  defdelegate with_mix_exs(env), to: TechnicalStrategyFixtures
  defdelegate with_custom_adr(env, topic, marker), to: TechnicalStrategyFixtures
  defdelegate with_decisions_index(env), to: TechnicalStrategyFixtures
  defdelegate read_adr(env, topic), to: TechnicalStrategyFixtures
  defdelegate adr_exists?(env, topic), to: TechnicalStrategyFixtures

  # -- Code Generation --
  defdelegate with_baseline_project(env), to: CodeGenerationFixtures
  defdelegate with_decision(env, topic), to: CodeGenerationFixtures
  defdelegate with_decisions(env, topics), to: CodeGenerationFixtures
  defdelegate with_integration_spec(env, provider), to: CodeGenerationFixtures
  defdelegate with_integration_specs(env, providers), to: CodeGenerationFixtures
  defdelegate with_generator_applied(env, generator_id), to: CodeGenerationFixtures
  defdelegate with_all_generators_applied(env), to: CodeGenerationFixtures
  defdelegate generator_applied?(env, generator_id), to: CodeGenerationFixtures
  defdelegate generator_ids(), to: CodeGenerationFixtures
  defdelegate with_full_script(env), to: CodeGenerationFixtures
  defdelegate with_empty_script(env), to: CodeGenerationFixtures
  defdelegate with_existing_script(env, body), to: CodeGenerationFixtures
  defdelegate read_script(env), to: CodeGenerationFixtures
  defdelegate script_exists?(env), to: CodeGenerationFixtures

  # -- QA Integration Plan --
  defdelegate with_decision_for_service(env, service, opts \\ []),
    to: QaIntegrationPlanFixtures

  defdelegate with_verified_integration_spec(env, name), to: QaIntegrationPlanFixtures
  defdelegate with_pending_integration_spec(env, name), to: QaIntegrationPlanFixtures

  defdelegate with_integration_spec_missing_verify_script(env, name),
    to: QaIntegrationPlanFixtures

  defdelegate with_verify_script(env, name), to: QaIntegrationPlanFixtures
  defdelegate with_integration_index(env, topics), to: QaIntegrationPlanFixtures
  defdelegate with_empty_integration_index(env), to: QaIntegrationPlanFixtures
  defdelegate with_verified_integration(env, name), to: QaIntegrationPlanFixtures
  defdelegate read_integration_spec(env, name), to: QaIntegrationPlanFixtures
  defdelegate integration_spec_exists?(env, name), to: QaIntegrationPlanFixtures
  defdelegate integration_index_exists?(env), to: QaIntegrationPlanFixtures
  defdelegate verify_script_exists?(env, name), to: QaIntegrationPlanFixtures

  # -- Embeddings --
  defdelegate write_framework_knowledge_file(dir, filename, content), to: EmbeddingsFixtures
  defdelegate simulate_framework_knowledge_boot_embed(scope), to: EmbeddingsFixtures

  # -- Continuous mode (Story 538) --
  @doc """
  Drive the real `POST /api/skills/start` endpoint with skill=implement
  so the agent's autonomous loop is enabled on the named session.

  Production surface: `cms implement` (CLI) → POST /api/skills/start
  → SkillController.start_skill → StartAgentTask.run("start_implementation")
  → StartImplementation.init_session sets `session.continuous = true`.

  Returns `:ok`. The session's `external_id` is whatever the caller passed
  in; calling this AFTER a regular `start_task` for that session flips the
  continuous flag on the existing row.
  """
  @spec start_continuous_mode(map(), String.t()) :: :ok
  def start_continuous_mode(scope, external_id) when is_binary(external_id) do
    response =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("x-working-dir", scope.cwd)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Phoenix.ConnTest.dispatch(
        CodeMySpecLocalWeb.Endpoint,
        :post,
        "/api/skills/start",
        %{"skill" => "implement", "external_id" => external_id}
      )
      |> Phoenix.ConnTest.json_response(200)

    case response do
      %{"prompt" => _} -> :ok
      _ -> raise "start_continuous_mode failed: #{inspect(response)}"
    end
  end

  # -- Tap-out human response (Story 704 / Rule 5) --
  @doc """
  Simulate the human responding to a pending tap-out request.

  Spex use this to drive the approval/rejection side without a real
  production-server round-trip. Wraps `TapOut.respond/4`.
  """
  @spec respond_to_tap_out(map(), String.t(), String.t(), :approve | :reject) ::
          {:ok, Session.t()} | {:error, term()}
  def respond_to_tap_out(scope, session_external_id, request_id, decision)
      when decision in [:approve, :reject] do
    session = CodeMySpec.Sessions.get_by_external_id(scope, session_external_id)
    TapOut.respond(scope, session, request_id, decision)
  end

  @doc """
  Returns the PubSub topic that tap-out events are broadcast on.

  Spex subscribe to this topic to assert that `tap_out` MCP calls
  publish the expected messages without referencing the internal
  `CodeMySpec.Permissions.TapOut` module directly.
  """
  @spec tap_out_pubsub_topic() :: String.t()
  def tap_out_pubsub_topic, do: "permissions:tap_out"

  @doc """
  Looks up a session by its external conversation id (the string the
  agent passes as `session_id` in hook calls). Returns the DB row so
  spex can extract the UUID needed for LiveView route params.
  """
  @spec get_session_by_external_id(Scope.t(), String.t()) :: Session.t() | nil
  def get_session_by_external_id(%Scope{} = scope, session_external_id)
      when is_binary(session_external_id) do
    Sessions.get_by_external_id(scope, session_external_id)
  end

  # -- Sub-agent registration with custom heartbeat (Story 704) --
  @doc """
  Register a sub-agent on a session with a specific `last_heartbeat_at`.

  Used by spex that need to seed a TTL-expired registration (heartbeat
  in the past) without manipulating the system clock. Goes through the
  same `Sessions.register_subagent/3` context function the production
  hook uses; only the timestamp differs.

  Returns `{:ok, session}` with the registration applied.
  """
  @spec register_subagent_with_heartbeat(map(), String.t(), map()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def register_subagent_with_heartbeat(scope, session_external_id, attrs)
      when is_binary(session_external_id) and is_map(attrs) do
    session = CodeMySpec.Sessions.get_by_external_id(scope, session_external_id)
    CodeMySpec.Sessions.register_subagent(scope, session, attrs)
  end

  # -- Users --
  defdelegate user_fixture(attrs \\ %{}), to: UsersFixtures
  defdelegate user_scope_fixture(), to: UsersFixtures
  defdelegate user_scope_fixture(user), to: UsersFixtures
  defdelegate user_scope_fixture(user, account), to: UsersFixtures
  defdelegate user_scope_fixture(user, account, project), to: UsersFixtures
  defdelegate full_scope_fixture(), to: UsersFixtures
  defdelegate full_scope_fixture(project_attrs), to: UsersFixtures
  defdelegate expire_magic_link_tokens_for(email), to: UsersFixtures

  # -- Accounts --
  defdelegate account_fixture(attrs \\ %{}), to: AccountsFixtures
  defdelegate account_with_owner_fixture(user, attrs \\ %{}), to: AccountsFixtures
  defdelegate member_fixture(user, account, role \\ :member), to: AccountsFixtures

  # -- Projects --
  defdelegate project_fixture(scope, attrs \\ %{}), to: ProjectsFixtures

  # -- Workspaces --

  @doc """
  Swap the workspace runner for the fake one and start it.

  A spex cannot name `CodeMySpecTest.FakeWorkspaceRunner` — `CodeMySpecSpex`
  does not carry `CodeMySpecTest` as a boundary dep, and should not: reaching
  into the app is this module's job, not the criterion's. This bridge already
  has the dep, so the swap belongs here.

  Exactly what the spex did inline: install the runner in application config,
  remove it on exit, and start the fake supervised.
  """
  @spec install_workspace_runner(keyword()) :: :ok
  def install_workspace_runner(opts \\ [healthy?: true, serving: :serving]) do
    Application.put_env(:code_my_spec, CodeMySpec.Workspaces, runner: FakeWorkspaceRunner)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:code_my_spec, CodeMySpec.Workspaces)
    end)

    # Idempotent, because a caller means "the workspace behaves like this now"
    # rather than "start a second one". Scenarios inside one `spex` block share
    # a test process — they read as sibling blocks and are not — so adding a
    # scenario to an existing criterion met
    #
    #   ** (RuntimeError) failed to start child with the spec
    #      {CodeMySpecTest.FakeWorkspaceRunner, [...]}.
    #      Reason: bad child specification, got: {:already_started, #PID<...>}
    #
    # which names a child spec and a pid and reads as a supervision bug in the
    # code under test. It took a stacktrace read to find that the second
    # installer was the caller's own fixture call.
    case Process.whereis(FakeWorkspaceRunner) do
      nil -> ExUnit.Callbacks.start_supervised!({FakeWorkspaceRunner, opts})
      _already_running -> FakeWorkspaceRunner.configure(opts)
    end

    :ok
  end

  @doc """
  Set what the fake workspace reports serving — `:serving`, `:erroring`,
  `:down` or `:ok`. How a scenario makes a running container answer badly.
  """
  defdelegate put_workspace_serving(serving), to: FakeWorkspaceRunner, as: :put_serving

  @doc """
  Decide, from the scenario, whether the instance has started answering.

  Lets a spec observe the starting state deliberately and then end it, rather
  than racing the boot watcher's wall clock — a race lost on a loaded machine,
  which is exactly where it must not flake.
  """
  defdelegate put_workspace_healthy(healthy?), to: FakeWorkspaceRunner, as: :put_healthy

  @doc """
  Puts `project_id`'s workspace into the state the pane has to render.

  Story 885's whole point is that these are four different screens, so a spec
  needs to produce each one without a container. The runner is faked; the row
  is real, because `Workspaces.state/1` reads both and conflating them is the
  bug the story exists to prevent.

  - `:absent` — no workspace row at all. Nothing was ever built.
  - `:starting` — booting, and the fake never answers, so the spec observes the
    starting state deliberately rather than racing the boot watcher's clock.
  - `:running` — running, with a port, so there is an address to frame.
  There is deliberately no "running without an address" state here.
  `booting_changeset/2` requires a port, so a workspace row cannot be in one —
  criterion 2323 hands the component that input directly, because the pane's
  contract has to hold for hosts beyond the one that exists today.
  - `:down` — the container has gone away.
  """
  @spec workspace_in(Scope.t(), String.t(), atom()) :: :ok
  def workspace_in(%Scope{} = _scope, _project_id, :absent), do: :ok

  def workspace_in(%Scope{} = _scope, project_id, state) do
    install_workspace_runner(runner_opts(state))

    {:ok, workspace} =
      WorkspacesRepository.upsert_booting(
        WorkspacesRepository.get_by_project(project_id),
        %{project_id: project_id, container_name: "spex-#{project_id}", port: port_for(state)}
      )

    settle(workspace, state)
  end

  defp runner_opts(:starting), do: [healthy?: false, alive?: true, serving: :down]
  defp runner_opts(:down), do: [healthy?: false, alive?: false, serving: :down]
  defp runner_opts(_running), do: [healthy?: true, alive?: true, serving: :serving]

  defp port_for(_state), do: 4599

  defp settle(_workspace, :starting), do: :ok

  defp settle(workspace, _state) do
    {:ok, _} = WorkspacesRepository.update(Workspace.running_changeset(workspace))
    :ok
  end

  @doc """
  An actual HTTP server standing in for the container's app, and a running
  workspace row for `project_id` pointing at it. Returns the preview hostname.

  The other workspace fixtures fake the *runner* — whether a container is up.
  This fakes the app instead, because the proxy criteria are not about
  container lifecycle: they are about whether a request that arrives at
  `preview-{id}.codemyspec.com` comes back carrying what the app actually
  sent. Nothing short of a real socket answers that. It has caught real bugs
  already — a proxy that relays a stale `content-length` produces a response
  no assertion on the body would notice.

  The app echoes what a proxy is most likely to mangle: it sets a cookie,
  reads one back, and reports the `host` header it was given.
  """
  @spec preview_app(Scope.t(), String.t(), keyword()) :: String.t()
  def preview_app(%Scope{} = _scope, project_id, opts \\ []) do
    Application.put_env(:code_my_spec, CodeMySpec.Workspaces, runner: LocalPreviewRunner)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:code_my_spec, CodeMySpec.Workspaces)
    end)

    body = Keyword.get(opts, :body, "<h1>Widget Tracker</h1>")
    {:ok, listener} = Bandit.start_link(plug: {PreviewApp, body}, port: 0, startup_log: false)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(listener)

    ExUnit.Callbacks.on_exit(fn -> Process.exit(listener, :normal) end)

    {:ok, workspace} =
      WorkspacesRepository.upsert_booting(
        WorkspacesRepository.get_by_project(project_id),
        %{project_id: project_id, container_name: "preview-app-#{port}", port: port}
      )

    {:ok, _running} = WorkspacesRepository.update(Workspace.running_changeset(workspace))

    PreviewAddress.host(project_id)
  end

  @doc """
  Binds the preview listener on an OS-assigned port and returns it.

  The preview socket needs a real one — `Phoenix.ConnTest` never opens a
  socket, so the proxy's upgrade path is unreachable from it. Port 0 rather
  than a fixed number on purpose: a fixed port collides the moment two specs
  run together, and this suite runs `max_cases: 20`.

  `CodeMySpecWeb.PreviewListener` rather than the endpoint, and that is the
  point rather than a convenience — the endpoint claims `/live/websocket` for
  its own LiveView socket before any plug runs, so it can never serve a
  preview's socket. See that module.
  """
  @spec preview_endpoint() :: pos_integer()
  def preview_endpoint do
    {:ok, listener} =
      Bandit.start_link(plug: CodeMySpecWeb.PreviewListener, port: 0, startup_log: false)

    {:ok, {_addr, port}} = ThousandIsland.listener_info(listener)
    ExUnit.Callbacks.on_exit(fn -> Process.exit(listener, :normal) end)

    port
  end

  @doc "Opens a preview socket as a browser would, addressed by Host header."
  defdelegate open_preview_socket(port, host), to: PreviewWsClient, as: :connect

  @doc "Sends a text frame up through the preview socket."
  defdelegate send_preview_frame(client, text), to: PreviewWsClient, as: :send_text

  @doc "Reads whatever frames have come back down, or none within the deadline."
  defdelegate preview_frames(client, timeout \\ 2_000), to: PreviewWsClient, as: :recv

  @doc "Closes a preview socket."
  defdelegate close_preview_socket(client), to: PreviewWsClient, as: :close

  @doc "The address a project's preview is served at, so a spex need not know the rule."
  @spec preview_host(String.t()) :: String.t()
  defdelegate preview_host(project_id), to: PreviewAddress, as: :host

  @doc """
  Creates a project whose `local_path` points at a freshly-created tmp
  directory that is NOT the spex's `scope.cwd`. Used by scenarios that
  want a project to exist in the DB while leaving the spex's working
  directory *unlinked* (e.g. Story 711 / criterion 6255 — the agent is
  in a working dir with no project row pointing at it, so `CliConfig`
  must surface the `list_projects` + `init_project` directive).

  Returns the project struct. The unlinked tmp dir is removed on
  test exit.
  """
  @spec project_fixture_unlinked(Scope.t(), map() | keyword()) ::
          Project.t()
  def project_fixture_unlinked(%Scope{} = scope, attrs \\ %{}) do
    unlinked_dir =
      Path.join(System.tmp_dir!(), "spex-unlinked-#{System.unique_integer([:positive])}")

    File.mkdir_p!(unlinked_dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(unlinked_dir) end)

    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.put_new(:local_path, unlinked_dir)

    ProjectsFixtures.project_fixture(scope, attrs)
  end

  @doc """
  Creates a fresh working directory carrying the full Phoenix project
  shape (`mix.exs`, `lib/`, `config/`) that no project row points at, and
  registers cleanup. Returns the path.

  Story 711 specs drive the bootstrap surface from a directory the
  `WorkingDir` plug resolves by hitting `File.*` directly, so the shape
  must exist on disk — hence this lives in the Fixtures bridge rather
  than the spec.
  """
  @spec phoenix_shape_working_dir() :: String.t()
  def phoenix_shape_working_dir do
    dir = Path.join(System.tmp_dir!(), "unlinked-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "config"))
    File.write!(Path.join(dir, "mix.exs"), "# stub for PhoenixProject.evaluate\n")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  @doc """
  A ledger of what the app asked a provider double to do.

  Doubles record through `record_call/2`; the spec reads the whole list back
  with `recorded_calls/1` and asserts on it. Dies with the test process.

  This replaced `send(self(), …)` from inside the doubles. Two reasons, and the
  second is the real one: a spec may not call `send/2`, and a mailbox is a poor
  record anyway — `refute_received` only sees the instant it runs, so "the app
  never resized the box" was really "nothing had arrived yet." The ledger keeps
  every call in order, so absence means absence.
  """
  @spec call_recorder() :: pid()
  def call_recorder do
    {:ok, recorder} = Agent.start_link(fn -> [] end)
    recorder
  end

  @doc "Records one call against `recorder`. Synchronous, so it cannot race the assertion."
  @spec record_call(pid(), term()) :: :ok
  def record_call(recorder, call), do: Agent.update(recorder, &[call | &1])

  @doc "Every call recorded so far, oldest first."
  @spec recorded_calls(pid()) :: [term()]
  def recorded_calls(recorder), do: recorder |> Agent.get(& &1) |> Enum.reverse()

  @doc """
  A spex run report on disk, in the JSONL shape `mix spex` leaves behind.
  Returns the path; it is removed on test exit.

  `entries` is a list of `{spec_path, message}`, one failed scenario each.

  Specs about the specs-ready gate need a *finished* run to hand the harness,
  and running a real one inside a spec would mean a suite inside a suite. This
  writes what that run would have left, so the gate is driven by its actual
  input rather than by a stub of it.
  """
  @spec spex_run_report([{String.t(), String.t()}]) :: String.t()
  def spex_run_report(entries) do
    body =
      Enum.map_join(entries, "\n", fn {path, message} ->
        Jason.encode!(%{
          "spex" => "intentional failure",
          "scenario" => "asserts false",
          "steps" => [
            %{"type" => "then", "description" => "fails", "status" => "failed"}
          ],
          "error" => %{
            "message" => message,
            "file" => path,
            "line" => 7,
            "stacktrace" => []
          }
        })
      end)

    path =
      Path.join(
        System.tmp_dir!(),
        "spex-run-report-#{System.unique_integer([:positive])}.jsonl"
      )

    File.write!(path, body <> "\n")
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    path
  end

  @doc """
  Turns the three requirement toggles on for a project.

  A fresh project defaults them off — it writes BDD spex and code and nothing
  else. The spex suite exercises the full development workflow, so it needs the
  whole chain (spec → review → test → implementation) to have anything to drive.

  Lives on the bridge rather than being called directly: `CodeMySpecSpex` is its
  own Boundary and may not reach into `CodeMySpec.*`, so every fixture the specs
  need has to come through here.
  """
  @spec require_all!(Scope.t()) :: Scope.t()
  def require_all!(scope) do
    {:ok, _config} =
      Configurations.update(scope, %{
        require_specs: true,
        require_reviews: true,
        require_unit_tests: true
      })

    scope
  end

  @doc """
  Gives the project working directory the Phoenix shape `Init.PhoenixProject`
  probes for — `mix.exs`, `lib/`, and `config/`.

  Writes through the scope's environment rather than to disk. The spex case
  registers an in-memory environment and keeps a directory on disk purely as a
  marker for the `WorkingDir` plug, so a `File.mkdir_p!` here would seed a
  filesystem the probe does not read.

  The `.gitkeep` entries are load-bearing: the in-memory environment has no
  directories of its own, and reports one as existing only when some entry sits
  beneath it. `ensure_dir/2` is a no-op there for the same reason.
  """
  @spec add_phoenix_project_shape(Scope.t()) :: :ok
  def add_phoenix_project_shape(%{environment: env}) do
    :ok = Environments.write_file(env, "mix.exs", "# stub for PhoenixProject.evaluate\n")
    :ok = Environments.write_file(env, "lib/.gitkeep", "")
    :ok = Environments.write_file(env, "config/.gitkeep", "")
    :ok
  end

  @doc """
  Removes `mix.exs` from the project working directory so the Phoenix-project
  shape check fails (Story 711 / criterion 6251 — missing shape emits the
  relaunch-from-root directive).

  Pair with `add_phoenix_project_shape/1`: removing from an environment that
  never had the shape passes for the wrong reason.
  """
  @spec remove_mix_exs(Scope.t()) :: :ok
  def remove_mix_exs(%{environment: env}) do
    :ok = Environments.delete_file(env, "mix.exs")
    :ok
  end

  @doc """
  Captures log output while the primary Logger level is temporarily
  lowered to `:info`, restoring it afterward. Lets specs assert on
  `:info`-level trace lines that the test runtime's `:warning` level would
  otherwise filter before they reach any handler. (Specs themselves can't
  juggle the Logger level — that's `try/after` plumbing that belongs in
  the bridge.)
  """
  @spec capture_log_at_info((-> any())) :: String.t()
  def capture_log_at_info(fun) when is_function(fun, 0) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      ExUnit.CaptureLog.capture_log(fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  # -- Stories (QA spex fixture setup, Stories 726/727) --
  @doc """
  Creates a story directly through the Stories context for use in QA
  spex setup. Returns the created story struct.
  """
  @spec story_fixture(Scope.t(), map()) :: Story.t()
  def story_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        title: "QA Story #{System.unique_integer([:positive])}",
        description: "A story for QA spex testing"
      })

    {:ok, story} = Stories.create_story(scope, attrs)
    story
  end

  # -- Sessions (timeline spex fixture setup, Story 813) --
  @doc """
  Creates a session (with optional embedded tasks and controllable
  `inserted_at`/`updated_at`) for timeline spex that assert on session
  ordering, extent, and per-task focus. Sessions originate from the
  agent's hook lifecycle in production; the bridge surfaces direct
  creation so spex can stage specific timeline states without driving a
  full agent run.
  """
  defdelegate session_fixture(scope, attrs \\ %{}), to: SessionsFixtures

  @doc """
  Touch a session through the real API, so subscribers hear about it.

  `session_fixture/2` back-dates `inserted_at` with a raw update *after*
  `create_session` has already broadcast, and a view that hides sessions with
  no activity yet (`inserted_at == updated_at`) recomputes against the
  pre-backdate row and drops it. Nothing broadcasts again, so the session never
  appears. This is the second event a working agent would produce anyway.
  """
  @spec touch_session(Scope.t(), Session.t()) :: {:ok, Session.t()} | {:error, term()}
  def touch_session(%Scope{} = scope, session),
    do: CodeMySpec.Sessions.update_session(scope, session, %{status: session.status})

  # -- Sessions (QA spex fixture setup, Stories 726/727) --
  @doc """
  Creates an active session with a `qa_complete` task linked to the given
  story. Used by QA spex setup to seed `context.story` and `context.task_id`
  without needing the full requirement prerequisite chain satisfied.

  Returns `{story, task_id, session}`.
  """
  @spec qa_story_task_fixture(Scope.t(), keyword()) ::
          {Story.t(), String.t(), Session.t()}
  def qa_story_task_fixture(scope, opts \\ []) do
    story =
      case Keyword.fetch(opts, :story) do
        {:ok, existing} ->
          existing

        :error ->
          story_fixture(scope, %{
            title: Keyword.get(opts, :title, "QA Story #{System.unique_integer([:positive])}"),
            description: Keyword.get(opts, :description, "Story for QA testing")
          })
      end

    task_id = Ecto.UUID.generate()
    session_external_id = "spex-qa-#{System.unique_integer([:positive])}"

    {:ok, session} =
      Sessions.create_session(scope, %{
        external_conversation_id: session_external_id,
        status: :active,
        type: QaStory,
        tasks: [
          %{
            id: task_id,
            status: :active,
            requirement_name: "qa_complete",
            story_id: story.id,
            project_id: scope.active_project_id,
            agent_id: "spex-agent",
            started_at: DateTime.utc_now()
          }
        ]
      })

    {story, task_id, session}
  end

  # -- Components --
  defdelegate get_component_by_module_name(scope, module_name), to: Components

  # -- Architecture --
  defdelegate proposal_with_context(app, name, description), to: ArchitectureFixtures
  defdelegate proposal_with_surface_and_context(opts \\ []), to: ArchitectureFixtures
  defdelegate with_proposal(env, content), to: ArchitectureFixtures
  defdelegate with_executed_proposal(scope, env, content), to: ArchitectureFixtures
  defdelegate dependency_fixture(scope, source, target), to: ArchitectureFixtures
  defdelegate component_fixture(scope, attrs), to: ArchitectureFixtures

  # -- BDD Specs --

  @doc """
  Where the harness will look for a criterion's spex.

  Resolves the story and criterion from the database before deriving,
  rather than deriving from whatever the spex is holding. Spex reach
  this with a story parsed out of `GetStory`'s text — `:id`, `:title`,
  `:criteria` and nothing else — and the path is built from the
  story's durable `:number`, which that projection does not carry.
  Deriving from it produced `test/spex/<id>_<slug>/`, the spex wrote
  its fixture there, and the evaluator looked under `<number>_<slug>`
  and reported the file missing. Seven spex in story 460 failed that
  way and all of them read as evaluator bugs.

  Resolving also picks up a recorded `spec_path`, which is what the
  evaluator uses when one exists, so this answers the question a spex
  is actually asking: where will the harness look?
  """
  @spec spec_file_path(map(), map()) :: String.t()
  def spec_file_path(%{id: story_id}, %{id: criterion_id}) do
    story = Repo.get!(Story, story_id) |> Repo.preload(:criteria)
    criterion = Enum.find(story.criteria, &(&1.id == criterion_id))

    unless criterion do
      raise ArgumentError,
            "criterion #{inspect(criterion_id)} does not belong to story #{inspect(story_id)}"
    end

    BddSpecs.spec_file_path(story, criterion)
  end

  # -- Problems --
  defdelegate problem_fixture(scope, attrs \\ %{}), to: ProblemsFixtures

  # -- Issues (QA triage / fix scenarios) --
  defdelegate issue_fixture(scope, attrs \\ %{}), to: IssuesFixtures

  # -- QA Attempts --
  defdelegate passed_qa_attempt(scope, opts \\ []), to: QaFixtures

  # -- OAuth (CLI client for Story 698) --
  defdelegate cli_oauth_application_fixture(attrs \\ %{}), to: OauthFixtures

  # -- Analytics (Story 698) --
  defdelegate attach_analytics_test_subscriber(pid),
    to: CodeMySpec.Analytics,
    as: :attach_test_subscriber

  defdelegate detach_analytics_test_subscriber(pid),
    to: CodeMySpec.Analytics,
    as: :detach_test_subscriber

  defdelegate attach_ga_test_subscriber(pid),
    to: GoogleAnalytics,
    as: :attach_test_subscriber

  defdelegate detach_ga_test_subscriber(pid),
    to: GoogleAnalytics,
    as: :detach_test_subscriber

  # -- Local app onboarding (Story 701) --

  @doc """
  Seeds a `client_users` row with a non-expired OAuth token for the
  test user. The local app's auth rung evaluates "done" against the
  presence of this row (same predicate `OAuthClient.authenticated?/0`
  returns).
  """
  def client_user_fixture(user, opts \\ []) do
    expires_in = Keyword.get(opts, :expires_in, 3600)
    suffix = System.unique_integer([:positive])

    token_data = %{
      "access_token" => "test-access-#{suffix}",
      "refresh_token" => "test-refresh-#{suffix}",
      "expires_in" => expires_in
    }

    {:ok, client_user} =
      OAuthClient.save_client_user(user.id, user.email, token_data)

    client_user
  end

  @doc """
  Records a `local_init_complete` event for the active project so the
  per-project ladder's init rung evaluates as "done." For tests where
  the scenario's intent is "init has been run."
  """
  def satisfy_init(%{active_project: project}) when not is_nil(project) do
    {:ok, _event} =
      CodeMySpec.Events.record("local_init_complete", %{project_id: project.id})

    :ok
  end

  @doc """
  Records a `local_project_setup_complete` event for the active project
  so the per-project ladder's setup rung evaluates as "done."
  """
  def satisfy_project_setup(%{active_project: project}) when not is_nil(project) do
    {:ok, _event} =
      CodeMySpec.Events.record("local_project_setup_complete", %{project_id: project.id})

    :ok
  end

  # -- Framework-issue remote stub --

  # -- Project configuration (Stories 608, etc.) --

  @doc """
  Updates the active project's configuration. Spex use this to
  change operator-configurable settings (e.g. fix_issues_min_severity)
  without reaching directly into CodeMySpec.Configurations.
  """
  @spec update_project_configuration(Scope.t(), map()) ::
          {:ok, term()} | {:error, term()}
  def update_project_configuration(%Scope{} = scope, attrs) when is_map(attrs) do
    Configurations.update(scope, attrs)
  end

  # -- Requirements graph (Stories 811, etc.) --

  @doc """
  Returns the list of next-actionable requirements for the active
  project scope. Spex use this to assert graph state without
  reaching directly into CodeMySpec.Requirements.RequirementGraph.
  """
  @spec next_actionable_requirements(Scope.t()) :: list()
  def next_actionable_requirements(%Scope{} = scope) do
    RequirementGraph.next_actionable(scope)
  end

  # --- Mail (story 816) ---

  @doc """
  Point the project at a real checkout on disk.

  For criteria that shell out — the deploy step runs `bin/deploy` from the
  project's `cwd`, which the stub directory does not have.
  """
  @spec set_project_local_path(Project.t(), String.t()) :: {:ok, Project.t()}
  def set_project_local_path(project, path) do
    {:ok,
     project
     |> Ecto.Changeset.change(local_path: path)
     |> CodeMySpec.Repo.update!()}
  end

  @doc "Set and verify a project's sending domain."
  def verify_project_domain(project, domain) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    project
    |> Ecto.Changeset.change(domain: domain, domain_verified_at: now)
    |> CodeMySpec.Repo.update!()
  end

  @doc """
  Mint a widget socket token for the scope's project.

  The browser-safe credential the widget presents on the socket. A spex cannot
  reach `AppTokens` across the boundary, so this bridges it.
  """
  def mint_socket_token(%Scope{active_project: project}) do
    CodeMySpec.AppTokens.issue_socket_token(project)
  end

  @doc "Write one secret into an environment's encrypted env (via the step)."
  def put_encrypted_secret(scope, environment, key, value) do
    Steps.put_secret(scope, environment, key, value)
  end

  @doc """
  Run one provisioning step for real, from inside a scripted run.

  `scripted_run/2` stubs every step, which is what makes a criterion about the
  *sequence* cheap. A criterion about one particular step's behaviour needs the
  opposite: that step real, the rest still stubbed. Scripting the key with a
  zero-arity function that calls this gives exactly that.

  The configured step opts are merged in, because that is where the seams a
  criterion injects — the builder's `:create` / `:build` / `:destroy`, the
  deploy script, the probe — are already being passed.
  """
  def run_provisioning_step(scope, key, opts \\ []) do
    :code_my_spec
    |> Application.get_env(:provisioning_step_opts, [])
    |> Keyword.merge(opts)
    |> then(&Steps.run(key, scope, &1))
  end

  @doc "Write a file into an environment (bridge to Environments)."
  def write_env_file(env, path, content), do: Environments.write_file(env, path, content)

  @doc "Run a command in an environment (bridge to Environments)."
  def env_cmd(env, command, args), do: Environments.cmd(env, command, args)

  def set_code_repo(project, url) do
    project
    |> Ecto.Changeset.change(code_repo: url)
    |> CodeMySpec.Repo.update!()
  end

  @doc """
  Give an environment a fixed address, without provisioning a box for it.

  `environment_ip/3` uses the environment's own `ip` when it has one and only
  asks Hetzner when it does not. So seeding it means a criterion that needs
  *somewhere to point at* — DNS, TLS — no longer needs a server created,
  recorded, and torn down to get an address.

  It also decouples cassettes that were coupled by accident. A DNS record's
  request body carries the server's IP, and the server is minted fresh on every
  recording, so `965_7996_dns_records_for_certificate` and
  `965_7996_server` could only ever replay together: recorded two days apart,
  the DNS bodies wanted 5.161.239.73 and the server cassette handed out
  something else entirely, and the create could never match. A fixed address is
  the same address next year.

  Not for criteria whose subject *is* the server. Those want the real thing.
  """
  @spec seed_environment_ip(Scope.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def seed_environment_ip(%Scope{} = scope, name, ip) do
    alias CodeMySpec.Provisioning.EnvironmentRepository

    EnvironmentRepository.put(scope, name, %{ip: ip})
  end

  @doc """
  A runner that reaches the local fleet's app box instead of a provisioned one.

  The box-side steps — starting the registry, starting the database — build
  their runner from the server's public IP *as recorded in the cassette*. Those
  addresses were released weeks ago and belong to someone else now, so replaying
  reached out to strangers and waited out the connect timeout, and the step
  failed for a reason that has nothing to do with the story. `serve_registries`
  halts on the first error, so nothing after it recorded a resource and setup
  reported every step from `server` onward as having nothing behind it.

  This is the same `ssh_runner/2` the production path uses, pointed at a box on
  loopback — so the docker commands really run, against a daemon that really
  exists, and what they prove is that they work rather than that they were
  attempted.

  `CodeMySpecSpex` may not reach into `CodeMySpec`, which is why it is here.
  """
  @spec fleet_runner(map(), keyword()) :: (list() -> {String.t(), non_neg_integer()})
  def fleet_runner(environment, opts \\ []) do
    alias CodeMySpec.Provisioning.Builder.Remote

    Remote.ssh_runner(%{"ip" => "127.0.0.1"},
      env: environment,
      ssh_key_path: Keyword.fetch!(opts, :ssh_key_path),
      ssh_port: Keyword.get(opts, :ssh_port, 2223)
    )
  end

  @doc """
  The project's environments, as rows.

  A criterion that fetches "every environment's host" has to know what was
  provisioned, and `CodeMySpecSpex` may not reach into `CodeMySpec` for it —
  that is what this bridge is for.
  """
  @spec environments(Scope.t()) :: [map()]
  def environments(%Scope{} = scope) do
    alias CodeMySpec.Provisioning.EnvironmentRepository

    EnvironmentRepository.list(scope)
  end

  @doc """
  Give a project exactly these environments, and no others.

  Environments are rows, so "production is turned off" means the project does
  not have one — not that some option is unchecked. There is no `prod` toggle
  on the setup form and there never was; the options are domain, email,
  storage and the rest.
  """
  @spec set_environments(Scope.t(), [String.t()]) :: [String.t()]
  def set_environments(%Scope{active_project: %{id: project_id}} = scope, names) do
    alias CodeMySpec.Provisioning.{Environment, EnvironmentRepository}

    # Seed first, so the initial rows exist and can be pruned to the set asked
    # for rather than racing whatever creates them lazily.
    EnvironmentRepository.list(scope)

    for environment <- CodeMySpec.Repo.all(Environment),
        environment.project_id == project_id,
        environment.name not in names do
      CodeMySpec.Repo.delete!(environment)
    end

    for name <- names, do: EnvironmentRepository.put(scope, name, %{})

    EnvironmentRepository.names(scope)
  end

  # The throwaway organisation spex repositories belong in — never a personal
  # account. Two call sites defaulted to `"johns10"`, which is how a teardown
  # came to report success for repositories it had aimed at the wrong owner.
  @spex_owner "codemy-my-spec-test"

  @doc "The repository name setup would use for this project."
  def repository_name(project), do: Repository.default_name(project)

  @doc """
  Create a repository in the spex organisation, as a precondition.

  Criteria whose premise is "a repository already exists" — adopt rather than
  duplicate, a name collision, a push that gets rejected — have to put it
  there. They used to inherit one from a previous run, which meant they passed
  on a dirty account and failed on a clean one: exactly backwards.

  `commits: true` gives it an initial commit, which is what makes a fresh
  history unable to fast-forward onto it.
  """
  @spec create_spex_repository(String.t(), keyword()) :: :ok | {:error, term()}
  def create_spex_repository(name, opts \\ []) do
    with token when is_binary(token) <- spex_env("GITHUB_SPEX_ADMIN_TOKEN"),
         owner when is_binary(owner) <- spex_env("GITHUB_SPEX_OWNER") do
      Req.post("https://api.github.com/orgs/#{owner}/repos",
        headers: [
          {"authorization", "Bearer #{token}"},
          {"accept", "application/vnd.github+json"}
        ],
        # Public, deliberately. The app's own grant has to *see* this repository
        # for the collision to be detected at all, and a private one in an org
        # it reads through a narrow scope is invisible to it — so setup found
        # no collision and quietly created its own. The organisation is a
        # throwaway holding nothing but spex repositories.
        json: %{name: name, private: false, auto_init: Keyword.get(opts, :commits, false)}
      )
      |> case do
        {:ok, %{status: status}} when status in [201, 422] ->
          :ok

        {:ok, %{status: status, body: body}} ->
          raise "could not create #{owner}/#{name}: #{status} #{inspect(body, limit: 5)}"

        other ->
          raise "could not create #{owner}/#{name}: #{inspect(other, limit: 5)}"
      end
    else
      # Loudly, not silently. A criterion whose premise is "this repository
      # already exists" cannot be checked without it, and returning :ok here
      # let the step create its own and report success — the opposite of the
      # collision under test, passing for the wrong reason.
      _ ->
        raise """
        GITHUB_SPEX_ADMIN_TOKEN and GITHUB_SPEX_OWNER must both be set to create
        the repository this criterion's premise depends on.
        """
    end
  end

  @doc """
  Delete a repository a spex created, using a **harness-only** credential.

  Deliberately not the app's OAuth grant. Adding `delete_repo` there would give
  CodeMySpec the power to delete repositories on every user's account, forever,
  to solve a problem that only exists while recording tests — a bad trade for a
  cleanup convenience. Instead this reads `GITHUB_SPEX_ADMIN_TOKEN`, a
  short-lived fine-grained token that belongs to the person recording and can be
  scoped to the spex repositories alone.

  Returns `:ok` when there is no token, so a machine without one records
  normally — it just leaves the repository behind, which is the situation we
  are already in.
  """

  @spec delete_spex_repository(String.t()) :: :ok | {:error, term()}
  def delete_spex_repository(name) do
    case spex_env("GITHUB_SPEX_ADMIN_TOKEN") do
      token when is_binary(token) and token != "" ->
        # Guarded twice: only names this harness generates, and only through a
        # token whose scope the operator chose. A teardown that could delete an
        # arbitrary repository is worse than a repository left behind.
        name
        |> String.starts_with?("spex-")
        |> delete_generated_repository(name, token)

      _ ->
        :ok
    end
  end

  defp delete_generated_repository(false, name, _token), do: {:error, {:refused, name}}

  defp delete_generated_repository(true, name, token) do
    # Through `spex_env/1`, and never defaulting to a personal account.
    #
    # This read `System.get_env("GITHUB_SPEX_OWNER", "johns10")`. The variable
    # lives in envs/.env, which Dotenvy loads into config and not into the
    # process environment, so the default won — and the teardown deleted from a
    # personal account that has never held these repositories. GitHub answered
    # 404, which this treats as "already gone", and it reported `:ok` for three
    # repositories it had not touched.
    #
    # 404-is-ok stays: a teardown that has already run must be able to run
    # again. What was wrong is being aimed somewhere nothing could ever exist,
    # where "not found" and "cleaned up" are indistinguishable.
    owner = spex_env("GITHUB_SPEX_OWNER") || @spex_owner

    "https://api.github.com/repos/#{owner}/#{name}"
    |> Req.delete(
      headers: [
        {"authorization", "Bearer #{token}"},
        {"accept", "application/vnd.github+json"}
      ]
    )
    |> case do
      {:ok, %{status: status}} when status in [204, 404] -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      other -> other
    end
  end

  @doc """
  Point the project at the repository setup would make for it.

  A re-run finding its own work adopts silently; a repository setup did not
  make is Sam's to decide about (criteria 8179 vs 8185). Recording repeatedly
  puts us in the first case — the repository really was made by an earlier run
  of this same spex — but the project row is fresh each time, so setup sees a
  stranger's repository and pauses. This states the fact that is true.
  """
  def own_repository(project) do
    name = Repository.default_name(project)
    owner = spex_env("GITHUB_SPEX_OWNER") || @spex_owner
    set_code_repo(project, "https://github.com/#{owner}/#{name}")
  end

  @doc "Set a project's sending domain without verifying it."
  def set_project_domain(project, domain) do
    project
    |> Ecto.Changeset.change(domain: domain, domain_verified_at: nil)
    |> CodeMySpec.Repo.update!()
  end

  @doc "Create a mailbox on a project (assigned via `:user_id`, or shared)."
  def mailbox_fixture(project, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:project_id, project.id)
      |> Map.put_new(:address, "mailbox#{System.unique_integer([:positive])}@example.com")

    {:ok, mailbox} =
      %CodeMySpec.Mail.Mailbox{}
      |> Mailbox.changeset(attrs)
      |> CodeMySpec.Repo.insert()

    mailbox
  end

  @doc "Persist an email directly in a mailbox (for history/retention setup)."
  def persisted_email(mailbox, attrs \\ %{}) do
    attrs = Map.new(attrs)

    email_attrs = %{
      direction: Map.get(attrs, :direction, :inbound),
      mailbox_id: mailbox.id,
      from_address: attrs[:from],
      to_address: mailbox.address,
      correspondent: attrs[:from] || attrs[:correspondent] || "someone@example.com",
      subject: attrs[:subject],
      body_text: attrs[:body],
      message_id: attrs[:message_id],
      inserted_at: attrs[:inserted_at]
    }

    {:ok, email} =
      %CodeMySpec.Mail.Email{}
      |> Email.changeset(email_attrs)
      |> CodeMySpec.Repo.insert()

    email
  end

  @doc """
  Stamp completed analysis runs at the CURRENT input fingerprints.

  `tests_passing` / `spex_passing` require a fresh completed run in the
  analysis ledger (v1.5.36) — zero persisted problems no longer reads as
  "passing" on a project whose suites never ran. Satisfaction fixtures call
  this AFTER the last file write; any later relevant file change makes the
  stamp stale again (by design).

  Syncs first: fingerprints hash the Files table, and fixture-written files
  the stop hook hasn't synced yet would otherwise shift the fingerprint at
  stop time — the stamp would read stale and real analyzers would run
  against the synthetic project.
  """
  def fresh_analysis_runs(%Scope{} = scope, sources \\ ["compiler", "credo", "exunit", "spex"]) do
    {:ok, _} = FileSync.sync_changed(scope, base_dir: scope.cwd)
    CodeMySpec.AnalysisFixtures.fresh_analysis_runs_fixture(scope, sources)
  end

  @doc """
  The connected provider grant from the **dev** database, for recording.

  Cloudflare and Resend rotate their refresh token on every use and revoke the
  grant when a spent one is presented. Exporting a token into the environment
  makes a second copy of a single-use credential — the app refreshes, the
  stored token rotates, and the exported copy is now spent, so the next
  recording run kills the grant. That is what used to force a manual reconnect
  between recordings; it was never the refresh logic failing.

  So the integration row is the single owner, and recording borrows from it.
  Read over a connection of its own because the spex sandbox owns
  `CodeMySpec.Repo` and points it at the test database, which holds no
  integrations. Tokens are Cloak-encrypted at rest and the vault key is shared
  across environments, so the test node can read what the dev app wrote.

  Returns `%{access_token:, refresh_token:, expires_at:}`.
  """
  def live_provider_grant(provider) do
    case :persistent_term.get({__MODULE__, :grant, provider}, nil) do
      grant when is_map(grant) -> if usable?(grant), do: grant, else: fetch_and_cache(provider)
      _ -> fetch_and_cache(provider)
    end
  end

  # The cached copy is a snapshot, and it does not carry a refresh token — that
  # is deliberate, so a rotating credential has exactly one owner. The cost is
  # that the snapshot cannot renew itself, and Resend's access token lives about
  # fifteen minutes while a full 969 recording takes longer than that. Caching
  # for the whole run therefore died partway through with
  # `:reauthorize_required`, which reads like a revoked grant and is not one —
  # the dev row was untouched and worked immediately afterwards.
  #
  # Re-reading when the snapshot nears expiry keeps the single owner. Going back
  # to dev means `fetch_access_token/2` refreshes under its row lock and
  # persists the rotation, so the new token has one owner too.
  #
  # This only started biting once the account was genuinely clean: recordings
  # used to finish inside fifteen minutes because the previous run's sending
  # domains were still there and verified instantly.
  #
  # The margin has to be how long a criterion may *run*, not a comfortable
  # buffer, because the snapshot is taken once in `connect_providers/1` and
  # then has to last until the criterion ends. At 300s it did not: a grant with
  # six minutes left passed this check, was copied onto the spex's scope
  # without a refresh token, and expired inside a 1961 recording that takes
  # 568s. The copy then reported `:reauthorize_required` — about a grant that
  # exists only for the test, while the real row sat healthy and refreshed.
  # That reads as a revoked Cloudflare connection and is nothing of the kind,
  # which cost this session two wrong diagnoses before the arithmetic.
  #
  # `CodeMySpecSpex.Case.spex_timeout/0` is the ceiling — 20 minutes while
  # recording — so that is what a snapshot must survive. Not read from there:
  # `CodeMySpecSpex.Fixtures` is its own boundary and may not reach into the
  # Case.
  #
  # For a provider whose token is shorter-lived than a recording this makes
  # `usable?/1` always false, so every criterion re-reads from dev. That is the
  # right answer — it is the single owner, and it refreshes — but it does not
  # save Resend, whose ~15 minute token cannot outlast a 20 minute recording
  # however fresh the copy is. That one needs the snapshot to renew through the
  # dev row mid-run, which is a larger change than this.
  # Long enough for the run *and its teardown*, which is the part 1200s missed.
  # A criterion may take 20 minutes, and tearing down two servers, their DNS
  # and their buckets takes minutes more — so a snapshot taken with 21 minutes
  # left expired while teardown was still using it. What that looks like is not
  # an expired token: Cloudflare goes unreadable, the status report says
  # "Cannot say. One or more providers could not be read", and teardown leaves
  # eight DNS records behind with a warning nobody sees until the next audit.
  #
  # At 45 minutes against Cloudflare's hour, nearly every criterion re-reads
  # from the dev row rather than reusing a snapshot. That is the intent: the
  # row is the single owner, `fetch_access_token/2` refreshes it under a lock,
  # and borrowing the freshest thing it has is strictly better than nursing a
  # copy.
  @grant_margin_seconds 2700

  defp usable?(%{expires_at: %DateTime{} = expires_at}) do
    DateTime.diff(expires_at, DateTime.utc_now()) > @grant_margin_seconds
  end

  # A placeholder has no meaningful expiry and must not send us back to dev on
  # every spex — the warning was already issued once.
  defp usable?(_), do: true

  defp fetch_and_cache(provider) do
    # A provider whose grant is dead must not stop a recording that does not
    # use it — a revoked Resend connection would otherwise block every
    # Cloudflare and Hetzner spex on the machine. The placeholder produces
    # 401s, so a spex that genuinely needed this provider still fails, and
    # says why here rather than as an unexplained refusal later.
    grant =
      try do
        refresh_dev_grant(provider)
      rescue
        error ->
          IO.warn("""
          #{provider} is not usable for recording: #{Exception.message(error)}

          Spex that actually call #{provider} will fail. Others are unaffected.
          """)

          placeholder_grant()
      end

    :persistent_term.put({__MODULE__, :grant, provider}, grant)
    grant
  end

  defp placeholder_grant do
    %{
      access_token: "spex-placeholder-token",
      refresh_token: nil,
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }
  end

  # Refreshes **in the dev database** — through a dynamic repo, so the app's own
  # `fetch_access_token/2` runs: same row lock, same rotation, same persistence.
  # The rotated refresh token lands back where it came from, which is the whole
  # point. Only the access token travels into the test database, and it travels
  # without its refresh token: an access token is not single-use, so a copy of
  # one cannot cost anybody the grant.
  defp refresh_dev_grant(provider) do
    config =
      :code_my_spec
      |> Application.get_env(CodeMySpec.Repo, [])
      |> Keyword.merge(
        name: :spex_dev_repo,
        database: "code_my_spec_dev",
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        log: false
      )

    {:ok, pid} = CodeMySpec.Repo.start_link(config)
    previous = CodeMySpec.Repo.put_dynamic_repo(:spex_dev_repo)

    try do
      # Most recently updated wins: a provider reconnected in the app leaves the
      # older row behind, and the newer one is the live grant.
      integration =
        Integration
        |> CodeMySpec.Repo.all()
        |> Enum.filter(&(&1.provider == provider))
        |> Enum.max_by(& &1.updated_at, DateTime, fn -> nil end)

      unless integration do
        raise """
        recording needs a connected #{provider}, and code_my_spec_dev has none.

        Connect it in the running app, then re-run. Never export a provider
        token into the environment: Cloudflare and Resend rotate their refresh
        token on every use and revoke the grant when a spent one is presented,
        so a second copy of it is what kills the connection.
        """
      end

      scope = %Scope{user: CodeMySpec.Repo.get!(User, integration.user_id)}

      case CodeMySpec.Integrations.fetch_access_token(scope, provider) do
        {:ok, access_token} ->
          # Re-read: fetch_access_token may have refreshed, moving expires_at.
          fresh =
            CodeMySpec.Repo.get!(Integration, integration.id)

          %{access_token: access_token, refresh_token: nil, expires_at: fresh.expires_at}

        {:error, reason} ->
          raise """
          could not obtain a #{provider} token from code_my_spec_dev: #{inspect(reason)}

          Reconnect #{provider} in the running app. If this says the refresh
          token was already used or the grant was revoked, something else is
          holding a second copy of it.
          """
      end
    after
      CodeMySpec.Repo.put_dynamic_repo(previous)
      Supervisor.stop(pid)
    end
  end

  @doc """
  A connection URL for the test database.

  The spex boundary cannot reach `Repo` directly, and a backup criterion needs
  a real database to dump — this is the bridge for it.
  """
  @spec database_url() :: String.t()
  def database_url do
    config = CodeMySpec.Repo.config()

    "postgres://#{config[:username]}:#{config[:password]}@" <>
      "#{config[:hostname]}/#{config[:database]}"
  end

  @doc """
  Hetzner resources left behind by an earlier spex run.

  Named `spex-` by convention, which is also what makes them safe to identify:
  anything without that prefix is somebody's real infrastructure and is never
  reported here. Returns `[]` when the credentials are absent — a developer
  without them cannot have leaked anything.
  """
  @spec leaked_spex_resources() :: [String.t()]
  def leaked_spex_resources do
    with token when is_binary(token) and token != "" <- System.get_env("HETZNER_API_TOKEN"),
         id when is_binary(id) and id != "" <- System.get_env("HETZNER_S3_ACCESS_KEY_ID"),
         secret when is_binary(secret) and secret != "" <-
           System.get_env("HETZNER_S3_SECRET_ACCESS_KEY") do
      credentials = [
        access_key_id: id,
        secret_access_key: secret,
        region: System.get_env("HETZNER_S3_REGION", "fsn1")
      ]

      previous = Application.get_env(:code_my_spec, CodeMySpec.Provisioning.Hetzner, [])

      Application.put_env(
        :code_my_spec,
        CodeMySpec.Provisioning.Hetzner,
        Keyword.put(previous, :api_token, token)
      )

      servers =
        case Hetzner.list_servers(%CodeMySpec.Users.Scope{}) do
          {:ok, list} -> Enum.map(list, &(&1["name"] || &1[:name]))
          _ -> []
        end

      buckets =
        case Storage.list_buckets(credentials, []) do
          {:ok, list} -> Enum.map(list, &name_of/1)
          _ -> []
        end

      Application.put_env(:code_my_spec, CodeMySpec.Provisioning.Hetzner, previous)

      Enum.filter(servers ++ buckets, &String.starts_with?(to_string(&1), "spex-"))
    else
      _ -> []
    end
  end

  defp name_of(%{name: name}), do: name
  defp name_of(%{"name" => name}), do: name
  defp name_of(name) when is_binary(name), do: name
  defp name_of(other), do: inspect(other)

  @doc """
  Put the pasted-in provider secrets on file, without proving them.

  `Credentials.missing/1` reads storage, and `start_setup` refuses to run
  while anything is missing — rightly, since a run that starts without its
  credentials fails after it has already made things. A criterion about the
  *runner* still has to get past that gate, and proving a credential against a
  real provider is story 964's claim, not the runner's.
  """
  @spec store_provider_secrets(Scope.t()) :: :ok
  def store_provider_secrets(%Scope{} = scope) do
    for {key, env} <- [
          {"hetzner_api_token", "HETZNER_API_TOKEN"},
          {"hetzner_s3_access_key_id", "HETZNER_S3_ACCESS_KEY_ID"},
          {"hetzner_s3_secret_access_key", "HETZNER_S3_SECRET_ACCESS_KEY"}
        ] do
      CodeMySpec.ProjectSecrets.put_value(
        scope,
        key,
        System.get_env(env, "spex-placeholder-#{key}")
      )
    end

    :ok
  end

  @doc """
  Record which box an environment runs on, as the server step does.

  The real `run(:server)` provisions a machine and writes `server_name`/`ip`
  back onto the environment row — that write is what makes a box findable
  afterwards, and everything asking "what is on this server" reads it.

  A criterion about *displaying* a provisioned box still needs that link, but
  `scripted_run/2` replaces the step's execute, so the write never happens. So
  a premise that says "setup has provisioned Sam's UAT box" arranges it here,
  through the same context call the step uses, rather than reaching into the
  table or making the scripted step pretend to be the real one.
  """
  @spec record_environment_server(Scope.t(), String.t(), String.t(), String.t()) :: :ok
  def record_environment_server(%Scope{} = scope, environment, server_name, ip) do
    {:ok, _environment} =
      CodeMySpec.Provisioning.put_environment(scope, environment, %{
        server_name: server_name,
        ip: ip
      })

    :ok
  end

  @doc """
  Say a project other than the active one is meant to be deployed.

  `setup :devops_on` covers the project on the scope. A criterion needing a
  *second* deployable project has no scope pointing at it and no id — the
  create form redirects to the index — so it names the project instead.

  DevOps is opt in, so a project created and left alone expects no
  infrastructure. A criterion about two deployable projects has to make both
  of them so.
  """
  @spec enable_devops(Scope.t()) :: :ok
  def enable_devops(%Scope{} = scope), do: set_devops(scope, :prod)

  @doc """
  Set the project's devops level explicitly.

  `:off`, `:uat` or `:prod`. `:off` is already the default, but a criterion
  whose premise is "devops is off" should say so rather than inherit it from
  whatever the default happens to be that week — the same reasoning that gives
  `devops_on` its own setup.
  """
  @spec set_devops(Scope.t(), :off | :uat | :prod) :: :ok
  def set_devops(%Scope{} = scope, level) when level in [:off, :uat, :prod] do
    {:ok, _configuration} = CodeMySpec.Configurations.update(scope, %{devops: level})

    :ok
  end

  @spec enable_devops(Scope.t(), String.t()) :: :ok
  def enable_devops(%Scope{} = scope, project_name) do
    project =
      scope
      |> CodeMySpec.Projects.list_projects()
      |> Enum.find(&(&1.name == project_name)) ||
        raise "no project named #{inspect(project_name)} on this account"

    enable_devops(%Scope{scope | active_project: project, active_project_id: project.id})
  end

  # `envs/.env` holds these, and Dotenvy loads that file into *config* rather
  # than into the process environment — so `System.get_env/1` answers nil for a
  # value that is plainly sitting in the file, unless somebody exported it by
  # hand first. Three of story 985's criteria failed on exactly that, reporting
  # a missing token that was never missing.
  #
  # Read the environment first, so an operator who did export something wins,
  # and fall back to the file the value actually lives in. Parsing it here is
  # what Dotenvy does for the application; the alternative is a suite that only
  # runs for whoever remembered the incantation.
  defp spex_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> dotenv_value(name)
    end
  end

  # The environment's own file first, then the shared one — the order Dotenvy
  # layers them in, so a value set for test wins over the same name set for
  # everything.
  # Resolved at compile time, not called at runtime. `Mix` is not bundled in a
  # release, so a `Mix.env()` here puts the module in the beam's atom table and
  # `release_safety_test.exs` refuses the build — correctly: it would raise
  # `UndefinedFunctionError` the first time it ran in one.
  @dotenv_files ["envs/#{Mix.env()}.env", "envs/.env"]

  defp dotenv_value(name) do
    @dotenv_files
    |> Enum.find_value(fn file ->
      case File.read(Path.expand(file, File.cwd!())) do
        {:ok, contents} -> find_dotenv_value(contents, name)
        _ -> nil
      end
    end)
  end

  defp find_dotenv_value(contents, name) do
    contents
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(String.trim(line), "=", parts: 2) do
        [^name, value] -> value |> String.trim() |> String.trim(~s("))
        _ -> nil
      end
    end)
  end
end
