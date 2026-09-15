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
      CmsHarness,
      CodeMySpec,
      CodeMySpec.AcceptanceCriteria,
      CodeMySpec.AccountSecrets,
      CodeMySpec.Accounts,
      CodeMySpec.AgentHarness,
      CodeMySpec.AgentTasks,
      CodeMySpec.Agents,
      CodeMySpec.Analysis,
      CodeMySpec.Analytics,
      CodeMySpec.AppTokens,
      CodeMySpec.Architecture,
      CodeMySpec.Auth,
      CodeMySpec.BddRules,
      CodeMySpec.BddSpecs,
      CodeMySpec.Components,
      CodeMySpec.Configurations,
      CodeMySpec.Conversations,
      CodeMySpec.Deploys,
      CodeMySpec.Environments,
      CodeMySpec.Epics,
      CodeMySpec.Events,
      CodeMySpec.Faults,
      CodeMySpec.FileEdits,
      CodeMySpec.Files,
      CodeMySpec.Generators,
      CodeMySpec.Integrations,
      CodeMySpec.MainAgent,
      CodeMySpec.Mail,
      CodeMySpec.Migration,
      CodeMySpec.Notifications,
      CodeMySpec.Paths,
      CodeMySpec.Permissions,
      CodeMySpec.Personas,
      CodeMySpec.Problems,
      CodeMySpec.ProjectSecrets,
      CodeMySpec.ProjectSync,
      CodeMySpec.Projects,
      CodeMySpec.Promotion,
      CodeMySpec.Provisioning,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Servers,
      CodeMySpec.Sessions,
      CodeMySpec.Stories,
      CodeMySpec.TaskOwner,
      CodeMySpec.TempFile,
      CodeMySpec.UserPreferences,
      CodeMySpec.Users,
      CodeMySpec.Utils,
      CodeMySpec.Validation,
      CodeMySpec.WorkingCopies,
      CodeMySpec.Workspaces,
      CodeMySpecTest,
      CodeMySpecWeb
    ]

  import Ecto.Query, only: [from: 2]

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
    Notifications,
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

  alias CmsHarness.Agents.Tools.RunScript
  alias CmsHarness.Agents.Tools.ToolDocs
  alias CmsHarness.Project.ChannelClient
  alias CodeMySpec.AgentHarness.ConversationRecorder
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.ToolSets
  alias CodeMySpec.AgentTasks.QaStory
  alias CodeMySpec.Analytics.GoogleAnalytics
  alias CodeMySpec.Architecture.SpecStub
  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Configurations
  alias CodeMySpec.Content.CloudflareClient
  alias CodeMySpec.Content.PullClient
  alias CodeMySpec.Content.S3Client
  alias CodeMySpec.Content.TriggerClient
  alias CodeMySpec.Conversations
  alias CodeMySpec.Faults
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Integrations.Integration
  alias CodeMySpec.Integrations.IntegrationRepository
  alias CodeMySpec.Mail.Email
  alias CodeMySpec.Mail.Mailbox
  alias CodeMySpec.Mail.ResendClient
  alias CodeMySpec.Permissions.TapOut
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Provisioning.Cloudflare
  alias CodeMySpec.Provisioning.Credentials
  alias CodeMySpec.Provisioning.Dns
  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Provisioning.Repository
  alias CodeMySpec.Provisioning.Resend
  alias CodeMySpec.Provisioning.Sequence
  alias CodeMySpec.Provisioning.StepRepository
  alias CodeMySpec.Provisioning.Steps
  alias CodeMySpec.Provisioning.Storage
  alias CodeMySpec.Provisioning.Teardown
  alias CodeMySpec.Provisioning.Wait
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.SetupFixtures.ErroringStep
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Users.User
  alias CodeMySpec.Utils.MapAccess
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy
  alias CodeMySpec.Workspaces.PreviewAddress
  alias CodeMySpec.Workspaces.Workspace
  alias CodeMySpec.Workspaces.WorkspacesRepository
  alias CodeMySpecTest.FakeWorkspaceRunner
  alias CodeMySpecTest.WorkspaceWatchers
  alias Phoenix.ConnTest
  alias Plug.Conn

  import Ecto.Query, only: [from: 2]

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

    StepRepository.upsert(scope, :storage, "prod", %{
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
      # provisioning them is not this fixture's job. `publishing_configured/1`
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
    dir = CodeMySpec.TempFile.dir("spex-ssh")
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

  Returns the same shape as `publish_all_records/3`, with the DKIM
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

  @doc "Remove what `publish_all_records/3` created."
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
  Read one agent back, for criteria whose claim is about what the row now says.

  Here rather than in a spex for the same reason `running_agent/3` is: the
  boundary refuses `CodeMySpecSpex` reaching into `CodeMySpec`, and it is right
  to — a spex that queries the database directly has stopped driving the surface
  it is about. This is the narrow exception where the claim *is* about the
  record.
  """
  def fetch_agent(%Scope{} = scope, id), do: CodeMySpec.Agents.fetch_agent(scope, id)

  @doc """
  Every agent the server believes is running, for a criterion whose claim is
  that there is not one.

  An absence is the awkward thing to assert through a surface: a page that shows
  no agent looks the same whether none was started or the page never shows them.
  Criterion 2930 needs exactly that — agreeing to an epic must not start
  anything — so it asks the record, through here rather than around the
  boundary.
  """
  def running_agents(%Scope{} = scope), do: CodeMySpec.Agents.list_running(scope)

  @doc """
  A row for an agent the server believes is running.

  It used to take a process handle, because an agent was a detached OS process
  and the row had to name one. The id is the handle now, so the row comes first
  and the machine is asked to run *that* agent.
  """
  def running_agent(%Scope{} = scope, opts \\ []) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: Keyword.get(opts, :engine, :alloy),
        provider: Keyword.get(opts, :provider, "zai"),
        working_copy: Keyword.get(opts, :working_copy, scope.cwd || "/tmp/a-copy"),
        role: Keyword.get(opts, :role, "coding"),
        continuous: Keyword.get(opts, :continuous, false),
        # What this agent may call, as a list rather than a rule read off the
        # role — so a criterion about scoping asserts on the same column the
        # server enforces from.
        tools: Keyword.get(opts, :tools) || tool_set(Keyword.get(opts, :role, "coding")),
        working_copy_id: scope.active_working_copy_id,
        project_id: scope.active_project_id,
        account_id: scope.active_account_id,
        status: :running
      })

    # The thread that agent talks in. `Agents.start_agent/2` opens one, so an
    # agent recorded as running without it is a state the app never produces —
    # and the page that watches it would 404.
    {:ok, _conversation} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    agent
  end

  defp tool_set(role) when is_binary(role),
    do: role |> String.to_existing_atom() |> tool_set()

  defp tool_set(role) when is_atom(role), do: ToolSets.for_role(role)

  @doc """
  Put an agent mid-turn, the way a turn actually starts.

  Through `record_turn_event/3`, which is what the harness sends when an agent
  begins responding — it stamps `turn_started_at`, and `StopDecision.wake/2`
  reads that to answer "is this agent working". Writing the column here would
  set the same field by a route the product never takes.

  `:running` is the wrong field for this and is the reason the distinction
  needs a fixture at all: it is written on a clean start and survives until a
  clean stop, so it is true of an idle agent all day.
  """
  @spec put_agent_mid_turn(Scope.t(), String.t()) :: :ok
  def put_agent_mid_turn(%Scope{} = scope, agent_id) do
    CodeMySpec.Agents.record_turn_event(scope, agent_id, %{"kind" => "turn_started"})
  end

  @doc """
  Every agent recorded on this project, read back from the database.

  Read back rather than taken from the struct a call returned: `credential` is a
  virtual field populated in memory on the way through, and what these criteria
  ask is what survives to the row.
  """
  def list_agents(%Scope{} = scope), do: CodeMySpec.Agents.list_agents(scope)

  @doc """
  How much of the project's actionable work belongs to this agent's role.

  The number the stop menu and `get_next_requirement` both answer from, so a
  scenario can tell "this agent was left alone because it has nothing" from
  "this agent was left alone with work waiting" — which look identical from the
  outside and mean opposite things.
  """
  def role_queue_size(%Scope{} = scope, agent_id) do
    case CodeMySpec.Agents.fetch_agent(scope, agent_id) do
      {:ok, %{role: role}} -> CodeMySpec.Requirements.actionable_count(scope, role)
      _ -> 0
    end
  end

  @doc """
  Everything actionable right now, as `{role, requirement_name}`, sorted.

  `role_queue_size/2` answers "does this agent have work" and nothing else, and
  a premise that reads zero could be wrong in any of a dozen places up the
  chain. Every criterion about routing needs the same thing when it fails —
  what is on the graph at all — and finding it out meant adding a prerequisite,
  running, reading a number, and guessing again.

  Worth knowing what a zero usually means here. The project chain is one line —
  `stories_exist` gates `technical_strategy` gates everything after it — so a
  project with no story has exactly one actionable node no matter what else the
  fixtures wrote, and every role but product reads empty.
  """
  @spec actionable_work(Scope.t()) :: [{atom(), String.t()}]
  def actionable_work(%Scope{} = scope) do
    # The same path `actionable_count/2` and the stop menu read, so what this
    # lists is what an agent would be counted as having. `compute_all/1` looks
    # like the obvious call and is not: its structs carry `satisfied` and no
    # notion of actionable at all, because actionability is a property of the
    # graph rather than of a node.
    %{actionable: actionable} = CodeMySpec.Requirements.cached_graph_with_actionable(scope)

    actionable
    |> Enum.map(&{&1.role, &1.name})
    |> Enum.sort()
  end

  @doc """
  The conversation an agent's turns land in.

  Keyed on the agent, which is what a conversation belongs to. It used to be
  keyed on the working copy — one thread for the whole team — and with several
  agents on a copy their turns interleaved into it and a reply could not say
  who it was for.
  """
  def agent_conversation(%Scope{} = scope, agent) do
    CodeMySpec.Repo.get_by(CodeMySpec.Conversations.Conversation,
      account_id: scope.active_account_id,
      project_id: scope.active_project_id,
      agent_id: agent.id
    )
  end

  @doc """
  What has been sent to this agent, oldest first.

  The transcript rather than the agent's mailbox, and deliberately: a message
  dispatched to a live agent starts or queues a turn, so reading the queue is a
  race and reading what was *recorded* is not.

  `:operator` because that is the role a message sent to an agent carries.
  This used to read `:orchestrator`, which was retired when it turned out
  `Chat.Runner.to_provider_message/1` dropped that role from every model's
  context — so the rows this helper was reading proved the person watching
  could see something, and never that the agent had been told it. These rows
  are the ones the agent is actually given.
  """
  def messages_to_agent(%Scope{} = scope, agent_id) do
    case CodeMySpec.Repo.get_by(CodeMySpec.Conversations.Conversation,
           account_id: scope.active_account_id,
           project_id: scope.active_project_id,
           agent_id: agent_id
         ) do
      nil ->
        []

      conversation ->
        conversation
        |> CodeMySpec.Conversations.list_messages()
        |> Enum.filter(&(&1.role == :operator))
        |> Enum.map(&message_text/1)
    end
  end

  # A message's text, out of the parts it is stored as.
  #
  # `content` is a list of `%{"type" => ..., "text" => ...}` maps — an
  # orchestrator action carries its sentence plus optional count, tool and kind
  # parts. There is no flat `body`, and reading one raises `KeyError` at exactly
  # the moment the feature starts working, which reads as the feature failing.
  defp message_text(%{content: parts}) when is_list(parts) do
    # Every part that carries text, not only the ones typed "text". An
    # orchestrator action puts its sentence in one part and the call it wants
    # made — `evaluate_task task_id: "…"` — in a part typed "tool". Keeping only
    # "text" drops the half that says what to do, which is the half story 985's
    # QA found agents need spelled out rather than described.
    parts
    |> Enum.filter(&(is_map(&1) and is_binary(Map.get(&1, "text"))))
    |> Enum.map_join("\n", &Map.get(&1, "text"))
  end

  defp message_text(_message), do: ""

  @doc """
  The agents this working copy is supposed to be running.

  The desired state, which is what a harness is told on join — not what anything
  last observed. A stopped agent is absent from it rather than filtered out of
  it, which is the property the resume criteria are about.

  ## Through the channel, not rebuilt here

  This used to assemble its own four-key map. It was a second implementation of
  the answer, and it drifted the way a second implementation does: the channel
  hands back `LaunchRequest.for/1` — credential, transcript, role brief, app url
  — and this handed back an id, a provider, a root and a role. Every criterion
  about what an agent comes back *with* was therefore asserting against a map
  written here, and would have passed with the real answer carrying nothing.

  The channel's own handler is two lines of passthrough over that call, so
  driving it costs nothing and removes the only place the two could disagree.
  """
  def agents_to_restore(%Scope{} = scope) do
    socket = %Phoenix.Socket{assigns: %{scope: scope}}

    {:reply, {:ok, %{"agents" => agents}}, _socket} =
      CodeMySpecWeb.HarnessProjectChannel.handle_in("agents_to_restore", %{}, socket)

    agents
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

  @doc """
  Connects Hetzner for the active project, the same shape as
  `connect_provider/3` for the OAuth providers — Hetzner authenticates with a
  single account-level API token rather than an OAuth grant, so it has no
  `Integrations` row to upsert; it lives as a project secret instead.

  Also grants a placeholder object-storage key pair — `Steps.run(:server,
  ...)` refuses before it reaches the provider at all without one
  (`storage_credentials_ready/2`, since every box it makes serves the
  registry and the registry needs them), which is a different pause than
  anything about servers themselves and would otherwise mask it.
  """
  @spec connect_hetzner(Scope.t(), String.t()) :: {:ok, term()}
  def connect_hetzner(scope, token \\ "spex-placeholder-hetzner-token") do
    {:ok, _} =
      ProjectSecrets.put_value(scope, "hetzner_s3_access_key_id", "spex-placeholder-key-id")

    {:ok, _} =
      ProjectSecrets.put_value(scope, "hetzner_s3_secret_access_key", "spex-placeholder-secret")

    ProjectSecrets.put_value(scope, "hetzner_api_token", token)
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

  @doc "Write a file into an environment — a premise the checkout starts from."
  defdelegate write_file(env, path, contents), to: Environments

  @doc "The project as the database has it, for a premise set after the fixture."
  def reload_project(project), do: CodeMySpec.Repo.get!(project.__struct__, project.id)

  @doc "The bucket an environment's dumps land in, named the way the app names it."
  defdelegate bucket_name(project, environment), to: CodeMySpec.Provisioning.Storage

  @doc """
  Write the deploy boilerplate into an environment, through the generator that
  really writes it.

  A premise, not a step. Story 970's position is that the boilerplate arrives
  with the project — `cms new` generates it — so a criterion about setup
  finishing starts from a project that has it, the same as Sam's would.

  The real generator rather than hand-written stand-ins: the deploy step asks
  `Generators.audit/2` whether the tree is deploy-ready, and a stub Dockerfile
  that satisfied today's audit would keep satisfying it after the audit learned
  to ask for something else — which is the shape of a test that passes for
  years while the thing it names has stopped working.
  """
  @spec generate_deploy_boilerplate(term(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  defdelegate generate_deploy_boilerplate(env, opts),
    to: CodeMySpec.Generators.DeployArtifacts,
    as: :generate

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
  Make a story older, so "the oldest wins" is a fact the premise set.

  The tie-break spex separated two creations with `Process.sleep(10)` and hoped
  the clock had moved. That is a guess about how far apart two inserts land: on
  a loaded machine both rows can take the same timestamp, and the tie-break the
  criterion is about then has nothing to break the tie with. It failed that way
  once in a sweep (48924084).

  Setting the value removes the race rather than widening it.
  """
  @spec age_story(Scope.t(), term(), number()) :: :ok
  def age_story(%Scope{} = _scope, story_id, seconds) do
    at = DateTime.add(DateTime.utc_now(), -round(seconds), :second)
    naive = at |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)

    from(s in CodeMySpec.Stories.Story, where: s.id == ^story_id)
    |> Repo.update_all(set: [inserted_at: naive, updated_at: naive])

    :ok
  end

  @doc """
  A second, live agent on this project, as a scope.

  The other half: something has to still be working, because the reclaim rides on
  a live agent's sync rather than on a schedule.
  """
  @spec live_agent_scope(Scope.t(), keyword()) :: Scope.t()
  def live_agent_scope(%Scope{} = scope, opts \\ []) do
    label = Keyword.get(opts, :label, "the agent still working")

    # On its own machine, because a checkout has to be on one: a copy is
    # identified by {project, device, root} and `device_id` is required. A fresh
    # device rather than a shared one for the same reason the working copy is
    # its own — two agents that share an identity are not two agents.
    {:ok, harness} =
      WorkingCopies.issue(scope, nil,
        label: label,
        device: CodeMySpec.DevicesFixtures.device_fixture(scope)
      )

    # Records a root, because the hook rebuilds the scope from the harness row
    # rather than trusting the request: `put_scope/2` takes `cwd` from
    # `harness.root`, and a scope with no cwd never reaches
    # `local_validate_stop/5` — the stop returns early instead of syncing. A live
    # agent without a working copy would therefore drive nothing, and every
    # scenario depending on the sync would fail for a reason unrelated to what it
    # is testing.
    # Its **own** working copy, not the other agent's. Sharing one means the live
    # agent's scan re-creates the very files the reclaim just removed and
    # re-projects the component from them — correct behaviour, and it would make
    # every scenario here assert that reclaiming does nothing.
    root = CodeMySpec.TempFile.owned_dir("reclaim_copy")
    {:ok, harness} = WorkingCopies.report_root(harness, root)

    # Its own **environment**, not just its own path, and registered against its
    # own root. The hook does not trust the request: it rebuilds the scope from
    # the harness row via `Scope.for_local_project/2`, which resolves the
    # environment from the registry. Registered per project — as it was — every
    # harness on the project resolved to the *same* env, so this agent scanned
    # the other one's working copy, found its spec, and re-projected the very
    # component the reclaim had just deleted. Measured: reclaim reported
    # `components_deleted=1` and `ComponentSync` upserted it back in the same
    # request. Correct behaviour on a false premise, and it made every scenario
    # here read as though reclaiming did nothing.
    {:ok, env} = Environments.create(:memory, working_dir: root)
    :ok = Environments.register({:root, root}, env)

    %{scope | active_working_copy_id: harness.id, cwd: root, environment: env}
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
  Record whether a checkout's application is answering, the way its harness
  would.

  `CmsHarness.Sync` measures this against the checkout's `preview_url` on the
  machine that can reach it; a spec has no harness, so it records through the
  same surface the channel handler calls.
  """
  @spec record_preview_status(Ecto.UUID.t(), String.t()) :: :ok
  def record_preview_status(working_copy_id, status) do
    {:ok, copy} = CodeMySpec.WorkingCopies.fetch(working_copy_id)
    {:ok, _} = CodeMySpec.WorkingCopies.record_preview_status(copy, status)
    :ok
  end

  @doc """
  Name the checkout a reader gets when it names none.

  `Projection.vantage/1` resolves a scope with no checkout to the project's
  **default** working copy, so "what does the UI see" is unanswerable until a
  project has one. Every question about a reader that names no checkout —
  whether it is served the cache, whose rows it writes — needs this first, and
  before it existed such a spec could only be written for a project where the
  answer was the unscoped fallback, which is the one case that does not occur
  in practice.

  Added for the criterion about a UI read costing a checkout its cached answer,
  which cannot be set up without it.

  Sets **both** fields that mean "main", because the application has two and
  keeps them apart. `WorkingCopies.designate_main/2` writes `working_copy.main`
  — that is the product operation, and what `WorkingCopies.main/1` reads.
  `Projection.vantage/1` reads `project.default_working_copy_id`, which nothing
  in `lib/` writes at all. Measured 2026-09-12: 8 projects have designated a
  main copy and 1 has `default_working_copy_id` set.

  A fixture that set only the product one produced a project whose unscoped
  reads resolve to `nil`, which is the state of 54 of 55 projects and the one
  where this criterion's bug cannot occur. Setting both reproduces the project
  where it does.
  """
  @spec designate_main(Scope.t(), Ecto.UUID.t()) :: :ok
  def designate_main(%Scope{} = scope, working_copy_id) do
    {:ok, _} = CodeMySpec.WorkingCopies.designate_main(scope, working_copy_id)

    {:ok, _} =
      CodeMySpec.Projects.update_project(scope, scope.active_project, %{
        default_working_copy_id: working_copy_id
      })

    :ok
  end

  @doc """
  Record what a checkout's git state is, the way its harness would.

  `CmsHarness.Sync` measures this on the machine that holds the disk and
  delivers it over the channel; a spec has no harness, so it measures its own
  real checkout and records through the same surface
  (`WorkingCopies.record_git_state/2`). The numbers are real — taken from git in
  a real repository — and only the delivery is short-circuited.

  Here rather than in a criterion because `CodeMySpec.WorkingCopies` is not a
  spex dependency.
  """
  @doc """
  Start watching this project's graph, and subscribe to its announcements.

  Here rather than in a criterion for the same reason as `record_git_state/2`:
  `CodeMySpec.Requirements` is not a spex dependency, so a criterion naming
  `GraphWatcher` or `GraphInputs` is a boundary violation. Reaching the domain
  is the bridge's job.

  Both halves matter and both are easy to forget separately. Without the
  watcher nothing recomputes on a write; without the subscription nothing
  arrives. And `settle_graph/1` answers `:ok` when nothing is watching, so a
  forgotten watcher looks exactly like a graph that did not move.
  """
  @spec watch_graph(Scope.t()) :: :ok
  def watch_graph(%Scope{active_project_id: project_id} = scope) do
    {:ok, _pid} = GraphWatcher.ensure_watching(scope)
    :ok = GraphInputs.subscribe(project_id)
    :ok
  end

  @doc """
  Do the watcher's pending pass now instead of when the debounce expires, and
  wait for what it set in motion.

  A spec that slept would be asserting the timer rather than the mechanism, and
  would be flaky on a loaded box — which is where the analyzer runs. Answers
  `:ok` when no watcher is running, so it is safe to call unconditionally.

  ## Why the pass alone is not enough

  A recompute that finds work wakes the project's agents *off* this process —
  it has to, because rendering a role's menu counts requirements and counting
  them can call `settle/1`, so a watcher waking inside its own recompute would
  be calling itself. So `GraphWatcher.settle/1` correctly answers as soon as
  the graph is current, which is a beat before anybody has been told.

  For a criterion asserting that an agent was told, that beat is the whole
  assertion. Worse than flaky: the wake outlives the test, the sandbox owner
  is already gone, and it dies with `cannot find ownership process ... using
  mode :manual` — which reads as a wake that crashed rather than one that
  arrived late.

  Draining rather than awaiting one task, because a pass can wake several
  agents and the spawn order is not ours to know. Bounded, so a spex that has
  some other long-running task under the same supervisor fails its own
  assertion rather than hanging here.
  """
  @spec settle_graph(Scope.t()) :: :ok
  def settle_graph(%Scope{} = scope) do
    :ok = GraphWatcher.settle(scope)
    drain_background_work()
  end

  @doc """
  What the graph actually holds actionable for a role, right now.

  `CodeMySpec.Requirements` is not a spex dependency, same as `watch_graph/1`
  and `settle_graph/1` above — this is the same bridge, for a spex that needs
  to tell a premise failure from a delivery failure. `Requirements.actionable_for_role/2`
  settles the graph itself before reading, so this reflects whatever the graph
  holds at the moment it is called, not a snapshot from before.
  """
  @spec actionable_names(Scope.t(), atom() | nil) :: [String.t()]
  def actionable_names(%Scope{} = scope, role \\ nil) do
    scope |> Requirements.actionable_for_role(role) |> Enum.map(& &1.name)
  end

  @doc """
  Wait for the background work this project started to finish.

  Public because teardown needs it as much as a scenario does, and for a
  sharper reason. A wake runs in a task off `CodeMySpec.TaskSupervisor`; if it
  is still running when the test's sandbox owner stops, it dies on a connection
  that is no longer there and the supervisor logs the crash at `:error` — and
  `SexySpex.ErrorCapture` fails whichever spex happens to be running when that
  lands. So the straggler does not fail its own test, it fails somebody else's,
  intermittently, and the failure text is a `Task.Supervisor` report with
  nothing in it about either scenario.

  Bounded, so a spex with some other long-running task under the same
  supervisor fails its own assertion rather than hanging here.
  """
  @doc """
  Stop every graph watcher, so nothing new starts during teardown.

  Draining the task supervisor is not enough on its own. A `GraphWatcher` is a
  project-scoped GenServer under a dynamic supervisor and outlives the scenario
  that started it, so its debounce timer can fire *after* the drain and spawn
  another wake into a sandbox that is about to go away. Stopping the watchers
  first closes that window.

  Every one rather than this scope's, because teardown runs before the scope is
  in hand and because a spex run gives each scenario its own project — so the
  watchers alive at the end of one are that one's, and a watcher belonging to
  nothing is what a straggler is.
  """
  @spec stop_graph_watchers() :: :ok
  def stop_graph_watchers do
    CodeMySpec.Requirements.WatcherSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(CodeMySpec.Requirements.WatcherSupervisor, pid)
    end)
  catch
    :exit, _ -> :ok
  end

  @spec drain_background_work() :: :ok
  def drain_background_work do
    drain_background_work(System.monotonic_time(:millisecond) + 5_000)
  end

  defp drain_background_work(deadline) do
    case Task.Supervisor.children(CodeMySpec.TaskSupervisor) do
      [] ->
        :ok

      [pid | _] ->
        await_exit(pid, deadline)

        if System.monotonic_time(:millisecond) < deadline,
          do: drain_background_work(deadline),
          else: :ok
    end
  end

  defp await_exit(pid, deadline) do
    ref = Process.monitor(pid)
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      remaining -> Process.demonitor(ref, [:flush])
    end
  end

  @spec record_git_state(Ecto.UUID.t(), map()) :: :ok
  def record_git_state(working_copy_id, %{} = state) do
    {:ok, copy} = CodeMySpec.WorkingCopies.fetch(working_copy_id)
    {:ok, _} = CodeMySpec.WorkingCopies.record_git_state(copy, state)
    :ok
  end

  @doc """
  Files observed by a *different* working copy on this project.

  Story 892's other arrangement. A reclaim can only be shown to work if something
  else is holding state, and "another checkout saw these files" is reachable —
  through the same channel handler a real harness pushes observations to, with the
  other harness's id on the scope.

  Through the channel rather than `FileSync` directly, for the reason
  `deliver_manifest/2` above records: a bridge that calls the context reimplements
  the behaviour under test, and a spec built on it proves the bridge works and
  nothing else.
  """
  @spec observe_files_as(Scope.t(), WorkingCopy.t() | String.t(), [String.t()], keyword()) ::
          map()
  def observe_files_as(scope, working_copy_id, paths, opts \\ [])

  def observe_files_as(%Scope{} = scope, id, paths, opts) when is_binary(id),
    do: observe_files_as(scope, %WorkingCopy{id: id}, paths, opts)

  def observe_files_as(%Scope{} = scope, %WorkingCopy{} = harness, paths, opts) do
    role = Keyword.get(opts, :role, "implementation")

    observations =
      Enum.map(paths, fn path ->
        %{
          "path" => path,
          "role" => role,
          "mtime" => DateTime.to_iso8601(DateTime.utc_now()),
          "size" => 128,
          "fingerprint" => "spex-#{:erlang.phash2(path)}",
          "valid" => true,
          "validation_errors" => %{},
          "component_id" => nil,
          "story_id" => nil
        }
      end)

    socket = %Phoenix.Socket{
      assigns: %{scope: %{scope | active_working_copy_id: harness.id}}
    }

    case CodeMySpecWeb.HarnessProjectChannel.handle_in(
           "observations",
           %{"observations" => observations},
           socket
         ) do
      {:reply, {:ok, reply}, _socket} ->
        reply

      {:reply, {:error, reason}, _socket} ->
        raise """
        the channel rejected this manifest, so nothing was arranged:

        #{inspect(reason)}

        A fixture that swallows a rejection leaves the spec asserting against an
        empty project and calling that a pass.
        """
    end
  end

  # credo:disable-for-next-line ExSlop.Check.Readability.NarratorDoc
  @doc "The open task an agent holds, wherever it lives. See `Sessions.open_task_for_agent/2`."
  defdelegate open_task_for_agent(scope, agent_id), to: CodeMySpec.Sessions

  @doc "Whether the server is currently carrying analyzer work for this copy."
  defdelegate analysis_runs_in_flight?(scope), to: CodeMySpec.Analysis, as: :runs_in_flight?

  @doc """
  What state each analyzer source is in for this copy.

  For asking whether analysis was *asked for*, which `runs_in_flight?/1` cannot
  answer here: a run is dispatched inline under test, so it has already finished
  by the time a `then_` looks and "in flight" is false whether or not anything
  was ever enqueued. The state map still remembers.
  """
  defdelegate analysis_status(scope), to: CodeMySpec.Analysis, as: :status

  @doc """
  An analyzer run for this copy that finished badly.

  For premises about what a stop does next: `validate_stop/3` enqueues with
  `only_failed: true` on the no-changed-files path, so a *failed* run is the
  state that makes a stop re-run something and a completed one is not. Without
  it a spec asserting "the turn end enqueued the analyzers" passes on runs an
  earlier step already caused, and proves nothing.
  """
  def failed_analysis_run(%Scope{} = scope, source) do
    CodeMySpec.AnalysisFixtures.analysis_run_fixture(scope, %{
      source: source,
      status_override: :failed
    })
  end

  @doc """
  An agent's turn ending, as it arrives on the channel.

  The same `agent_turn_event` push `CmsHarness.Agents.Engine` sends from
  `settle/2` when a turn is over. A spec cannot run a real turn — that needs a
  provider and a model — and what the server owns is what it does when one ends,
  which is exactly what arrives here.

  Same reasoning and same shape as `record_turn/4` below: the proxy that
  produces the push lives in `cms_harness`, so a spec drives the channel's own
  entry rather than a second version of it.
  """
  def end_turn(scope, agent_id, opts \\ [])

  def end_turn(%Scope{} = scope, agent_id, []) do
    socket = %Phoenix.Socket{assigns: %{scope: scope}}

    # Both shapes, because this handler acknowledges and the sibling above does
    # not. Matching only one turns a working push into a `MatchError` inside a
    # `when_`, which reads as the feature failing rather than as the helper
    # being wrong about the reply.
    case CodeMySpecWeb.HarnessProjectChannel.handle_in(
           "agent_turn_event",
           %{
             "agent_id" => agent_id,
             "event" => ChannelClient.encode_turn_event(%{event: :turn_ended})
           },
           socket
         ) do
      {:noreply, _socket} -> :ok
      {:reply, _reply, _socket} -> :ok
    end
  end

  # Cassette opts (`:compile_output_file` and friends — see
  # `CodeMySpec.Validation.validate_stop/3`) have no wire representation: a
  # real harness never sends them, and the channel payload above has nowhere
  # to carry them. Driven straight through `Agents.record_turn_event/4`
  # instead of the socket when a spex supplies any, which is the same escape
  # `Hooks.Stop` already gives the external path — the channel round-trip
  # this skips is a two-line passthrough with nothing of its own to exercise.
  def end_turn(%Scope{} = scope, agent_id, opts) do
    :ok = CodeMySpec.Agents.record_turn_event(scope, agent_id, %{"kind" => "turn_ended"}, opts)
  end

  @doc """
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
    Conversations.find_or_create_session_conversation(
      scope.active_account_id,
      scope.active_project_id,
      "sprite"
    )
  end

  @doc """
  The path of the transcript for this project's most recent agent session.

  The page used to be per-project and is now per-session — one page per agent,
  because a project with five agents was showing whichever one moved last. A
  spex that records a turn and then wants to look at it needs the conversation's
  id, and the id is created inside the recorder rather than by the spex.

  So the bridge answers "the one I just wrote to", which is what every one of
  these scenarios means. `Conversations.get_agent_conversation/2` is the same
  newest-first lookup the page itself used before the split.
  """
  @spec agent_conversation_path(Scope.t()) :: String.t()
  def agent_conversation_path(%Scope{} = scope) do
    base = "/app/projects/#{scope.active_project_id}/agent-conversation"

    case Conversations.get_agent_conversation(scope, scope.active_project_id) do
      nil -> base
      conversation -> "#{base}?conversation=#{conversation.id}"
    end
  end

  @doc """
  The path of one named agent's transcript.

  `agent_conversation_path/1` answers "the one that moved last", which is what
  a scenario with a single agent means. A scenario with two of them needs to say
  which, and "last" is exactly the wrong answer there — two agents on one
  project would both be read from whichever page happened to be newest, so an
  assertion about one and a refutation about the other would both be looking at
  the same transcript and could not disagree.

  `find_or_create_agent_conversation/3` is the same call `running_agent/2` makes,
  so it finds that agent's thread rather than opening a second one.

  The conversation goes in the query string, matching `agent_conversation_path/1`
  and the one route the router actually has. This was written as a path segment
  and every caller 404ed — `live/2` then fails inside `LiveViewTest` with a
  `FunctionClauseError` about static tokens rather than saying "no route", which
  reads as a broken page and is a broken URL.
  """
  @spec agent_conversation_path(Scope.t(), %{id: Ecto.UUID.t()}) :: String.t()
  def agent_conversation_path(%Scope{} = scope, %{id: agent_id}) do
    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent_id
      )

    "/app/projects/#{scope.active_project_id}/agent-conversation?conversation=#{conversation.id}"
  end

  @doc """
  Ask a question the way `ask_user` does, and get its id back.

  A spex about the notifications inbox has to put a question there, and the
  only honest way to do that is the call the MCP tool makes. Going through
  `create_question_request/2` also gets the side effects the criteria are
  about — the push attempt, and the broadcast the navbar badge listens to —
  which a bare insert would silently skip, leaving a live-count scenario
  passing against a count that never moved.

  `session_external_id` is what ties a question to the conversation it was
  asked in; nil means it was asked outside a harness.

  Options are `%{"label" => …}` maps because that is the shape `AskUserQuestion`
  sends and the shape the form renders — a bare string here raises inside the
  component, several layers from the fixture that produced it.
  """
  @spec ask_question(integer(), keyword()) :: String.t()
  def ask_question(user_id, opts \\ []) do
    {:ok, request} =
      Notifications.create_question_request(user_id, %{
        "title" => Keyword.get(opts, :title, "Claude Code has a question"),
        "questions" =>
          Keyword.get(opts, :questions, [
            %{
              "question" => "Which approach?",
              "options" => [%{"label" => "A"}, %{"label" => "B"}]
            }
          ]),
        "session_external_id" => Keyword.get(opts, :session_external_id)
      })

    request.id
  end

  @doc """
  Request a tool permission the way the Claude Code hook does.

  The inbox lists questions and permission requests together, so a scenario
  about ordering or isolation needs both kinds present — one kind alone cannot
  show that they interleave correctly.
  """
  @spec request_permission(integer(), keyword()) :: String.t()
  def request_permission(user_id, opts \\ []) do
    {:ok, request} =
      Notifications.create_permission_request(user_id, %{
        "tool_name" => Keyword.get(opts, :tool_name, "Bash"),
        "tool_input" => Keyword.get(opts, :tool_input, %{"command" => "mix test"})
      })

    request.id
  end

  @doc """
  Answer a question, as the answering surface does.

  Used by scenarios whose *setup* needs answered history — a criterion about
  pending items sorting above resolved ones needs a resolved one to exist.
  A scenario testing the act of answering drives the page instead.
  """
  @spec answer_question(String.t(), map()) :: :ok
  def answer_question(id, answers) do
    {:ok, _} = Notifications.answer_question_request(id, answers)
    :ok
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

  # A real Anthropic response never repeats a block id within one message, and
  # a turn that calls several tools at once is exactly what the grouping UI
  # (story 984) needs to exercise — a fixed id here duplicated the DOM id
  # LiveView renders per call and crashed the render instead of the assertion.
  def tool_block(name, input) do
    %{
      "type" => "tool_use",
      "id" => "toolu_spex_#{System.unique_integer([:positive])}",
      "name" => name,
      "input" => input
    }
  end

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
  A story that is actually in the graph, optionally belonging to one checkout.

  `authored_story/3` makes a story; it does not make one the graph projects.
  `Preloader.load/1` takes only `ready_for_dev` stories, and narrows those to
  the ones assigned to this checkout or to none — so a spec about what a
  particular vantage sees cannot be written from `authored_story/3` alone, and
  three of them worked around it by asserting on components instead.

  `working_copy: id` is what makes two vantages disagree: a story assigned to
  one checkout is invisible to another and visible to a reader that names no
  checkout at all, which is the asymmetry the projection has to survive.

  Added with criterion 3359, which needs a story that one checkout can see and
  another cannot.
  """
  @spec released_story(Scope.t(), String.t(), keyword()) :: Story.t()
  def released_story(%Scope{} = scope, title, opts \\ []) do
    story = authored_story(scope, title, opts)

    attrs =
      %{ready_for_dev: true}
      |> then(fn a ->
        case Keyword.get(opts, :working_copy) do
          nil -> a
          id -> Map.put(a, :working_copy_id, id)
        end
      end)

    {:ok, released} = CodeMySpec.Stories.update_story(scope, story, attrs)
    released
  end

  @doc """
  Push every stored requirement's freshness into the past.

  `checked_at` is truncated to the second, so two reads inside one second are
  indistinguishable and a recompute that happened looks like one that did not.
  The fix is to stamp rather than to sleep: backdate what is there, then
  anything recomputed afterwards carries an obviously newer time and anything
  left alone still carries the old one.

  Added for criterion 3424, which asks which requirements an observation
  actually cost — a question that cannot be asked while every reading falls in
  the same second.
  """
  @spec backdate_requirement_freshness(Scope.t()) :: :ok
  def backdate_requirement_freshness(%Scope{active_project_id: project_id}) do
    past =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-3600, :second)
      |> NaiveDateTime.truncate(:second)

    {_, _} =
      CodeMySpec.Repo.update_all(
        from(n in "requirements",
          where:
            n.project_id == type(^project_id, :binary_id) or
              n.component_id in subquery(
                from(c in "components",
                  where: c.project_id == type(^project_id, :binary_id),
                  select: c.id
                )
              ) or
              n.story_id in subquery(
                from(st in "stories",
                  where: st.project_id == type(^project_id, :binary_id),
                  select: st.id
                )
              )
        ),
        set: [checked_at: past]
      )

    :ok
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
    ConnTest.build_conn()
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

  @doc """
  The question id out of what `AskUserQuestion` answered.

  The tool reports it in prose — "Question id: <uuid>" — because its reader is
  an agent rather than a parser. A spex that needs to answer the question it
  just asked has to get the id from somewhere, and reading it back out of the
  tool's own reply keeps the scenario on the surface instead of reaching into
  the table the tool wrote.
  """
  @spec question_id_from(String.t()) :: String.t()
  def question_id_from(response_text) do
    [_, id] = Regex.run(~r/Question id: ([0-9a-f-]{36})/, response_text)
    id
  end

  @doc """
  Answer a question the way the person answering it does.

  `Notifications.answer_question_request/2` is what the inbox form calls, and it
  is the only thing that marks a request answered and releases whoever was
  waiting on it. A spex that set the status itself would pass against a listing
  filtering on a field nothing in the product ever writes.

  `answers` is keyed by the question's own text, which is the shape the form
  submits and the shape the waiting side reads.
  """
  @spec answer_question(Scope.t(), String.t(), String.t()) :: :ok
  def answer_question(%Scope{} = _scope, question_id, label) do
    request = CodeMySpec.Repo.get!(CodeMySpec.Notifications.QuestionRequest, question_id)

    answers =
      Map.new(request.questions, fn question -> {Map.fetch!(question, "question"), label} end)

    {:ok, _answered} = CodeMySpec.Notifications.answer_question_request(question_id, answers)

    :ok
  end

  @doc """
  Whether this project asks for spec files, and a component to ask it about.

  `require_specs` is what `graph_for_type/1` filters a template by, so turning it
  off is how a project stops needing a whole class of requirement — the surface
  behind criterion 3359.
  """
  def require_specs(%Scope{} = scope, required?) do
    CodeMySpec.Configurations.get_or_create(scope)
    {:ok, _config} = CodeMySpec.Configurations.update(scope, %{require_specs: required?})
    :ok
  end

  @doc """
  A schema component, whose whole template is spec requirements.

  `schema_graph/0` is `spec_file` and `spec_valid` and nothing else, which makes
  it the type that computes *zero* requirements once specs are off — the case
  that kept stale rows forever.
  """
  def a_schema_component(%Scope{} = scope) do
    CodeMySpec.Components.create_component(scope, %{
      name: "Calculator",
      module_name: "#{scope.active_project.module_name}.Calculator",
      type: "schema"
    })
  end

  @doc "The stop hook's blocking decision, as the hook itself asks for it."
  # Drops the block key. `validate_stop/3` returns `{:error, reason, key}` — the
  # key is R8's repeat identity for the finding set, not something a spec has an
  # opinion about, and every one of these asserts on the reason.
  #
  # `opts` is the same cassette escape hatch `end_turn/3` carries
  # (`:compile_output_file` and friends, test-only) — passed straight through
  # to `Validation.validate_stop/3`.
  def validate_stop(scope, opts \\ [])

  def validate_stop(%Scope{} = scope, opts) do
    case CodeMySpec.Validation.validate_stop(scope, nil, opts) do
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
      ConnTest.build_conn()
      |> Plug.Conn.put_req_header("x-harness-id", scope.active_working_copy_id)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> ConnTest.dispatch(
        CodeMySpecLocalWeb.Endpoint,
        :post,
        "/api/skills/start",
        %{"skill" => "implement", "external_id" => external_id}
      )
      |> ConnTest.json_response(200)

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

  # -- Agents on this machine --
  #
  # Story 1038's criteria are about what a *running* agent carries and what a
  # script it runs can reach, so they start one. Through the bridge because
  # `CodeMySpecSpex` is its own Boundary and cannot name `CmsHarness` directly.
  defdelegate launch_agent(request), to: CmsHarness.Agents, as: :launch
  defdelegate halt_agent(agent_id), to: CmsHarness.Agents, as: :halt

  @doc "What one agent is doing right now — mid-turn, and how much is behind it."
  defdelegate agent_status(agent_id), to: CmsHarness.Agents, as: :status

  @doc """
  Give an agent something to do without waiting for the turn.

  `send_message/4` rather than `message/4`: a spec that waited would wait on a
  model, and what these criteria are about is what happens to a *delivery* while
  an agent is busy — which needs the agent busy, not the spec blocked.
  """
  def send_agent_message(agent_id, text) do
    CmsHarness.Agents.send_message(agent_id, "spec-" <> Ecto.UUID.generate(), text)
  end

  defdelegate agent_tools(agent_id), to: CmsHarness.Agents, as: :tools
  defdelegate agent_tool_context(agent_id), to: CmsHarness.Agents, as: :tool_context

  @doc "Say what this scope's working copy machine can do, as a join would."
  def record_machine_tools(%Scope{active_working_copy_id: id}, names) do
    {:ok, copy} = CodeMySpec.WorkingCopies.fetch(id)
    CodeMySpec.WorkingCopies.record_machine_tools(copy, names)
  end

  @doc "Run a script as this agent would, through the tool it carries."
  def run_script(script, context),
    do: RunScript.execute(%{"script" => script}, context)

  @doc "Ask what it may call, through the tool it carries."
  def tool_docs(input, context),
    do: ToolDocs.execute(input, context)

  @doc "What one answer may cost the turn."
  defdelegate max_result_chars(), to: RunScript

  # -- Devices --
  #
  # A checkout is identified by {project, device, root} and `device_id` is
  # required, so a spex that joins a working copy needs a machine to join from.
  # Through the bridge like everything else: `CodeMySpecSpex` is its own
  # Boundary and cannot reach `CodeMySpec.DevicesFixtures` directly.
  defdelegate device_fixture(scope), to: CodeMySpec.DevicesFixtures
  defdelegate device_fixture(scope, attrs), to: CodeMySpec.DevicesFixtures

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

  @doc "The user with this email, or `nil`. See `account_owned_by/1`."
  def user_with_email(email), do: Repo.get_by(User, email: email)

  @doc """
  The first account `user` owns, or `nil`.

  A lookup rather than a fixture. Setup helpers create against a sandbox that
  rolls back, so "already there" never happens and asking is pointless — until
  the run points at a database that keeps its rows, when creating a second one
  is the wrong answer.

  Oldest first, and by ownership rather than by name: the accounts a persistent
  database is already holding were created by earlier runs under generated
  slugs, so anything keyed on a name invented later finds none of them and
  makes a fourth.
  """
  def account_owned_by(user) do
    Repo.one(
      from(a in CodeMySpec.Accounts.Account,
        join: m in CodeMySpec.Accounts.Member,
        on: m.account_id == a.id,
        where: m.user_id == ^user.id and m.role == :owner,
        order_by: [asc: a.inserted_at, asc: a.id],
        limit: 1
      )
    )
  end

  # -- Projects --
  defdelegate project_fixture(scope, attrs \\ %{}), to: ProjectsFixtures

  @doc "The account's project with this name, or `nil`. See `account_owned_by/1`."
  def project_named(account_id, name) do
    Repo.get_by(Project, account_id: account_id, name: name)
  end

  # -- Content publishing --

  @doc """
  Stub the outbound halves of publishing, recording each call to `test_pid`.

  A spex may not call `send/2` — specs drive the surface, they do not post
  messages at it — and the rule holds for helpers in the file too. Recording
  what a stub was asked to do is the exception the rule is not about, so it
  lives here, where the bridge is allowed to.

  The two clients are stubbed separately rather than in a loop that branches on
  which one it is: the message each records has a different shape, and that
  difference is the whole content of the two stubs.
  """
  @spec stub_publishing_outbound(pid()) :: :ok
  def stub_publishing_outbound(test_pid) do
    stub_s3_puts(test_pid)
    stub_trigger_posts(test_pid)
  end

  @doc """
  Stub the content bucket, sending `{:s3_put, target, body}` per upload.

  The body travels whether or not the caller reads it. Story 712 had two
  versions of this stub — one recording the target, one the target and the
  body — and a criterion that wanted the body had to carry its own copy of the
  scaffolding to get it.
  """
  @spec stub_s3_puts(pid()) :: :ok
  def stub_s3_puts(test_pid) do
    Req.Test.set_req_test_to_shared(%{})

    stub_client(S3Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:s3_put, conn.host <> conn.request_path, body})
      {conn, ""}
    end)
  end

  @doc """
  Stub the client's pull trigger, sending `{:trigger, request}` per POST.

  `request` carries the url, the authorization header and the decoded body,
  which is what the criteria about *what the trigger says* need — and costs the
  ones that only care whether it fired nothing.
  """
  @spec stub_trigger_posts(pid()) :: :ok
  def stub_trigger_posts(test_pid) do
    Req.Test.set_req_test_to_shared(%{})

    stub_client(TriggerClient, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:trigger,
         %{
           url: "#{conn.scheme}://#{conn.host}#{conn.request_path}",
           auth: conn |> Plug.Conn.get_req_header("authorization") |> List.first(),
           body: Jason.decode!(raw)
         }}
      )

      {conn, ~s({"status":"accepted","sync_id":"sync-1"})}
    end)
  end

  @doc """
  Stub Cloudflare's purge endpoint, sending `{:cf_purge, urls}` per call.
  """
  @spec stub_cloudflare_purges(pid()) :: :ok
  def stub_cloudflare_purges(test_pid) do
    stub_client(CloudflareClient, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:cf_purge, raw |> Jason.decode!() |> Map.get("files", [])})

      {conn, ~s({"success":true})}
    end)
  end

  defp stub_client(module, record) do
    previous = Application.get_env(:code_my_spec, module, [])
    Application.put_env(:code_my_spec, module, plug: {Req.Test, module})

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, module, previous)
    end)

    Req.Test.stub(module, fn conn ->
      {conn, body} = record.(conn)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)

    :ok
  end

  @doc """
  Serve a content pull from `rows`, recording `{:pull_fetch, url}` per fetch.

  Story 713 carried six copies of this stub, each about thirty lines, and they
  differed in three places: whether the advertised hash matches the blob,
  whether a manifest field is dropped, and whether fetches were recorded at
  all. Those three are the entire subject of the criteria that use them, and
  they were the hardest thing to find in the file.

      stub_content_pull(rows)
      stub_content_pull(rows, hash: :mismatched)
      stub_content_pull(rows, manifest: %{drop: "content_blob_hash"})
      stub_content_pull(:no_content)

  `:no_content` answers `{}` to everything, for the criteria that only ask
  whether a fetch happened at all. Recording is unconditional: a caller that
  does not read the messages pays nothing for them, and the alternative was a
  second copy of the stub.
  """
  @spec stub_content_pull([map()] | :no_content, keyword()) :: :ok
  def stub_content_pull(rows, opts \\ [])

  def stub_content_pull(:no_content, opts) do
    install_pull_stub(fn _path -> "{}" end, opts)
  end

  def stub_content_pull(rows, opts) do
    blob_json = Jason.encode!(rows)
    manifest_json = rows |> pull_manifest(blob_json, opts) |> Jason.encode!()

    install_pull_stub(
      fn
        "/manifest.json" -> manifest_json
        "/content.json" -> blob_json
        _other -> "{}"
      end,
      opts
    )
  end

  defp pull_manifest(rows, blob_json, opts) do
    %{
      "version" => "1.0",
      "generated_at" => "2026-05-15T12:00:00Z",
      "content_blob_url" => "https://content.foo.com/content.json",
      "content_blob_hash" => blob_hash(blob_json, Keyword.get(opts, :hash, :matching)),
      "counts" => %{"blog" => length(rows)}
    }
    |> override_manifest(Keyword.get(opts, :manifest, %{}))
  end

  defp blob_hash(blob_json, :matching),
    do: "sha256:" <> (:sha256 |> :crypto.hash(blob_json) |> Base.encode16(case: :lower))

  defp blob_hash(_blob_json, :mismatched), do: "sha256:" <> String.duplicate("0", 64)

  defp override_manifest(manifest, %{drop: key}), do: Map.delete(manifest, key)
  defp override_manifest(manifest, overrides), do: Map.merge(manifest, overrides)

  defp install_pull_stub(answer, opts) do
    test_pid = Keyword.get(opts, :record_to, self())

    Req.Test.set_req_test_to_shared(%{})
    previous = Application.get_env(:code_my_spec, PullClient, [])
    Application.put_env(:code_my_spec, PullClient, plug: {Req.Test, PullClient})

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, PullClient, previous)
    end)

    Req.Test.stub(PullClient, fn conn ->
      send(test_pid, {:pull_fetch, "#{conn.scheme}://#{conn.host}#{conn.request_path}"})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, answer.(conn.request_path))
    end)

    :ok
  end

  # -- Mail --

  @doc """
  Serve Resend's two inbound-mail reads from their recorded bodies.

  A spex may not call `File` — it drives the surface and observes rendered
  output — so reading the recordings belongs here. The path is answered by
  function head rather than a `case` for the same reason it is everywhere else
  in this codebase: the shape of the request is what selects the answer.
  """
  @spec stub_resend_receiving() :: :ok
  def stub_resend_receiving do
    stub_resend(&resend_recording(&1.method, &1.request_path))
  end

  @doc """
  Serve Resend's domain calls, with the registered domain in `status`.

  `:not_started`, `:pending` and `:verified` are Resend's own words for it, and
  each has a recorded response — which is the only thing story 816's six
  domain criteria disagreed about. They each carried a copy of this stub whose
  `case` differed by one arm, so the state a criterion is *about* was buried in
  eleven lines of identical scaffolding.
  """
  @spec stub_resend_domain(:not_started | :pending | :verified) :: :ok
  def stub_resend_domain(status) when status in [:not_started, :pending, :verified] do
    stub_resend(&domain_recording(&1.method, &1.request_path, status))
  end

  @doc """
  Answer every Resend call with the recorded send response.

  For criteria about mail going out, where the domain calls are scaffolding
  rather than subject.
  """
  @spec stub_resend_send() :: :ok
  def stub_resend_send do
    stub_resend(fn _conn -> recorded_body("send") end)
  end

  defp stub_resend(answer) do
    # Shared, because the call is made by the LiveView process rather than the
    # test — a per-process stub leaves it unstubbed and the sync silently finds
    # nothing.
    Req.Test.set_req_test_to_shared(%{})

    previous = Application.get_env(:code_my_spec, ResendClient, [])

    Application.put_env(:code_my_spec, ResendClient,
      api_key: "re_test",
      plug: {Req.Test, ResendClient}
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, ResendClient, previous)
    end)

    Req.Test.stub(ResendClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, answer.(conn))
    end)

    :ok
  end

  defp resend_recording("GET", "/emails/receiving/" <> _id), do: recorded_body("received_email")
  defp resend_recording("GET", "/emails/receiving"), do: recorded_body("received_list")

  # Registering answers with the domain as created; asking about it answers
  # with the status this stub was installed for; triggering verification
  # answers with the trigger's own response.
  defp domain_recording("POST", "/domains", _status), do: recorded_body("domain_create")
  defp domain_recording("POST", "/domains/" <> _id, _status), do: recorded_body("verify_trigger")

  defp domain_recording("GET", "/domains/" <> _id, :not_started),
    do: recorded_body("domain_create")

  defp domain_recording("GET", "/domains/" <> _id, status),
    do: recorded_body("domain_#{status}")

  defp recorded_body(name) do
    File.read!(Path.join(["test", "cassettes", "resend", "#{name}.json"]))
  end

  # -- Workspaces --

  @doc """
  The attribute names the real widget script looks for.

  Read from `Widget.markers/0` rather than written out again: they are a
  published contract, and a fake that copies it keeps serving the old strings
  after the contract moves — so the criteria pass while the real widget stops
  being found, which is the failure the contract exists to prevent. The spex
  boundary cannot name `CodeMySpec.Provisioning` itself, so it comes through
  here.
  """
  defdelegate widget_markers(), to: CodeMySpec.Provisioning.Widget, as: :markers

  @doc """
  Where database dumps are keyed under, from the module that decides it.
  """
  defdelegate dumps_prefix(), to: CodeMySpec.Provisioning.Storage

  @doc """
  Seals a story's Three Amigos session, the way the gate does.

  Here rather than called directly because `CodeMySpecSpex` may not name
  `CodeMySpec.AgentTasks` — this bridge exists to hold exactly that kind of
  reach-through, and three separate fixtures build three-amigos state and all
  three need to seal.

  Through `evaluate/2` rather than by writing the field: it seals only on a
  passing check, so a fixture that set the flag directly could seal a story it
  had left incomplete, and every downstream test would then be built on a state
  the product cannot produce.
  """
  @spec seal_three_amigos(term(), term()) :: :ok
  def seal_three_amigos(scope, story) do
    {:ok, :valid} =
      AgentTasks.ThreeAmigos.evaluate(scope, %{
        entity_type: :story,
        entity_id: to_string(story.id)
      })

    :ok
  end

  @spec install_workspace_runner(keyword(), keyword()) :: :ok
  @doc """
  Swap the workspace runner for the fake one and start it.

  A spex cannot name `CodeMySpecTest.FakeWorkspaceRunner` — `CodeMySpecSpex`
  does not carry `CodeMySpecTest` as a boundary dep, and should not: reaching
  into the app is this module's job, not the criterion's. This bridge already
  has the dep, so the swap belongs here.

  `config` carries the boot timings a criterion needs (`boot_timeout`,
  `poll_interval`) alongside the runner.

  ## Teardown is ordered, and the order is the whole point

  Bringing a workspace up spawns a watcher that polls the database until the
  container answers or dies. Two of story 990's criteria describe a boot that
  is *deliberately* still in progress when the scenario ends, so their watchers
  cannot be waited out — they have to be killed, while everything they call is
  still there.

  Both of the obvious ways to write this teardown break that. `start_supervised!/1`
  stops what it started **before any `on_exit` runs** (probed, not assumed), so
  the watcher's next poll calls a runner that is gone. Clearing the config
  first is worse: the watcher falls back to the default runner, which is the
  real Docker one, and polls it for fifteen minutes.

  Either way the crash is logged at `:error`, and `SexySpex.ErrorCapture`'s
  handler is global — so it fails whichever spex is running at that moment,
  not the one that left the watcher behind. That is what 990/8221 was: a
  failure in a sweep, green in isolation, and not actually 8221's.

  So this is one callback with the order in it — kill this spex's watchers,
  stop the runner they call, then clear the config. The sandbox owner outlives
  all three, because the Case registers `stop_owner` earlier and earlier means
  later on the way out.
  """
  def install_workspace_runner(opts \\ [healthy?: true, serving: :serving], config \\ []) do
    Application.put_env(
      :code_my_spec,
      CodeMySpec.Workspaces,
      Keyword.merge([runner: FakeWorkspaceRunner], config)
    )

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
      nil -> start_runner_with_ordered_teardown(opts)
      _already_running -> FakeWorkspaceRunner.configure(opts)
    end

    :ok
  end

  @doc """
  What the instance was told about itself when it was started.

  The environment the runner was handed, which is everything a container knows
  and the only thing it can onboard with. A spec that needs to act as the
  instance reads it from here rather than being told the answers — a copy id or
  a credential that never reached the environment then fails the spec instead
  of being supplied by it.

  Here rather than reached for directly because the fake is named on this side
  of the boundary and nowhere else.
  """
  @spec workspace_instance_env() :: %{String.t() => String.t()}
  def workspace_instance_env do
    case FakeWorkspaceRunner.calls() do
      [{_name, _app, _port, env} | _] -> Map.new(env)
      [] -> %{}
    end
  end

  defp start_runner_with_ordered_teardown(opts) do
    started_before = WorkspaceWatchers.running()
    {:ok, runner} = FakeWorkspaceRunner.start_link(opts)

    ExUnit.Callbacks.on_exit(fn ->
      WorkspaceWatchers.kill_since(started_before)
      if Process.alive?(runner), do: GenServer.stop(runner)
      Application.delete_env(:code_my_spec, CodeMySpec.Workspaces)
    end)
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
      CodeMySpec.TempFile.dir("spex-unlinked")

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
    dir = CodeMySpec.TempFile.dir("unlinked")
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
      CodeMySpec.TempFile.path("spex-run-report", ".jsonl")

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
  Capture logs with the Logger level lowered to `level` for the duration.

  `Logger.configure/1` as well as the capture, because Logger drops anything
  below its configured level before a handler ever sees it — `capture_log/2`'s
  own `:level` option filters what was already let through.

  Parameterised rather than duplicated because a trace can span levels: story
  812 asserts one dispatch is followed from handler entry to MP delivery, and
  those are `:info` and `:debug` respectively — the delivery line was moved down
  deliberately, since at warning it emitted 2,190 lines in one suite run.
  """
  def capture_log_at(level, fun) when is_function(fun, 0) do
    previous_level = Logger.level()
    Logger.configure(level: level)

    try do
      ExUnit.CaptureLog.capture_log(fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  # -- Stories (QA spex fixture setup, Stories 726/727) --
  #
  # Private: `qa_story_task_fixture/2`'s only caller. The public
  # `story_fixture/2` this used to be was a plain wrapper around
  # `Stories.create_story/2` with no MCP layer to it, so every spex that
  # called it directly has moved to `CodeMySpecSpex.StoryHelpers.create_story/2`
  # instead — the surface a story is actually supposed to be created through.
  @spec story_fixture(Scope.t(), map()) :: Story.t()
  defp story_fixture(scope, attrs) do
    attrs =
      Enum.into(attrs, %{
        title: "QA Story #{System.unique_integer([:positive])}",
        description: "A story for QA spex testing"
      })

    {:ok, story} = Stories.create_story(scope, attrs)
    story
  end

  @doc """
  Records a health-verified deploy for a story on an environment, for spex
  that need "this story is on UAT" to be true.

  Here rather than in a spex for the same reason `running_agent/3` is: the
  boundary refuses `CodeMySpecSpex` reaching into `CodeMySpec` directly, and
  deploy tracking reads and writes `CodeMySpec.Deploys` now, not a file the
  agent wrote for itself (a46f3ec5) — "on UAT" is a row with
  `health_verified_at` set.
  """
  @spec record_deploy(Scope.t(), integer(), String.t(), keyword()) ::
          CodeMySpec.Deploys.Deploy.t()
  def record_deploy(%Scope{} = scope, story_id, environment, opts \\ []) do
    opts = Keyword.put_new(opts, :health_verified_at, DateTime.utc_now())
    {:ok, deploy} = CodeMySpec.Deploys.record(scope, story_id, environment, opts)
    deploy
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
            # Set, or the task does not survive being read back.
            # `Sessions.maybe_prune_orphan_tasks/1` strips any task whose
            # `session_type` is not a known module, and `nil` is an atom that
            # is not one — so a task created without it is pruned on the next
            # read and the fixture quietly produces a session with no tasks.
            session_type: QaStory,
            requirement_name: "qa_complete",
            story_id: story.id,
            project_id: scope.active_project_id,
            # Nameable, because a task can belong to an agent that is not a
            # Claude Code session at all — an orchestrator assigns one to an
            # agent running under Alloy, and the task then lives on the
            # orchestrator's session while naming the other agent. Story 1043's
            # nudge is about exactly that shape.
            agent_id: Keyword.get(opts, :agent_id, "spex-agent"),
            started_at: DateTime.utc_now()
          }
        ]
      })

    {story, task_id, session}
  end

  @doc """
  An active task on the agent's own row — `TaskOwner`'s shape, not a session's.

  `start_task` is what a real Alloy agent calls to claim work, and it goes
  through `TaskOwner.add_task/3` directly on the agent — there is no session in
  the middle. `qa_story_task_fixture/2` models the older shape, a task on
  somebody else's session naming this agent by id, which is what an *external*
  Claude Code session's sub-agent looks like, not one we run ourselves.

  Returns `{agent, task}`, both the updated agent and the task now active on
  it — spex files reach `CodeMySpec` only through this bridge, so the caller
  should not need a second call through `TaskOwner` just to read back what was
  just staged.
  """
  @spec agent_task_fixture(Scope.t(), CodeMySpec.Agents.Agent.t(), keyword()) ::
          {CodeMySpec.Agents.Agent.t(), CodeMySpec.Sessions.Task.t()}
  def agent_task_fixture(%Scope{} = scope, %CodeMySpec.Agents.Agent{} = agent, opts \\ []) do
    task_id = Keyword.get(opts, :id, Ecto.UUID.generate())

    {:ok, agent} =
      TaskOwner.add_task(scope, agent, %{
        id: task_id,
        status: :active,
        requirement_name: Keyword.get(opts, :requirement_name, "qa_complete"),
        story_id: Keyword.get(opts, :story_id),
        # Settable, because a criterion about how long a task has been open
        # cannot produce elapsed time any other way and must not sleep for it.
        started_at: Keyword.get(opts, :started_at, DateTime.utc_now())
      })

    {agent, TaskOwner.active_task(agent)}
  end

  @doc """
  The main agent giving up on a question it could not answer.

  Criterion 3259. Trying and failing has to end with the user, and the act of
  giving up is the thing that has to exist for it to: without one, a question
  the main agent took and could not settle simply stays with it, and an absorbed
  question has no symptom on any surface.
  """
  @spec give_up_on_question(Scope.t(), String.t()) :: :ok
  def give_up_on_question(%Scope{} = scope, question_id) do
    {:ok, _question} = CodeMySpec.MainAgent.give_up_on_question(scope, question_id)
    :ok
  end

  @doc """
  The check-in, run now.

  The cadence's own tick rather than a wait. A spex that waited for the timer
  would be slow and — worse — would pass by accident on a machine loaded enough
  for the timer to fire twice. What every criterion on story 1059 claims is
  about the wake-up's *content and consequences*, and the tick is that wake-up.
  """
  @spec cadence_tick(Scope.t()) :: :ok
  def cadence_tick(%Scope{} = scope), do: CodeMySpec.MainAgent.check_in(scope)

  @doc "How often this project's main agent is woken, in seconds."
  @spec cadence_interval(Scope.t()) :: pos_integer()
  def cadence_interval(%Scope{} = scope), do: CodeMySpec.MainAgent.cadence_interval(scope)

  @doc """
  Set how often this project's main agent is woken.

  Through the configuration the product writes, not a module attribute — the
  whole of criterion 3331 is that the number is somewhere it can be changed
  without a deploy.
  """
  @spec set_cadence_interval(Scope.t(), pos_integer()) :: :ok
  def set_cadence_interval(%Scope{} = scope, seconds),
    do: CodeMySpec.MainAgent.set_cadence_interval(scope, seconds)

  @doc "Whether this project's cadence is still waking its main agent."
  @spec cadence_running?(Scope.t()) :: boolean()
  def cadence_running?(%Scope{} = scope), do: CodeMySpec.MainAgent.cadence_running?(scope)

  @doc """
  Make one of the things the digest reads unanswerable.

  Criterion 3333 is about a digest that *cannot be built*, which is a different
  state from one that finds nothing — and the difference is invisible unless a
  scenario can produce the first. The analyzer ledger is the source broken here
  because it is the one the digest reads that has a failure mode of its own.

  Scoped to this project rather than set on the node, which is what lets QA
  exercise 3333 at all: the seam used to be `Application.put_env/3`, so using it
  live broke every project's digest on a box four other checkouts share, and
  five QA passes in a row refused on exactly that ground (0fb7bf03).
  """
  @spec break_digest_source(Scope.t()) :: :ok
  def break_digest_source(%Scope{active_project_id: project_id}) do
    :ok = Faults.inject(project_id, :digest_unavailable)
    ExUnit.Callbacks.on_exit(fn -> Faults.clear(project_id, :digest_unavailable) end)
    :ok
  end

  @doc """
  Make this project's graph watcher raise instead of recomputing.

  A different fault from `break_digest_source/1`: that one leaves the graph
  itself fine and breaks only what the main agent's digest reads. This is the
  recompute failing outright, so no `{:graph_updated, _}` is ever announced.
  """
  @spec break_graph_recompute(Scope.t()) :: :ok
  def break_graph_recompute(%Scope{active_project_id: project_id}) do
    :ok = Faults.inject(project_id, :graph_recompute_fails)
    ExUnit.Callbacks.on_exit(fn -> Faults.clear(project_id, :graph_recompute_fails) end)
    :ok
  end

  @doc """
  An epic on this project.

  Through `Epics.create_epic/2`, the same call the product agent's `create_epic`
  tool makes, so an epic in a scenario is the shape one really takes.
  """
  def epic_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "an epic #{System.unique_integer([:positive])}",
        slug: "an-epic-#{System.unique_integer([:positive])}",
        description: "what this epic is for"
      })

    {:ok, epic} = CodeMySpec.Epics.create_epic(scope, attrs)
    epic
  end

  @doc """
  Put a story in an epic.

  Through `Stories.update_story/3`, which is what every surface that moves a
  story calls. `epic_id` is a column on the story — one story belongs to at most
  one epic — so there is no join table to write.
  """
  @spec put_story_in_epic(Scope.t(), map() | integer(), map()) :: :ok
  def put_story_in_epic(%Scope{} = scope, %CodeMySpec.Stories.Story{} = story, epic) do
    {:ok, _story} = CodeMySpec.Stories.update_story(scope, story, %{epic_id: epic.id})
    :ok
  end

  # Same reason as `mark_story_ready/2`: a criterion that got its story from
  # `CreateStory` holds the tool's parsed reply, which is a map with an id on
  # it and not a row.
  def put_story_in_epic(%Scope{} = scope, %{id: story_id}, epic),
    do: put_story_in_epic(scope, story_id, epic)

  def put_story_in_epic(%Scope{} = scope, story_id, epic) when is_integer(story_id),
    do: put_story_in_epic(scope, CodeMySpec.Stories.get_story!(scope, story_id), epic)

  @doc """
  Mark a story ready for development, the way the epics page does.

  Takes an id as readily as a struct, because the two ways a criterion comes by
  a story answer differently: `authored_story/3` hands back the row, while
  `:story_linked_to_component` drives `CreateStory` and parses the tool's reply,
  so all it has is a map with an id on it. Both are "the story", and a bridge
  that only accepted one of them made which given ran earlier a thing the
  criterion had to know.
  """
  @spec mark_story_ready(Scope.t(), map() | integer()) :: :ok
  def mark_story_ready(%Scope{} = scope, %CodeMySpec.Stories.Story{} = story) do
    {:ok, _story} = CodeMySpec.Stories.update_story(scope, story, %{ready_for_dev: true})
    :ok
  end

  def mark_story_ready(%Scope{} = scope, %{id: story_id}),
    do: mark_story_ready(scope, story_id)

  def mark_story_ready(%Scope{} = scope, story_id) when is_integer(story_id) do
    mark_story_ready(scope, CodeMySpec.Stories.get_story!(scope, story_id))
  end

  @doc """
  What the machine this checkout runs on is currently carrying.

  The same shape of fact a harness already reports about its preview, its tools
  and its head commit — a thing it observes about itself and pushes on the
  channel — for the box underneath. Driven through the channel rather than
  written to a row, so a scenario cannot produce a state no harness could send.
  """
  @spec report_machine_load(Scope.t(), map()) :: :ok
  def report_machine_load(%Scope{} = scope, load) when is_map(load) do
    socket = %Phoenix.Socket{assigns: %{scope: scope}}

    case CodeMySpecWeb.HarnessProjectChannel.handle_in("machine_load", load, socket) do
      {:noreply, _socket} -> :ok
      {:reply, _reply, _socket} -> :ok
    end
  end

  @doc """
  Switch an agent off without stopping it.

  `set_agent_continuous(scope, id, false)` is what the pause control calls, and
  pausing is deliberately not stopping: the row stays alive and the process
  stays alive, and what goes off is being woken for new work. A scenario that
  wrote the field would be modelling a state the product reaches a different
  way — and the way it reaches it is the part criterion 3305 is about.
  """
  @spec pause_agent(Scope.t(), Ecto.UUID.t()) :: {:ok, map(), atom()} | {:error, term()}
  def pause_agent(%Scope{} = scope, agent_id) do
    CodeMySpec.Agents.set_agent_continuous(scope, agent_id, false)
  end

  @doc """
  A turn this agent has started and not finished.

  The same `agent_turn_event` push `end_turn/3` sends, with the event a
  scenario names instead of `:turn_ended` — so an agent mid-response is
  produced by the harness's own entry point rather than by writing a flag
  nothing in production sets.

  Nothing ends it. That is the state criteria 3279 and 3297 are about: a
  connection open to a model with a response coming back, which from every
  other angle is indistinguishable from an agent that has stopped.
  """
  @doc """
  Put this session into continuous mode, the way `start_implementation` does.

  The stop hook's menu-on-turn-end path is gated on the *session's* own
  `continuous` flag (`Hooks.Stop.continuous_mode?/1`) — a different switch
  from the working copy's loop that `put_to_work/2` turns on. A session made
  through `start_session/1` alone is correctly, silently allowed to stop
  with no menu: continuous mode is what turns a stop into a continuation,
  and nothing about posting session-start opts a session into it.
  """
  @spec make_session_continuous(Scope.t(), String.t()) :: :ok
  def make_session_continuous(%Scope{} = scope, session_id) do
    session = CodeMySpec.Sessions.get_by_external_id(scope, session_id)
    {:ok, _session} = CodeMySpec.Sessions.update_session(scope, session, %{continuous: true})
    :ok
  end

  @spec start_turn(Scope.t(), String.t(), keyword()) :: :ok
  def start_turn(%Scope{} = scope, agent_id, opts \\ []) do
    socket = %Phoenix.Socket{assigns: %{scope: scope}}

    event =
      ChannelClient.encode_turn_event(%{
        event: Keyword.get(opts, :event, :turn_started),
        turn: Keyword.get(opts, :turn, 1)
      })

    case CodeMySpecWeb.HarnessProjectChannel.handle_in(
           "agent_turn_event",
           %{"agent_id" => agent_id, "event" => event},
           socket
         ) do
      {:noreply, _socket} -> :ok
      {:reply, _reply, _socket} -> :ok
    end
  end

  @doc """
  One agent saying something on its own thread.

  `Conversations.add_agent_message/4` is what `AgentHarness.relay_up/2` calls
  when a turn arrives from the machine, so "the agent spoke" means here what it
  means in production. `send_agent_message/2` is the other direction — it
  dispatches to a real harness over the transport — and a scenario about how
  long ago an agent last said something must not need one running.
  """
  @spec agent_said(Scope.t(), map(), String.t()) :: :ok
  def agent_said(%Scope{} = scope, %{id: agent_id, role: role}, text) do
    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent_id
      )

    {:ok, _message} =
      Conversations.add_agent_message(conversation, to_string(role), "assistant", text)

    :ok
  end

  @doc """
  A tool call on this agent's own conversation, the way `Agents.Engine` records one.

  Same conversation `agent_said/3` writes to — keyed on the agent, not on a
  session — so a scenario about one agent's turns can mix plain messages and
  tool calls in the order they actually happened.
  """
  @spec agent_tool_call(Scope.t(), map(), String.t(), String.t(), map()) :: :ok
  def agent_tool_call(%Scope{} = scope, %{id: agent_id}, call_id, name, arguments) do
    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent_id
      )

    {:ok, _} = Conversations.add_tool_call(conversation, call_id, name, arguments)
    :ok
  end

  @doc """
  What that call returned, on the same agent-keyed conversation.

  `opts` takes `:failed?` (default `false`) so a scenario can state a call
  that came back an error without paraphrasing it into a plain message.
  """
  @spec agent_tool_result(Scope.t(), map(), String.t(), String.t(), String.t(), keyword()) :: :ok
  def agent_tool_result(%Scope{} = scope, %{id: agent_id}, call_id, name, text, opts \\ []) do
    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent_id
      )

    {:ok, _} = Conversations.add_tool_result(conversation, call_id, name, text, opts)
    :ok
  end

  @doc """
  Put this agent's transcript in the past.

  Backdates every message on the agent's own conversation, so a scenario can
  ask what an agent that has said nothing for forty-five minutes looks like
  without waiting forty-five minutes.

  The messages rather than the agent row: "when did it last say something" is a
  question about what it said, and `agents.updated_at` moves for reasons that
  have nothing to do with speaking — a status change, a task claimed, a reap
  pass. A view reading the row would call an agent chatty because something
  else touched it.
  """
  @spec age_agent_messages(Scope.t(), map(), number()) :: :ok
  def age_agent_messages(%Scope{} = _scope, %{id: agent_id}, seconds) do
    at = DateTime.add(DateTime.utc_now(), -round(seconds), :second)
    naive = at |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)

    conversation_ids =
      from(c in CodeMySpec.Conversations.Conversation,
        where: c.agent_id == type(^agent_id, :binary_id),
        select: c.id
      )
      |> Repo.all()

    from(m in CodeMySpec.Conversations.Message, where: m.conversation_id in ^conversation_ids)
    |> Repo.update_all(set: [inserted_at: naive, updated_at: naive])

    :ok
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

  ## Why this is a fixture rather than the real callback

  `BootstrapController`'s callback is the actual production writer of
  this row, but reaching it means a full PKCE exchange — an
  `AuthState`, a redirect to a real OAuth provider, a human consent
  screen, and a callback carrying a code only the provider can mint.
  Same shape as `connect_provider/3`'s reasoning: there is no surface a
  spex can drive here, only a fixture or no coverage for anything
  downstream of "already signed in."
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

  # -- Framework-issue remote stub --

  # -- Stub call observation (`send/2` stays out of _spex.exs files) --

  @doc """
  Notes a matching-method-and-path call for a spex's own
  `assert_received`/`refute_received`, without the spex file touching
  `send/2` directly (`NoDirectSendInSpex`). Sends `message` to `test_pid`
  only when `method`/`path` name the create-server request; every other
  request is silently ignored.
  """
  @spec notify_server_create(pid(), String.t(), String.t(), term()) :: :ok
  def notify_server_create(test_pid, "POST", "/v1/servers", message), do: send(test_pid, message)
  def notify_server_create(_test_pid, _method, _path, _message), do: :ok

  @doc """
  Notes every call reaching a stub, tagged `{tag, request_path}`, for a
  spex's own `assert_received`/`refute_received`.
  """
  @spec notify_call(pid(), atom(), String.t()) :: :ok
  def notify_call(test_pid, tag, request_path), do: send(test_pid, {tag, request_path})

  @doc """
  Stub `client` to answer 200 with `response_body`, noting each call's
  `authorization` header for a spex's own `assert_received`.
  """
  @spec stub_capturing_authorization(module(), pid(), String.t()) :: :ok
  def stub_capturing_authorization(client, test_pid, response_body) do
    Req.Test.stub(client, fn conn ->
      send(test_pid, {:authorization, Conn.get_req_header(conn, "authorization")})

      conn
      |> Conn.put_resp_content_type("application/json")
      |> Conn.send_resp(200, response_body)
    end)
  end

  @doc """
  Stub `client` to accept and answer `%{"ok" => true}`, noting each call's
  host for a spex's own `assert_received`.
  """
  @spec stub_accepting_and_noting_host(module(), pid()) :: :ok
  def stub_accepting_and_noting_host(client, test_pid) do
    Req.Test.stub(client, fn conn ->
      send(test_pid, {:asked, conn.host})
      Req.Test.json(conn, %{"ok" => true})
    end)
  end

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

  @doc """
  Point a project at the remote it already owns.

  For the drill, whose database is rolled back between walks: the repository
  step adopts a repository at setup's own name only when the project already
  points at it, so without this every walk met its own remote as a stranger's.
  """
  def set_project_code_repo(project, url) do
    project
    |> Ecto.Changeset.change(code_repo: url)
    |> CodeMySpec.Repo.update!()
  end

  @doc """
  Give a project the deploy key it already had.

  Through the real changeset rather than `Ecto.Changeset.change/2`, because
  `put_deploy_key_hash/1` is what makes the key findable — the API looks a
  project up by the hash, so a key written around the changeset authenticates
  nothing.
  """
  def set_project_deploy_key(scope, project, key) do
    {:ok, project} = CodeMySpec.Projects.update_project(scope, project, %{deploy_key: key})
    project
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
  Put one project secret, for a premise that needs a known value where the
  code would otherwise mint a random one.

  `Database.credential/2` generates a password when `database_password_<env>`
  is absent, and that value ends up in three places at once — the URL the dump
  authenticates with, the `ALTER USER` the step runs, and the command a
  cassette records. Generated, the first two agree and the third can never
  match again.
  """
  @spec put_project_secret(Scope.t(), String.t(), String.t()) :: :ok
  def put_project_secret(%Scope{} = scope, key, value) do
    {:ok, _} = ProjectSecrets.put_value(scope, key, value)

    :ok
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
  Point an environment at an account server, without a provider round trip.

  The real path — the servers page, or `link_server` — verifies the name
  against the provider first (`Servers.link/2` calls `Hetzner.list_servers`),
  because a human or an agent linking a server should not be able to point
  at one that does not exist. A criterion whose subject is *further down the
  pipeline* — what a project's own devops run does once its environment is
  already linked — does not need that round trip re-proven every time; it
  needs the linked state to already be true when the scenario starts, the
  same reason `seed_environment_ip/3` exists.

  Creates the account's `Server` row if this is the first environment
  pointed at `server_name` (matching `Server.link/2`'s own `on_conflict:
  :nothing`, so linking the same name twice is not an error), then points
  `environment_name` at it.

  Not for a criterion whose claim *is* the link itself — story 989's own
  criteria drive that through the real UI, exactly as `seed_environment_ip/3`
  is not for criteria whose claim is about DNS resolving a server that was
  actually created.
  """
  @spec link_environment_to_server(Scope.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def link_environment_to_server(%Scope{} = scope, environment_name, server_name) do
    alias CodeMySpec.Provisioning.EnvironmentRepository
    alias CodeMySpec.Servers
    alias CodeMySpec.Servers.Server

    with {:ok, _} <- Server.link(scope, %{name: server_name}),
         %{id: server_id} <- Servers.get_linked(scope, server_name) do
      EnvironmentRepository.put(scope, environment_name, %{server_id: server_id})
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Bring up an account server the way only the account-level surface may:
  the box, its shared registry container, and its shared database
  container. `CodeMySpecSpex` may not reach `CodeMySpec.Provisioning.Steps`
  or `CodeMySpec.Servers` directly, which is why this bridges it — the
  claim it backs is a project-scoped criterion's premise (the account
  already granted and bootstrapped a server), not the bootstrap itself.
  """
  @spec bootstrap_account_server(Scope.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def bootstrap_account_server(%Scope{} = scope, server_name, opts \\ []) do
    alias CodeMySpec.Provisioning.Steps
    alias CodeMySpec.Servers

    {:ok, _ssh_key_ids} = Servers.access_key(scope)
    Steps.provision_account_server(scope, server_name, opts)
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
      # Asked rather than inferred from the failure. The 422 below is GitHub's
      # documented answer for "a repository with that name already exists", and
      # treating it as success was right — but it is not the only answer it
      # gives. Creating over the repository this criterion left behind three
      # weeks ago returned `500 ""` and then `502 "Server Error"` on the next
      # attempt, neither of which is 422, so the collision arrived as a raise
      # and the criterion went red on a premise that was already satisfied.
      #
      # A GET settles it in one request and cannot be answered with a server
      # error that means the opposite of what it says. The 422 clause stays for
      # the race: two runs creating the same name at once.
      if adoptable?(owner, name, token, opts) do
        :ok
      else
        post_spex_repository(owner, name, token, opts)
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

  # Present *and* good enough for what was asked. A repository that exists but
  # holds no commit does not satisfy `commits: true` — the premise there is a
  # remote a fresh history cannot fast-forward onto, and an empty one can be
  # fast-forwarded onto perfectly well. Adopting it would make the criterion
  # pass for the wrong reason, which is the failure this whole fixture exists
  # to stop.
  defp adoptable?(owner, name, token, opts) do
    case github_get(owner, name, token, "") do
      {:ok, %{status: 200}} ->
        not Keyword.get(opts, :commits, false) or has_commits?(owner, name, token)

      _ ->
        false
    end
  end

  defp has_commits?(owner, name, token) do
    case github_get(owner, name, token, "/commits?per_page=1") do
      {:ok, %{status: 200, body: [_ | _]}} -> true
      _ -> false
    end
  end

  defp github_get(owner, name, token, suffix) do
    Req.get("https://api.github.com/repos/#{owner}/#{name}#{suffix}",
      headers: [
        {"authorization", "Bearer #{token}"},
        {"accept", "application/vnd.github+json"}
      ]
    )
  end

  defp post_spex_repository(owner, name, token, opts) do
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
  Record that `agent_id` wrote `path`.

  What `FileEdits.track_agent_edit/2` records in production when an agent calls
  `write` or `edit`. A criterion that seeds a finding and expects an agent to be
  blocked by it has to say the agent made it — otherwise the finding belongs to
  nobody, is demoted to advisory, and the scenario asserts against silence.
  """
  def record_agent_edit(agent_id, path) do
    CodeMySpec.FileEdits.track_agent_edit(agent_id, path)
  end

  @doc """
  A completed run for `source` whose fingerprint no longer matches the tree.

  Stale is not the same state as never-ran, and the difference decides what the
  agent is told. A source with no completed run at all is simply not enforced;
  a completed run against a fingerprint that has moved on still blocks, and the
  response gains the footer explaining that a rerun is coming — which is where
  the hook's "curl analysis/wait and stop again" remedy lives.
  """
  def stale_analysis_run(%Scope{} = scope, source) do
    CodeMySpec.AnalysisFixtures.analysis_run_fixture(scope, %{
      source: source,
      input_fingerprint: "stale-fingerprint",
      status_override: :completed
    })
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
  The scan, as a step a scenario can take.

  Writing a file is half of what happens in production; the harness scanning it
  is the other half, and several requirements read only what the scan wrote. An
  integration spec's `## Status` is parsed by `Scanner.validate_integration/1`
  and carried on the File row, because parsing it at evaluate time meant reading
  the working copy from inside the graph computation — a 35-second-limit call to
  the harness, on the hot path of every agent turn.

  So a scenario that writes a file and asks a requirement about it has to scan
  in between, or it is asking about a file the application has never been told
  exists. Named for what it is rather than folded into the writing fixtures: the
  sequence is the point, and hiding it would let a scenario pass while skipping
  the step production cannot skip.
  """
  def scan_working_copy(%Scope{} = scope) do
    {:ok, _} = FileSync.sync(scope, embed: false)
    :ok
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

  # `connect_provider/3` stamps every grant a spex writes, which is what makes
  # one distinguishable from a grant a person connected in the app.
  defp spex_copy?(%Integration{provider_metadata: %{"provider_user_id" => "spex"}}), do: true
  defp spex_copy?(_), do: false

  # Long enough to outlast the slowest step. The inbound probe waits five
  # minutes for Resend to verify the MX records, settles for one, then polls
  # five more for the message — eleven minutes in which nothing can renew the
  # credential it started with.
  @borrowed_token_margin_seconds 20 * 60

  # The borrowed token cannot renew itself: it travels without its refresh
  # token on purpose, because Resend and Cloudflare rotate theirs on every use
  # and a second copy of a single-use credential is what revokes a grant. So
  # whatever life it has when it is borrowed is all it will ever have.
  #
  # `fetch_access_token/2` renews at two minutes to expiry, which is right for
  # an application making one request — and wrong here, where a token with ten
  # minutes left is handed to a step that needs eleven. The inbound step ran
  # 604 seconds and then reported `API key is invalid`, having started with a
  # perfectly good credential that expired underneath it.
  #
  # Ageing the *dev* row is what forces the renewal, and it renews through the
  # application's own path: the row keeps its refresh token, so the rotation
  # happens under the same lock and persists back where it came from. There is
  # still only one owner.
  # Only where there is something to renew with. GitHub's user tokens carry no
  # refresh token at all, and ageing one out would turn a working credential
  # into `:reauthorize_required` — the placeholder path, for a token that was
  # fine. Their stored expiry is a year out, so they never reach the margin
  # anyway; the guard is here so that stays true by construction.
  defp age_out_a_token_too_short_to_finish_on(%Integration{refresh_token: token} = integration)
       when is_binary(token) and token != "" do
    if DateTime.diff(integration.expires_at, DateTime.utc_now()) < @borrowed_token_margin_seconds do
      # Untruncated: the field is `:utc_datetime_usec`, and a second-precision
      # value raises rather than being cast — which fell through to the
      # placeholder and made every Resend call fail instantly instead of ten
      # minutes in.
      integration
      |> Ecto.Changeset.change(expires_at: DateTime.utc_now())
      |> Repo.update!()
    end

    :ok
  end

  defp age_out_a_token_too_short_to_finish_on(_integration), do: :ok

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
      #
      # Except the rows a spex wrote itself. `connect_provider/3` copies the
      # grant onto the spex user, and a run pointed at code_my_spec_dev copies
      # it into the database this is reading — so its own copy, being the
      # newest, became the grant it borrowed the next time. When the copy was
      # `placeholder_grant()` — one failed refresh is enough — the placeholder
      # became the source of truth and every later run read it back with an
      # unexpired `expires_at` and no warning, while Cloudflare answered
      # "Invalid format for Authorization header" to a token reading
      # `spex-placeholder-token`.
      integration =
        Integration
        |> CodeMySpec.Repo.all()
        |> Enum.filter(&(&1.provider == provider and not spex_copy?(&1)))
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

      age_out_a_token_too_short_to_finish_on(integration)

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
  @spec leaked_spex_resources(:all | [:servers | :buckets]) :: [String.t()]
  def leaked_spex_resources(kinds \\ :all) do
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
      previous_s3 = Application.get_env(:code_my_spec, CodeMySpec.Content.S3Client, [])

      # The token *and* both plugs. `config/test.exs` pins
      # `plug: {Req.Test, …}` on every provider client so that a call with no
      # stub raises instead of quietly reaching a provider — right for the
      # suite, and fatal here: this check runs in `connect_providers`, which is
      # setup, so it is outside every cassette and nothing stubs that process.
      # It raised `cannot find mock/stub`, and `case` does not catch a raise,
      # so the guard meant to protect a recording session was the thing that
      # ended it — before a single interaction was written.
      #
      # Both, because the two halves take different routes: servers go through
      # `Provisioning.Hetzner`, buckets through ExAws and `Content.S3Client`.
      # Clearing only the first moves the same failure one layer down, which is
      # exactly what it did.
      #
      # Dropping the pins is not a loosening. Asking the real provider what
      # this account holds is the entire point of the check; a stubbed answer
      # would report nothing and pass, which is the failure it exists to catch.
      # Both are restored below, so nothing that follows sees a live client.
      #
      # Only reachable with real credentials in the environment, i.e. a
      # recording run — the `with` above returns `[]` otherwise.
      Application.put_env(
        :code_my_spec,
        CodeMySpec.Provisioning.Hetzner,
        previous |> Keyword.put(:api_token, token) |> Keyword.delete(:plug)
      )

      Application.put_env(
        :code_my_spec,
        CodeMySpec.Content.S3Client,
        Keyword.delete(previous_s3, :plug)
      )

      names = server_names(kinds) ++ bucket_names(kinds, credentials)

      Application.put_env(:code_my_spec, CodeMySpec.Provisioning.Hetzner, previous)
      Application.put_env(:code_my_spec, CodeMySpec.Content.S3Client, previous_s3)

      spex_named(names)
    else
      _ -> []
    end
  end

  defp server_names(kinds) do
    if want?(kinds, :servers) do
      case Hetzner.list_servers(%CodeMySpec.Users.Scope{}) do
        {:ok, list} -> Enum.map(list, &MapAccess.get(&1, :name))
        _ -> []
      end
    else
      []
    end
  end

  defp bucket_names(kinds, credentials) do
    if want?(kinds, :buckets) do
      case Storage.list_buckets(credentials, []) do
        {:ok, list} -> Enum.map(list, &name_of/1)
        _ -> []
      end
    else
      []
    end
  end

  @doc """
  The `spex-` names in a list. Public because it is the whole of the guard's
  judgement and the only part testable without a provider.

  `spex-drill-*` is excluded. It belongs to `test/drill/provisioning_walk.exs`,
  which keeps its environment between runs on purpose, and no criterion's
  premise is ever satisfied by it — the suite builds `c8024.astralbi.com` and
  the like. Counted as residue, a live environment that was doing nothing wrong
  stopped every recording session.

  The same exclusion, for the same reason, guards `mix cms.provisioning_leaks`
  (`@drill_marker`); there it stands between a sweep and `--delete`.
  """
  @spec spex_named([term()]) :: [String.t()]
  def spex_named(names) do
    Enum.filter(names, fn name ->
      string = to_string(name)

      String.starts_with?(string, "spex-") and
        not Regex.match?(~r/(^|\.)spex-drill([-.]|$)/, string)
    end)
  end

  # `:all` is the default everywhere and stays the answer for anything that has
  # not declared, so an undeclared spex is checked exactly as before.
  defp want?(:all, _kind), do: true
  defp want?(kinds, kind) when is_list(kinds), do: kind in kinds
  defp want?(kind, kind) when is_atom(kind), do: true
  defp want?(_kinds, _kind), do: false

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
      # Through `Credentials.put_value/3` so the fixture lands where the
      # runtime looks. All three of these are account-grain since `48a6e127`
      # — "the same grain as the servers they name" — and writing them per
      # project put them where `Hetzner.token/1` never reads, which is the
      # defect QA found on story 850 (bcd2b2b4). A fixture that stores them
      # the old way would keep passing while the page it stands in for did not.
      Credentials.put_value(
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

  @doc """
  The environments a project's own devops run is actually permitted to touch,
  mirroring `Steps.permitted_environment_rows/1`'s own filter: `devops: :uat`
  drops prod, anything else keeps both. A fixture that bootstraps servers for
  every environment unconditionally stands up a prod box for a project that
  opted out of prod — `Fakes.Hetzner`/`Fakes.Shell` then honestly report one
  exists, and a criterion asserting "and production was not built either"
  fails for real, just not for the reason it's testing.
  """
  @spec devops_environments(Scope.t()) :: [String.t()]
  def devops_environments(%Scope{} = scope) do
    case CodeMySpec.Configurations.get(scope) do
      %{devops: :uat} -> ["uat"]
      _ -> ["prod", "uat"]
    end
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
