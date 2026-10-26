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
    exports: [GraphVerification, StoryIssueBag],
    deps: [
      CmsHarness,
      CmsHarness.Agents,
      CmsHarness.Project,
      # criterion 2351 (story 1132) reads the harness's own HTTP route list.
      CmsHarness.Web,
      # The connected desktop assistance fixture uses the real harness websocket rig.
      CmsHarnessTest,
      CodeMySpec,
      CodeMySpec.Agents.Agent,
      CodeMySpec.Embeddings,
      CodeMySpec.Environments,
      CodeMySpec.Provisioning.Hetzner,
      CodeMySpec.Stories,
      CodeMySpec.AccountSecrets,
      CodeMySpec.Accounts,
      CodeMySpec.AgentHarness,
      CodeMySpec.AgentTasks,
      CodeMySpec.Agents,
      # `launch_agent/1` names the carried tools the way the channel's launch does.
      CodeMySpec.McpServers,
      CodeMySpec.Analysis,
      CodeMySpec.Analysis.HarnessRegistry,
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
      CodeMySpec.Devices,
      CodeMySpec.ExecutionContexts,
      CodeMySpec.Epics,
      CodeMySpec.Events,
      CodeMySpec.Faults,
      CodeMySpec.FileEdits,
      CodeMySpec.Files,
      CodeMySpec.Generators,
      CodeMySpec.Integrations,
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
      CodeMySpec.Qa,
      CodeMySpec.Promotion,
      CodeMySpec.Provisioning,
      CodeMySpec.ProvisioningPlan,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Requirements.GraphInputs,
      CodeMySpec.Servers,
      CodeMySpec.Staffing,
      CodeMySpec.TaskOwner,
      CodeMySpec.TempFile,
      CodeMySpec.UserPreferences,
      CodeMySpec.Users,
      CodeMySpec.Users.Scope,
      CodeMySpec.Utils,
      CodeMySpec.Validation,
      CodeMySpec.WorkingCopies,
      CodeMySpec.AppInstances,
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
    ExecutionContextFixtures,
    ExecutionContexts,
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
    TerminalAgentFixtures,
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
  alias CodeMySpec.Agents.Mailbox, as: AgentMailbox
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.ToolIndex
  alias CodeMySpec.Agents.ToolSets
  alias CodeMySpec.AgentTasks.QaStory
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.Reconciler
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.Analytics.GoogleAnalytics
  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Configurations
  alias CodeMySpec.Content.CloudflareClient
  alias CodeMySpec.Content.PullClient
  alias CodeMySpec.Content.S3Client
  alias CodeMySpec.Content.TriggerClient
  alias CodeMySpec.Conversations
  alias CodeMySpec.Embeddings.HexDocSweep
  alias CodeMySpec.Faults
  alias CodeMySpec.Files.ComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Files.LockfileSweep
  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Integrations.Integration
  alias CodeMySpec.Integrations.IntegrationRepository
  alias CodeMySpec.Mail.Email
  alias CodeMySpec.Mail.Mailbox
  alias CodeMySpec.Mail.ResendClient
  alias CodeMySpec.McpServers.ToolRegistry
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Provisioning.Cloudflare
  alias CodeMySpec.Provisioning.Credentials
  alias CodeMySpec.Provisioning.Dns
  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Provisioning.Repository
  alias CodeMySpec.Provisioning.Resend
  alias CodeMySpec.Provisioning.Steps
  alias CodeMySpec.Provisioning.Storage
  alias CodeMySpec.Provisioning.Teardown
  alias CodeMySpec.Provisioning.Wait
  alias CodeMySpec.ProvisioningPlan.Sequence
  alias CodeMySpec.ProvisioningPlan.StepRepository
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.GraphReport
  alias CodeMySpec.Requirements.GraphStore
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.SetupFixtures.ErroringStep
  alias CodeMySpec.Stories.AcceptanceCriteria
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
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.FakeWorkspaceRunner
  alias CodeMySpecTest.RecordingAgentTransport
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

      published = Enum.map(keep, &publish_dns_record(scope, zone, zone_name, &1))

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

  defp publish_dns_record(scope, zone, zone_name, record) do
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
          accept_inbound_pending(created, sending_domain, pending)

        {:error, reason} ->
          {:error, {:never_verified, sending_domain, reason}}
      end
    end
  end

  defp accept_inbound_pending(created, sending_domain, pending) do
    if Enum.all?(pending, &inbound_record?/1) do
      {:ok, created}
    else
      {:error, {:never_verified, sending_domain, {:still_verifying, pending}}}
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
  Back-date a step's last check, without re-running or re-verifying it.

  There is no surface path to fast-forward the clock — "checked a week ago"
  is a precondition a real run cannot produce inside a test. Leaves every
  other field (state, resources, position) exactly as the real run left it;
  only `verified_at` moves.
  """
  @spec age_step_check(Scope.t(), atom(), String.t() | nil, non_neg_integer()) :: :ok
  def age_step_check(scope, key, environment, ago_seconds) do
    StepRepository.upsert(scope, key, environment, %{
      verified_at: DateTime.add(DateTime.utc_now(), -ago_seconds, :second)
    })

    :ok
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
        execution_mode: Keyword.get(opts, :execution_mode, :working_copy),
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

    # Running is presence now: the copy's channel tracks a live agent, so the
    # row alone would read as off.
    AgentPresence.present(agent)
  end

  @doc "Track an already-created agent present, the way `running_agent/2` does."
  @spec mark_present(map()) :: map()
  def mark_present(agent), do: AgentPresence.present(agent)

  @doc """
  Untrack an agent's presence without ending its process: the lane leaves the
  harness channel, the thing actually running it does not.
  """
  @spec mark_absent(map()) :: :ok
  def mark_absent(agent), do: AgentPresence.absent(agent)

  @doc """
  Record the machine's own pid for an agent, the way a harness report does.

  `os_pid` arrives on this project from the machine actually running the
  agent, not from a decision made here — so a criterion whose premise is
  "the machine already reported a pid for it" sets it directly rather than
  standing up the full report round trip to produce the same row.
  """
  @spec record_os_pid(CodeMySpec.Agents.Agent.t(), integer()) :: CodeMySpec.Agents.Agent.t()
  def record_os_pid(%CodeMySpec.Agents.Agent{} = agent, pid) when is_integer(pid) do
    scope = %Scope{
      active_account_id: agent.account_id,
      active_project_id: agent.project_id
    }

    {:ok, updated} = AgentsRepository.update_agent(scope, agent, %{os_pid: pid})
    updated
  end

  defp tool_set(role) when is_binary(role),
    do: role |> String.to_existing_atom() |> tool_set()

  defp tool_set(role) when is_atom(role), do: ToolSets.for_role(role)

  @doc """
  Swap in `RecordingAgentTransport` for a scenario that restarts or messages
  a `running_agent/2` fixture.

  `running_agent/2` creates only the row, with no live harness process behind
  it, so the default `InProcessAgentTransport` refuses delivery to a machine
  that was never actually started -- this is the same swap
  `OperatorMessagesWaitForDeliveryTest` and its siblings use to exercise
  `message_agent`/`restart_agent` without one.
  """
  @spec use_recording_transport(term()) :: :ok
  def use_recording_transport(project), do: RecordingAgentTransport.listen(project)

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
    consume_recorded_dispatch(scope, agent_id)
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
        |> Enum.filter(&(&1.role == :operator and &1.delivery != :failed))
        |> Enum.map(&message_text/1)
    end
  end

  # A message's text, out of the parts it is stored as.
  #
  # `content` is a list of `%{"type" => ..., "text" => ...}` maps — an
  # orchestrator action carries its sentence plus optional count, tool and kind
  # parts. There is no flat `body`, and reading one raises `KeyError` at exactly
  # the moment the feature starts working, which reads as the feature failing.
  defp message_text({_status, text}) when is_binary(text), do: text

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

  def check_machine_prerequisites, do: CmsHarness.Setup.check_prerequisites()

  def check_platform_machine_prerequisites do
    CmsHarness.Setup.check_prerequisites(platform: CmsHarness.Setup.Platform.detect())
  end

  defdelegate machine_prerequisites_passed?(snapshot),
    to: CmsHarness.Setup,
    as: :prerequisites_passed?

  defdelegate machine_setup_status(), to: CmsHarness.Setup, as: :status

  defdelegate without_setup_postgres(context),
    to: CmsHarnessTest.SetupFixture,
    as: :without_postgres

  def configure_agent_models_for_email(email) do
    email
    |> CodeMySpec.Users.get_user_by_email()
    |> UserPreferences.scope_for()
    |> configure_agent_models()
  end

  def connect_setup_project(context) do
    CmsHarnessTest.FakeServer.start()

    CmsHarness.Setup.connect_project(
      context.project_dir,
      %{
        project_id: Ecto.UUID.generate(),
        working_copy_id: Ecto.UUID.generate(),
        app: "dev_setup_app"
      },
      []
    )
  end

  @doc "Complete model selection before account/project onboarding scenarios."
  def configure_agent_models(scope) do
    {:ok, _} = connect_provider(scope, "anthropic")
    {:ok, _} = CodeMySpec.Agents.put_model_setting(scope, :main, "anthropic", "claude-opus-5-5")
    :ok
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

  def stop_desktop_fixture_copies(directory) do
    prefix = Path.expand(directory) <> "/"

    roots =
      CmsHarness.Projects.list()
      |> Enum.filter(&String.starts_with?(Path.expand(&1), prefix))

    # Closing the client side's socket does not wait for the matching
    # server-side HarnessProjectChannel to notice and exit -- that happens on
    # its own, async, over the local websocket. A channel still mid a
    # reconcile when this test's Sandbox owner stops next outlives the
    # connection it was using (add46395, 9d81dfbd). Monitored here, while the
    # registry entry is still live, and waited out below.
    refs = Enum.map(desktop_channel_pids(prefix), &Process.monitor/1)

    Enum.each(roots, &CmsHarness.Projects.stop_serving/1)

    Enum.each(refs, &await_desktop_channel_down/1)
  end

  # `root` is reported to the registry, not an identity it resolves by (see
  # `HarnessRegistry.register_executor/3`'s own moduledoc) -- so this scans
  # every entry and filters on it directly, instead of first resolving a
  # working_copy_id for each root the way an ordinary caller would.
  defp desktop_channel_pids(prefix) do
    HarnessRegistry
    |> Registry.select([{{:"$1", :"$2", {:_, :"$3"}}, [{:is_binary, :"$1"}], [{{:"$2", :"$3"}}]}])
    |> Enum.filter(fn {_pid, root} ->
      is_binary(root) and String.starts_with?(Path.expand(root), prefix)
    end)
    |> Enum.map(fn {pid, _root} -> pid end)
  end

  defp await_desktop_channel_down(ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      5_000 ->
        raise "a desktop harness's server-side channel outlived the client copy that closed on it"
    end
  end

  def desktop_setup_main_agent(user) do
    account = CodeMySpec.AccountsFixtures.account_with_owner_fixture(user)
    account_scope = CodeMySpec.UsersFixtures.user_scope_fixture(user, account)
    {:ok, _} = UserPreferences.select_active_account(account_scope, account.id)
    project = CodeMySpec.ProjectsFixtures.project_fixture(account_scope, account_id: account.id)
    scope = CodeMySpec.UsersFixtures.user_scope_fixture(user, account, project)
    {:ok, _} = UserPreferences.select_active_project(scope, project.id)
    context = %{user: user, account: account, project: project, scope: scope}

    :ok = install_recording_agent_transport(context)
    :ok = designate_main(context.scope, context.scope.active_working_copy_id)
    agent = running_agent(context.scope, role: "main")
    Map.put(context, :setup_main_agent, agent)
  end

  def desktop_setup_connected_harness(scope) do
    previous = System.get_env("CMS_PROJECT_ID")
    System.delete_env("CMS_PROJECT_ID")
    ExUnit.Callbacks.on_exit(fn -> restore_desktop_project_id(previous) end)

    CmsHarnessTest.FakeServer.start()
    project = CmsHarnessTest.Projects.project_dir(project_id: scope.active_project_id)
    ExUnit.Callbacks.on_exit(fn -> CmsHarnessTest.Projects.stop_project(project.root) end)
    {:ok, _} = CmsHarness.Projects.ensure_started(project.root)
    %{connected: true} = CmsHarness.Setup.Connection.observe(project.root)
    project
  end

  defp restore_desktop_project_id(nil), do: System.delete_env("CMS_PROJECT_ID")
  defp restore_desktop_project_id(value), do: System.put_env("CMS_PROJECT_ID", value)

  def desktop_harness_credential(user) do
    {:ok, token} =
      ExOauth2Provider.AccessTokens.create_token(user, %{expires_in: 3600},
        otp_app: :code_my_spec
      )

    token.token
  end

  def generate_user_session_token(user), do: Users.generate_user_session_token(user)

  def select_active_account(scope, account_id),
    do: UserPreferences.select_active_account(scope, account_id)

  def select_active_project(scope, project_id),
    do: UserPreferences.select_active_project(scope, project_id)

  defdelegate google_integration_fixture(user, attrs \\ %{}), to: IntegrationsFixtures

  defdelegate find_or_register_oauth_user(provider, attrs), to: CodeMySpec.Integrations
  defdelegate find_or_register_oauth_user(provider, attrs, opts), to: CodeMySpec.Integrations

  defdelegate dispatch_analytics_event(event, payload), to: CodeMySpec.Analytics, as: :dispatch

  defdelegate mark_cli_first_connected(user), to: UsersFixtures

  # -- Execution contexts --
  defdelegate fixture_execution_context(scope), to: UsersFixtures
  defdelegate put_fixture_execution_context(scope, env), to: UsersFixtures

  defdelegate memory_execution_context_fixture(opts \\ []), to: ExecutionContextFixtures
  defdelegate local_execution_context_fixture(opts \\ []), to: ExecutionContextFixtures
  defdelegate register_environment(project_id, env), to: ExecutionContexts, as: :register
  defdelegate unregister_environment(project_id), to: ExecutionContexts, as: :unregister

  @doc "Write a file into an environment — a premise the checkout starts from."
  defdelegate write_file(env, path, contents), to: ExecutionContexts

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
  @doc "Where a component spec file used to live; for showing nothing writes one."
  def spec_file(module_path), do: ".code_my_spec/spec/#{module_path}.spec.md"

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
  def age_story(%Scope{} = scope, story_id, seconds) do
    at = DateTime.add(DateTime.utc_now(), -round(seconds), :second)
    naive = at |> DateTime.to_naive()

    from(s in CodeMySpec.Stories.Story, where: s.id == ^story_id)
    |> Repo.update_all(set: [inserted_at: naive, updated_at: naive])

    # And say so, because this is a write to a graph input.
    #
    # `Freshness.row_key/1` is `{id, updated_at}`, and this sets `updated_at` —
    # so backdating a story moves its fingerprint. Going through `update_all`
    # means `Stories` never hears about it, and a silent write now leaves the
    # graph stale rather than being repaired by whoever reads next.
    #
    # It looked like a flake: criterion 5901 passed alone and failed in a full
    # run, because whether the older story's work surfaced depended on some
    # *later* announcement happening to cover this one. A fixture that writes
    # what the graph is computed from announces like any other writer.
    GraphInputs.changed(scope, GraphInputs.observation_id())

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
    # the harness row via `LocalScope.for_local_project/2`, which resolves the
    # environment from the registry. Registered per project — as it was — every
    # harness on the project resolved to the *same* env, so this agent scanned
    # the other one's working copy, found its spec, and re-projected the very
    # component the reclaim had just deleted. Measured: reclaim reported
    # `components_deleted=1` and `ComponentSync` upserted it back in the same
    # request. Correct behaviour on a false premise, and it made every scenario
    # here read as though reclaiming did nothing.
    {:ok, env} = ExecutionContexts.create(:memory, working_dir: root)
    :ok = ExecutionContexts.register({:root, root}, env)

    %{scope | active_working_copy_id: harness.id, cwd: root}
  end

  @doc """
  The harness's side of the wire, for Story 987.

  Scans the working copy with the real `Scanner.observe/2` — the same function
  the harness runs, since both compile it from `lib/code_my_spec` — serialises
  the result the way the harness does, and pushes it through the **real
  channel handler**.

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

    # `:observe_in` scans a directory on this machine while the channel keeps
    # the harness-addressed scope: what a remote harness scans is its own
    # disk, and what the server reads back goes over the wire.
    observed_env =
      case Keyword.get(opts, :observe_in) do
        nil -> UsersFixtures.fixture_execution_context(scope)
        dir -> CodeMySpec.ExecutionContexts.ExecutionContext.new(:local, dir)
      end

    {:ok, entries} = Scanner.observe(observed_env, read_model)
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

  @doc "A publication stamp delivered by the server, for downstream graph-cache scenarios."
  def record_story_publication(scope, story_id, version, opts \\ []) do
    story = CodeMySpec.Stories.get_story(scope, story_id)
    CodeMySpec.Stories.mark_story_promoted(scope, story, version, opts)
  end

  @doc """
  Record what a checkout's application is doing, the way its harness would.

  `CmsHarness.Sync` measures this against the checkout's `preview_url` on the
  machine that can reach it; a spec has no harness, so it records through the
  same surface the channel handler calls.

  Replaces `record_git_state/2`, which recorded the checkout's `ahead`/`behind`/
  `dirty` counts. Those columns are gone — they were a mirror of git that
  nothing decided on, and hashing them into every story's fingerprint made one
  keystroke reconsider every story in the project.

  `preview_status` is the surviving input of that shape and the one the graph
  genuinely reads: `Promotion.serving/2` turns on it, and `preview_checked_at`
  beside it is a heartbeat the fingerprint must ignore. So the criteria on story
  1063 that used git state to tell "a value that matters" from "a timestamp that
  does not" ask the same question here, of an input that still exists.
  """
  @spec record_preview_status(Ecto.UUID.t(), String.t()) :: :ok
  def record_preview_status(working_copy_id, status) do
    {:ok, copy} = CodeMySpec.WorkingCopies.fetch(working_copy_id)
    {:ok, _} = CodeMySpec.WorkingCopies.record_preview_status(copy, status)
    :ok
  end

  @doc """
  The project with no checkout anywhere: every working copy loses its root, so
  none is a candidate host. The fixture scope's own copy is rooted, which is a
  harness running somewhere as far as placing a new copy is concerned.
  """
  @spec without_checkouts(Scope.t()) :: :ok
  def without_checkouts(%Scope{active_project_id: project_id}) do
    {_, _} =
      Repo.update_all(
        from(w in WorkingCopy, where: w.project_id == ^project_id),
        set: [root: nil]
      )

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
    {:ok, _} = CodeMySpec.Staffing.designate_main(scope, working_copy_id)

    {:ok, _} =
      CodeMySpec.Projects.update_project(scope, scope.active_project, %{
        default_working_copy_id: working_copy_id
      })

    :ok
  end

  @doc """
  A machine that already runs a tunnel before the scenario starts — this Mac's
  dev tunnel, today (story 1117). The device is announced the way its harness
  would, then its tunnel recorded. State that predates the scenario, which is
  what makes it a fixture rather than a step.
  """
  @spec record_machine_tunnel(Scope.t(), Ecto.UUID.t(), map()) :: :ok
  def record_machine_tunnel(
        %Scope{} = scope,
        device_id,
        %{tunnel_id: _, tunnel_secret: _} = tunnel
      ) do
    {:ok, _device} =
      CodeMySpec.Devices.announce(scope, device_id, %{kind: :local, hostname: "johns-mac"})

    {:ok, _device} = CodeMySpec.Devices.record_tunnel(device_id, tunnel)
    :ok
  end

  @doc """
  A main copy still holding the per-project tunnel it was given before story
  1117: the old model, recorded on the copy itself.
  """
  @spec record_project_tunnel(Scope.t(), Ecto.UUID.t(), map()) :: :ok
  def record_project_tunnel(%Scope{} = scope, working_copy_id, %{
        tunnel_id: id,
        tunnel_secret: secret
      }) do
    {:ok, copy} = WorkingCopies.fetch(working_copy_id)

    {:ok, instance} = CodeMySpec.AppInstances.ensure_default(scope, copy)

    {:ok, _instance} =
      CodeMySpec.AppInstances.record_preview_tunnel(scope, instance, %{
        preview_url: PreviewAddress.url(instance.id),
        preview_tunnel_id: id,
        preview_tunnel_secret: secret
      })

    :ok
  end

  @doc """
  Start watching this project's graph, and subscribe to its announcements.

  Here rather than in a criterion for the same reason as `record_preview_status/2`:
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

    # Each project belongs to this test's teardown, including secondary projects.
    # A named callback also handles repeated starts without accumulating callbacks.
    ExUnit.Callbacks.on_exit({:stop_graph_watcher, project_id}, fn -> stop_watching(scope) end)

    # `GraphInputs.subscribe/1` is a plain `Phoenix.PubSub.subscribe/2`, which is
    # not idempotent per process: a second subscription from the same pid to the
    # same topic is a second registry entry, and `Phoenix.PubSub.broadcast/3`
    # dispatches once per entry — so calling this twice from one test process
    # delivers every later `{:graph_updated, project_id}` twice, silently, to a
    # mailbox that already looks correct to every scenario that doesn't count
    # broadcasts directly. `setup_active_project` already calls this once for
    # every spex; a `given_` that calls it again (3189, 3194) was doubling every
    # announcement from that point on. Measured: both criteria failed at exactly
    # 2 announcements for one change, every run — not a race, a fixed doubling.
    key = {__MODULE__, :graph_inputs_subscribed, project_id}

    unless Process.get(key) do
      :ok = GraphInputs.subscribe(project_id)
      Process.put(key, true)
    end

    # The watcher computes on arrival and announces it, so subscribing leaves a
    # `{:graph_updated, _}` in the caller's mailbox for a scenario that has not
    # touched anything. Settle the bootstrap pass and drain what it said.
    #
    # Looped rather than a single settle-and-drain. A `given_` chain doing real
    # writes across real wall-clock time can leave the watcher mid-backlog: a
    # `graph_inputs_changed` message that arrives *while* a settle-triggered
    # recompute is running queues behind it rather than folding into it, and
    # schedules its own debounce timer for after this call has already
    # returned. One settle-and-drain only clears whatever was pending at the
    # instant it ran — not a backlog still working through several such
    # cycles on the watcher's own clock.
    #
    # Measured on 3189: a `given_` chain doing real writes across ~1.5s against a
    # 25ms test debounce and a 20-60ms recompute produced four to six separate
    # recompute cycles, each with its own real observations, arriving in bursts
    # over several hundred milliseconds. A single settle-and-drain — even one
    # that loops its own `receive` down to empty — only ever caught whichever
    # cycles had already finished by the time it ran, and left the rest to leak
    # into whatever the `when_` counted next.
    #
    # So this settles, drains, and checks the watcher's own word for whether
    # anything is still pending (`status/1`'s `pending: timer != nil`) — which
    # is true exactly when a burst arrived behind the settle call and is
    # already scheduled to recompute again. Repeating until the watcher itself
    # says there is nothing left to catch up on is what makes "the mailbox is
    # clean before a `when_` starts counting" true regardless of how many
    # cycles setup took to produce it.
    #
    # No cap, deliberately. A setup chain leaving more stray messages than
    # expected should show up as a slower test, not vanish behind a bounded drain.
    drain_until_settled(project_id)
  end

  defp drain_until_settled(project_id, attempts \\ 50)

  # Loudly, not forever. A watcher whose pass keeps failing keeps its timer
  # set, so `pending` stays true and this spun until ExUnit's timeout — sixty
  # seconds of a settle retried five hundred times a second, with the watcher's
  # own reason in `last_error` the whole time. Measured at 31,058 log lines in
  # one run, behind a sandbox connection that a process killed mid-query had
  # taken down.
  defp drain_until_settled(project_id, 0) do
    raise "the graph for #{project_id} would not settle; the watcher says: " <>
            inspect(
              GraphWatcher.status(project_id) && GraphWatcher.status(project_id)[:last_error]
            )
  end

  defp drain_until_settled(project_id, attempts) do
    GraphWatcher.settle(project_id)
    drain_bootstrap_announcements(project_id)

    case GraphWatcher.status(project_id) do
      %{pending: true} -> drain_until_settled(project_id, attempts - 1)
      _ -> :ok
    end
  end

  defp drain_bootstrap_announcements(project_id) do
    receive do
      {:graph_updated, ^project_id} -> drain_bootstrap_announcements(project_id)
    after
      0 -> :ok
    end
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
  Publish what a fixture wrote, so the graph can see it.

  The bridge, because `CodeMySpecSpex` does not depend on `CodeMySpec.Files` and
  should not start: this module is the one approved crossing.

  Fixtures used to get this for free. `GetNextRequirement` opened with a full
  `FileSync.sync/2` on its way to the graph, so anything written before an agent
  asked was published by the asking — which made a read responsible for a
  write's visibility and left admission and the agent reading two different
  graphs (c83c5b58). The sync is gone from there, so a fixture that writes a
  file publishes it itself.
  """
  @spec sync_files(Scope.t()) :: :ok
  def sync_files(%Scope{} = scope) do
    {:ok, _} = FileSync.sync(scope, base_dir: scope.cwd)
    {:ok, _} = ComponentSync.sync_from_files(scope, base_dir: scope.cwd)
    :ok
  end

  @doc """
  Sync only what changed since the last sync -- the path a rewrite actually
  goes through (`FileSync.sync_changed/2`), which is what clears a
  criterion's own latch when its spex is rewritten. `sync_files/1`'s full
  `FileSync.sync/2` does not carry that: it is the bulk reconciliation pass,
  not the incremental one the watcher and the stop hook use.
  """
  @spec sync_changed(Scope.t()) :: :ok
  def sync_changed(%Scope{} = scope) do
    {:ok, _} = FileSync.sync_changed(scope, base_dir: scope.cwd)
    :ok
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
  Which of one entity's requirements the graph currently reads as unsatisfied.

  Pairs with `actionable_names/2` to tell two shapes of race apart on a red
  run: something here means the fixture chain that was meant to satisfy this
  entity's requirements is genuinely incomplete; nothing here while the role's
  actionable set is still empty means the chain finished and the published
  graph has not caught up with it.

  Settles first, same as `actionable_for_role/2` does internally — a pending
  recompute means a write has landed that this has not seen, and "unsatisfied"
  is exactly the answer that write would change.
  """
  @spec unsatisfied_names(Scope.t(), term()) :: [String.t()]
  def unsatisfied_names(%Scope{} = scope, entity_id) do
    scope |> unsatisfied_for(entity_id) |> Enum.map(& &1.name)
  end

  @doc """
  Same as `unsatisfied_names/2`, but `{name, reason}` pairs.

  A name alone says a requirement is not satisfied; it does not say why, and
  `RequirementCalculator`'s delegate checks already compute a `reason` for
  exactly this purpose — carried on the node as `details`. Reading it back
  here is cheaper than a second theory.
  """
  @spec unsatisfied_reasons(Scope.t(), term()) :: [{String.t(), term()}]
  def unsatisfied_reasons(%Scope{} = scope, entity_id) do
    scope
    |> unsatisfied_for(entity_id)
    |> Enum.map(&{&1.name, reason_of(&1)})
  end

  # String keys, because that is the canonical shape and there is already a
  # function that says so. `Requirement.normalize_details/1` exists precisely
  # for this: `details` is written to a `jsonb` column, which has no atoms, so a
  # freshly computed requirement can carry atom keys where a stored one never
  # does. Normalising once is the difference between reading one shape and
  # guessing between two.
  defp reason_of(node) do
    node.details
    |> Requirement.normalize_details()
    |> Map.get("reason")
  end

  defp unsatisfied_for(%Scope{} = scope, entity_id) do
    :ok = GraphWatcher.settle(scope)

    scope
    |> Requirements.cached_graph_with_actionable()
    |> Map.fetch!(:nodes)
    |> Enum.filter(&(&1.entity_id == entity_id and not &1.satisfied))
  end

  @doc """
  Forget everything the event path has projected for this project, at every
  vantage, so the next projector to arrive meets it for the first time.

  A projector arriving trusts rows it finds and seeds only a vantage that has
  none, so a criterion about the seed has to take the rows away first — a
  restart alone measures a trust. Oracle tooling, like `watch_graph/1`.
  """
  @spec forget_projection(Scope.t()) :: :ok
  def forget_projection(%Scope{} = scope) do
    scope
    |> Projection.vantages()
    |> Enum.each(&GraphStore.clear(%{scope | active_working_copy_id: &1}))
  end

  @doc """
  Stop every project's graph projector, so nothing new starts during teardown.

  A projector outlives the scenario that started it and drains the moment a
  mark lands, so it can start work into a sandbox that is about to go away.

  Every one rather than this scope's, because teardown runs before the scope is
  in hand — which is only right when nothing runs beside the caller. From an
  async test this stops every concurrent test's projector; use
  `stop_watching/1` there.
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

  @doc """
  Stop watching this project, so the watcher does not outlive the test.

  A watcher is a process and the sandbox transaction is not. Left running, it
  takes its next pass after the test that started it has gone, finds the
  connection it was using checked back in, and logs at `:error` —
  `SexySpex.ErrorCapture` then fails whichever spex happens to be running when
  that lands. Observed on criterion 3339, failed by a straggler from an earlier
  scenario: "could not checkout the connection owned by #PID<...>".

  `GraphWatcher` already handles the *project* disappearing underneath it
  (`:gone`, stop, no noise). It cannot handle the connection disappearing,
  because that is indistinguishable from a real database fault — which is
  exactly what a reader needs it to shout about.
  """
  @spec stop_watching(Scope.t()) :: :ok
  def stop_watching(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    case Registry.lookup(CodeMySpec.Requirements.Registry, {project_id, :graph}) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(CodeMySpec.Requirements.WatcherSupervisor, pid)
        :ok

      [] ->
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  def stop_watching(%Scope{}), do: :ok

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
  @doc "The open (not completed, not cancelled) task an agent holds, or nil."
  def open_task_for_agent(scope, agent_id) do
    with {:ok, agent} <- CodeMySpec.Agents.fetch_agent(scope, agent_id) do
      Enum.find(agent.tasks || [], &(&1.status not in [:completed, :cancelled]))
    else
      _ -> nil
    end
  end

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

  For premises about a run that did not finish well. A stop never re-runs it
  (John, 2026-10-04); only an explicit request does.
  """
  def failed_analysis_run(%Scope{} = scope, source) do
    CodeMySpec.AnalysisFixtures.analysis_run_fixture(scope, %{
      source: source,
      status_override: :failed
    })
  end

  @doc "Durable messages still waiting for an agent to consume them."
  def queued_agent_messages(scope, agent_id) do
    scope |> AgentMailbox.entries(agent_id) |> Enum.filter(&(&1.state in [:queued, :claimed]))
  end

  # Recording transports stop at the wire. These fixtures explicitly model the
  # engine's consumption handshake before reporting that a turn began or ended.
  defp consume_recorded_dispatch(scope, agent_id, ref \\ nil) do
    entry =
      Enum.find(AgentMailbox.entries(scope, agent_id), fn entry ->
        entry.state == :claimed and (is_nil(ref) or entry.delivery_ref == ref)
      end)

    consume_recorded_entry(scope, agent_id, entry)
  end

  defp consume_recorded_entry(_scope, _agent_id, nil), do: :ok

  defp consume_recorded_entry(scope, agent_id, entry) do
    {:ok, agent} = AgentsRepository.fetch_agent(scope, agent_id)
    generation = agent.mailbox_generation || "fixture-engine"
    {:ok, :ok} = AgentMailbox.register(scope, agent_id, generation)
    {:ok, _entry} = AgentMailbox.consume(scope, agent_id, entry.delivery_ref, generation)
    :ok
  end

  @doc "Terminal evidence for the fixture engine’s current consumed message."
  def mailbox_turn_end(scope, agent_id) do
    scope
    |> AgentMailbox.entries(agent_id)
    |> Enum.find(&(&1.state == :consumed))
    |> mailbox_terminal_event(scope, agent_id)
  end

  defp mailbox_terminal_event(nil, scope, agent_id) do
    {:ok, agent} = AgentsRepository.fetch_agent(scope, agent_id)
    generation = agent.mailbox_generation || "fixture-engine"
    {:ok, :ok} = AgentMailbox.register(scope, agent_id, generation)
    %{event: :turn_ended, ref: "work-#{Ecto.UUID.generate()}", generation: generation}
  end

  defp mailbox_terminal_event(entry, _scope, _agent_id),
    do: %{event: :turn_ended, ref: entry.delivery_ref, generation: entry.generation}

  @doc "Deliver a queued message and begin its turn through the harness channel."
  def deliver_agent_message(%Scope{} = scope, agent_id, ref) do
    consume_recorded_dispatch(scope, agent_id, ref)
    socket = %Phoenix.Socket{assigns: %{scope: scope}}

    Enum.each([Map.put(mailbox_turn_end(scope, agent_id), :event, :turn_started)], fn event ->
      case CodeMySpecWeb.HarnessProjectChannel.handle_in(
             "agent_turn_event",
             %{
               "agent_id" => agent_id,
               "event" => ChannelClient.encode_turn_event(event)
             },
             socket
           ) do
        {:noreply, _socket} -> :ok
        {:reply, _reply, _socket} -> :ok
      end
    end)
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
             "event" => ChannelClient.encode_turn_event(mailbox_turn_end(scope, agent_id))
           },
           socket
         ) do
      {:noreply, _socket} -> :ok
      {:reply, _reply, _socket} -> :ok
    end
  end

  # Recorded outputs (`:compile_output_file` and friends) are landed as a
  # completed analysis run first (`land_outputs/2`); a turn end never starts
  # or ingests one. Whatever opts remain go straight through
  # `Agents.record_turn_event/4`, since the channel payload has nowhere to
  # carry them; with none left, the turn ends over the socket like a real one.
  def end_turn(%Scope{} = scope, agent_id, opts) do
    case land_outputs(scope, opts) do
      [] ->
        end_turn(scope, agent_id, [])

      rest ->
        :ok =
          CodeMySpec.Agents.record_turn_event(
            scope,
            agent_id,
            ChannelClient.encode_turn_event(mailbox_turn_end(scope, agent_id)),
            rest
          )
    end
  end

  @doc """
  An agent's turn failing, as it arrives on the channel.

  Same reasoning as `end_turn/3`: the proxy that reports a failed turn lives
  in `cms_harness`, so a spec drives the channel's own `agent_turn_event`
  entry on a `turn_failed` kind rather than a second version of it. `text`
  is read by `Agents.record_turn_event/4` through `ProviderRefusal.read/2`
  and `TurnTimeout.exec/1` to classify the failure's cause.
  """
  @spec fail_turn(Scope.t(), String.t(), String.t()) :: :ok
  def fail_turn(%Scope{} = scope, agent_id, text) do
    socket = %Phoenix.Socket{assigns: %{scope: scope}}

    event = ChannelClient.encode_turn_event(%{event: :turn_failed, text: text})

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

  Options are `%{"label" => …}` maps because that is the shape `AskQuestion`
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
        "session_external_id" => Keyword.get(opts, :session_external_id),
        "agent_id" => Keyword.get(opts, :agent_id)
      })

    request.id
  end

  @doc """
  Make question inserts for this test user write no row.

  PostgreSQL's BEFORE INSERT cancellation exercises an actual failed write
  without aborting the surrounding sandbox transaction. In particular, this
  fixture does not wrap the tool call in a rollback that would hide a task
  mutation made before the insert. The trigger and temporary function are
  transactional DDL and disappear with the test sandbox's rollback.
  """
  @spec refuse_question_inserts(Scope.t()) :: :ok
  def refuse_question_inserts(%Scope{user: %{id: user_id}}) when is_integer(user_id) do
    CodeMySpec.Repo.query!("""
    CREATE FUNCTION pg_temp.spex_refuse_question_insert() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.user_id = #{user_id} THEN
        RETURN NULL;
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    CodeMySpec.Repo.query!("""
    CREATE TRIGGER spex_refuse_question_insert
    BEFORE INSERT ON question_requests
    FOR EACH ROW EXECUTE FUNCTION pg_temp.spex_refuse_question_insert()
    """)

    :ok
  end

  @doc """
  Refuse this test user's tap-out inserts without aborting the sandbox transaction.
  This injects storage failure, not task state or a permission outcome.
  """
  @spec refuse_tap_out_inserts(Scope.t()) :: :ok
  def refuse_tap_out_inserts(%Scope{user: %{id: user_id}}) when is_integer(user_id) do
    CodeMySpec.Repo.query!("""
    CREATE FUNCTION pg_temp.spex_refuse_tap_out_insert() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.user_id = #{user_id} AND NEW.tool_name = 'tap_out' THEN
        RETURN NULL;
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    CodeMySpec.Repo.query!("""
    CREATE TRIGGER spex_refuse_tap_out_insert
    BEFORE INSERT ON permission_requests
    FOR EACH ROW EXECUTE FUNCTION pg_temp.spex_refuse_tap_out_insert()
    """)

    :ok
  end

  @doc """
  Establish the age of a question already created through its public surface.

  Changes only its timestamps, never its answer, status, ownership, or task
  blocker. This supplies historical setup without sleeping through a real TTL.
  """
  @spec age_question(Scope.t(), String.t(), pos_integer()) :: :ok
  def age_question(%Scope{user: %{id: user_id}}, question_id, seconds)
      when is_integer(seconds) and seconds > 0 do
    timestamp =
      DateTime.utc_now() |> DateTime.add(-seconds, :second)

    {1, _} =
      from(q in Notifications.QuestionRequest,
        where: q.id == ^question_id and q.user_id == ^user_id
      )
      |> CodeMySpec.Repo.update_all(set: [inserted_at: timestamp, updated_at: timestamp])

    :ok
  end

  @doc """
  Establish the age of a permission request already created through its
  public surface (`tap_out`, or a tool permission).

  Mirrors `age_question/3`. Changes only timestamps, never status or decision.
  """
  @spec age_permission(Scope.t(), String.t(), pos_integer()) :: :ok
  def age_permission(%Scope{user: %{id: user_id}}, permission_id, seconds)
      when is_integer(seconds) and seconds > 0 do
    timestamp =
      DateTime.utc_now() |> DateTime.add(-seconds, :second)

    {1, _} =
      from(p in Notifications.PermissionRequest,
        where: p.id == ^permission_id and p.user_id == ^user_id
      )
      |> CodeMySpec.Repo.update_all(set: [inserted_at: timestamp, updated_at: timestamp])

    :ok
  end

  @doc """
  Bind an already-created agent to a story and/or epic, as the agent row
  records it.

  Setup only: a scenario about an agent's own story or epic needs the row to
  carry one without re-deriving the whole `start_agent` path.
  """
  @spec bind_agent(Scope.t(), map(), map()) :: map()
  def bind_agent(%Scope{} = scope, agent, attrs) do
    {:ok, agent} = AgentsRepository.update_agent(scope, agent, attrs)
    agent
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
        "tool_input" => Keyword.get(opts, :tool_input, %{"command" => "mix test"}),
        "agent_id" => Keyword.get(opts, :agent_id)
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
    do: AcceptanceCriteria.list_story_criteria(scope, story.id)

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
  Replace a component's problems for one source, the way a reconciler does.

  Added deliberately rather than reached for: `record_problem/3` appends, so the
  only swap it can express changes the count — and a count changing is exactly
  what criteria 3472 and 3473 must NOT rely on. They are about a finding being
  swapped for a different one *at equal count*, which is the case a fingerprint
  keyed on `%{source => count}` cannot see, so arranging it needs the
  delete-then-insert path the analyzer itself uses.

  `Problems.replace_problems_for_components/4` is that path, and it announces,
  so a spex driving it exercises the same sequence a finished analyzer run does.
  """
  @spec replace_problems(Scope.t(), Ecto.UUID.t(), String.t(), [map()]) :: :ok
  def replace_problems(%Scope{} = scope, component_id, source, problems) do
    {:ok, _} =
      CodeMySpec.Problems.replace_problems_for_components(
        scope,
        [component_id],
        source,
        Enum.map(problems, fn attrs ->
          Map.merge(
            %{
              source: source,
              severity: :error,
              category: "readability",
              component_id: component_id,
              project_id: scope.active_project_id
            },
            attrs
          )
        end)
      )

    :ok
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
  The question id out of what `AskQuestion` answered.

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
  Which agent raised a question, if an agent did.

  The identity `Plugs.AgentScope` puts on the frame in production, read back
  off the question it wrote. `check_answer` refuses a question whose `agent_id`
  is not the caller's — correctly, one agent must not read another's reply — so
  a spex collecting an answer has to call as the asker, and this is where the
  asker is recorded. Nil for a Claude Code session's question, which has no
  agent.
  """
  @spec asking_agent_id(String.t()) :: String.t() | nil
  def asking_agent_id(question_id) do
    case CodeMySpec.Notifications.get_question_request(question_id) do
      %{agent_id: agent_id} -> agent_id
      nil -> nil
    end
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

  @output_file_sources [
    compile_output_file: "compiler",
    credo_output_file: "credo",
    exunit_output_file: "exunit",
    spex_output_file: "spex"
  ]

  @doc """
  Recorded analyzer outputs, landed as completed analysis runs — what
  `start_analysis` would have produced — before anything stops.

  Takes the opts a stop or turn end was given and returns them without the
  output files and `:await` (which waits for the runs to land), neither of
  which a stop accepts.
  """
  def land_outputs(%Scope{} = scope, opts) do
    {files, rest} = Keyword.split(opts, Keyword.keys(@output_file_sources))

    case for({opt, source} <- @output_file_sources, Keyword.has_key?(files, opt), do: source) do
      [] ->
        :ok

      sources ->
        CodeMySpec.Analysis.ensure_stale_runs(scope, sources, files)
        # Waited for only when asked, as `validate_stop/3` used to: a scope
        # that routes runs to a harness the spec never started would wait
        # forever.
        if Keyword.get(rest, :await, false), do: CodeMySpec.Analysis.await_all(scope)
    end

    Keyword.delete(rest, :await)
  end

  @doc "Files the harness scanned but could classify into no role."
  def unclassified_files(%Scope{} = scope),
    do: Scanner.unclassified(UsersFixtures.fixture_execution_context(scope))

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

  @doc """
  Embed the way the server does: the pgvector store, the `EmbedPool` the app
  runs, and `knowledge_dir` as the release's knowledge folder. A recording
  serving stands in for Ortex and sends `{:embedded, texts, priority}` to the
  calling process for every batch.

  A server's store and the boot that fills it have no surface a spex can
  drive, so this and `server_starts/0` are the seam (577de9bb step 4).
  """
  @spec embed_on_pgvector(String.t()) :: :ok
  def embed_on_pgvector(knowledge_dir) do
    keys = [:embeddings_backend, :embedding_serving, :framework_knowledge_dir]
    previous = Map.new(keys, &{&1, Application.get_env(:code_my_spec, &1)})

    Application.put_env(:code_my_spec, :embeddings_backend, CodeMySpec.Embeddings.PgVectorBackend)

    Application.put_env(
      :code_my_spec,
      :embedding_serving,
      CodeMySpecTest.RecordingEmbeddingServing
    )

    Application.put_env(:code_my_spec, :framework_knowledge_dir, knowledge_dir)
    CodeMySpecTest.RecordingEmbeddingServing.listen(self())

    start_embed_pool(Process.whereis(CodeMySpec.EmbedPool))

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:code_my_spec, key)
        {key, value} -> Application.put_env(:code_my_spec, key, value)
      end)

      CodeMySpecTest.RecordingEmbeddingServing.reset()
    end)

    :ok
  end

  # Once per test: a second scenario in the same test reuses it.
  defp start_embed_pool(nil) do
    ExUnit.Callbacks.start_supervised!(
      {FLAME.Pool, name: CodeMySpec.EmbedPool, min: 0, max: 1, backend: FLAME.LocalBackend}
    )
  end

  defp start_embed_pool(_running), do: :ok

  @doc """
  Like `embed_on_pgvector/1`, but through the real `OrtexServing` priority
  queue instead of the synchronous recording fake. Criterion 1770 needs an
  actual search-preempts-bulk guarantee to exercise, and nothing proves
  that when every embed call just returns inline on whatever process
  happens to call it.

  Every job — search or bulk — blocks until told `:go`, reporting
  `{:worker_blocked, pid, kind, texts}` once held. Holding every job, not
  just the first, is what lets a scenario confirm *which* job the queue
  dispatches next one at a time, deterministically — everything here is
  otherwise instant, so once released, a real race to completion would
  reach the test process before it could tell the correct order from the
  wrong one.
  """
  @spec embed_on_pgvector_queued(String.t()) :: :ok
  def embed_on_pgvector_queued(knowledge_dir) do
    keys = [:embeddings_backend, :embedding_serving, :framework_knowledge_dir]
    previous = Map.new(keys, &{&1, Application.get_env(:code_my_spec, &1)})

    Application.put_env(:code_my_spec, :embeddings_backend, CodeMySpec.Embeddings.PgVectorBackend)
    Application.put_env(:code_my_spec, :embedding_serving, CodeMySpec.Embeddings.OrtexServing)
    Application.put_env(:code_my_spec, :framework_knowledge_dir, knowledge_dir)

    start_embed_pool(Process.whereis(CodeMySpec.EmbedPool))

    test_pid = self()
    vector = List.duplicate(0.1, 384)

    run_fn = fn
      _pipeline, {:single, text} ->
        send(test_pid, {:worker_blocked, self(), :search, [text]})

        receive do
          :go -> :ok
        end

        {:ok, vector}

      _pipeline, {:batch, texts} ->
        send(test_pid, {:worker_blocked, self(), :bulk, texts})

        receive do
          :go -> :ok
        end

        {:ok, Enum.map(texts, fn _ -> vector end)}
    end

    ExUnit.Callbacks.start_supervised!({CodeMySpec.Embeddings.OrtexServing, run_fn: run_fn})

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:code_my_spec, key)
        {key, value} -> Application.put_env(:code_my_spec, key, value)
      end)
    end)

    :ok
  end

  @doc """
  A hex package tarball holding `sources` (path => Elixir source), and the
  outer checksum a `mix.lock` entry for it carries. For `Req.Test.stub` on
  `CodeMySpec.Embeddings.HexPackageFetch`: hex.pm is the provider here.
  """
  @spec hex_tarball(map()) :: {binary(), String.t()}
  def hex_tarball(sources) do
    tarball = CodeMySpecTest.HexTarballFixtures.build(sources)
    {tarball, CodeMySpecTest.HexTarballFixtures.checksum(tarball)}
  end

  @doc "The 2-minute hex docs sweep, run now: the timer has no surface."
  @spec hex_doc_sweep_runs() :: :ok
  def hex_doc_sweep_runs, do: HexDocSweep.sweep_now()

  @doc "The 15-minute lockfile and project-knowledge sweep, run now."
  @spec lockfile_sweep_runs() :: :ok
  def lockfile_sweep_runs, do: LockfileSweep.sweep_now()

  @doc "Make every embedding batch fail (`true`) or succeed again (`false`)."
  @spec fail_embedding(boolean()) :: :ok
  def fail_embedding(fail?) do
    CodeMySpecTest.RecordingEmbeddingServing.fail(fail?)
    :ok
  end

  @doc "Embed with a different model from now on, as a model upgrade would."
  @spec switch_embedding_model(String.t()) :: :ok
  def switch_embedding_model(name) do
    CodeMySpecTest.RecordingEmbeddingServing.model(name)
    :ok
  end

  @doc """
  Route embedding calls through the recorder for this test, undone
  automatically on exit — the seam for a criterion that needs its own
  pool/backend configured around it (unlike `embed_on_pgvector/1`, this
  leaves `:embeddings_backend` alone).
  """
  @spec embedding_serving_is_recorded() :: :ok
  def embedding_serving_is_recorded do
    previous = Application.get_env(:code_my_spec, :embedding_serving)

    Application.put_env(
      :code_my_spec,
      :embedding_serving,
      CodeMySpecTest.RecordingEmbeddingServing
    )

    CodeMySpecTest.RecordingEmbeddingServing.listen(self())

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:code_my_spec, :embedding_serving)
        value -> Application.put_env(:code_my_spec, :embedding_serving, value)
      end

      CodeMySpecTest.RecordingEmbeddingServing.reset()
    end)

    :ok
  end

  @doc "Block the recorder's next batch (`true`) until released, or stop blocking (`false`)."
  @spec pause_embedding_until_released(boolean()) :: :ok
  def pause_embedding_until_released(pause?) do
    CodeMySpecTest.RecordingEmbeddingServing.pause_until_released(pause?)
  end

  @doc "Release a batch the recorder paused, naming the runner process it paused in."
  @spec release_embedding(pid()) :: :ok
  def release_embedding(pid) do
    CodeMySpecTest.RecordingEmbeddingServing.release(pid)
  end

  @doc """
  The server starting, as far as framework knowledge goes: the boot child
  the application lists, run to completion. Answers once it has exited.
  """
  @spec server_starts() :: :ok
  def server_starts do
    child =
      Supervisor.child_spec(CodeMySpec.Embeddings.FrameworkKnowledgeReconciler,
        id: make_ref()
      )

    pid = ExUnit.Callbacks.start_supervised!(child)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      30_000 -> raise "the framework knowledge boot child did not finish"
    end
  end

  defdelegate write_framework_knowledge_file(dir, filename, content), to: EmbeddingsFixtures

  # -- Continuous mode (Story 538) --
  @doc """
  Drive the real `POST /api/skills/start` endpoint with skill=implement
  so the agent's autonomous loop is enabled on the named session.

  Production surface: `cms implement` (CLI) → harness → `CmsHarness.Web.
  SkillsController` → `HarnessProjectChannel` → `SkillRouter.resolve/2`
  (skill: "implement") → `StartAgentTask.run("start_implementation")` →
  `StartImplementation.init_session` sets `session.continuous = true`.
  LocalWeb's `POST /api/skills/start` is gone with the retired CLI (issue
  f532f990); calling `resolve/2` directly skips the transport layers same
  as `start_agent_task/2` does for the direct-dispatch route.

  Returns `:ok`. The session's `external_id` is whatever the caller passed
  in; calling this AFTER a regular `start_task` for that session flips the
  continuous flag on the existing row.
  """
  @spec start_continuous_mode(map(), String.t()) :: :ok
  def start_continuous_mode(scope, external_id) when is_binary(external_id) do
    case AgentTasks.SkillRouter.resolve(scope, %{
           "skill" => "implement",
           "external_id" => external_id
         }) do
      {:ok, %{prompt: _}} -> :ok
      other -> raise "start_continuous_mode failed: #{inspect(other)}"
    end
  end

  # -- Agents on this machine --
  #
  # Story 1038's criteria are about what a *running* agent carries and what a
  # script it runs can reach, so they start one. Through the bridge because
  # `CodeMySpecSpex` is its own Boundary and cannot name `CmsHarness` directly.
  def launch_agent(request) do
    callbacks = mailbox_callbacks(request["agent_id"])

    request
    |> Map.put_new(
      "direct_tools",
      ToolIndex.carried_definitions(ToolRegistry.registry())
    )
    |> Map.put("on_register", callbacks[:on_register])
    |> Map.put("on_consume", callbacks[:on_consume])
    |> CmsHarness.Agents.launch()
  end

  def mailbox_callbacks(agent_id) do
    agent = Repo.get!(CodeMySpec.Agents.Agent, agent_id)

    scope = %Scope{
      active_account_id: agent.account_id,
      active_project_id: agent.project_id,
      active_working_copy_id: agent.working_copy_id
    }

    [
      on_register: fn id, generation ->
        CodeMySpec.Agents.Mailbox.register(scope, id, generation)
      end,
      on_consume: fn id, ref, generation ->
        CodeMySpec.Agents.Mailbox.consume(scope, id, ref, generation)
      end
    ]
  end

  def dispatch_agent_mail(_copy, agent, ref, text, timeout),
    do: CmsHarness.Agents.send_message(agent.id, ref, text, timeout)

  defdelegate halt_agent(agent_id), to: CmsHarness.Agents, as: :halt

  @doc "What one agent is doing right now — mid-turn, and how much is behind it."
  defdelegate agent_status(agent_id), to: CmsHarness.Agents, as: :status

  @doc """
  Give an agent something to do without waiting for the turn.

  Admission returns while the message waits in the database mailbox. The
  scenario can observe delivery while the agent remains busy.
  """
  def send_agent_message(agent_id, text) do
    CodeMySpec.Agents.send_to_agent(agent_id, text, :operator_message)
  end

  @doc """
  Tell an agent something and wait for the turn it takes about it.

  The waiting half of the pair above, and the one a *measured* run needs.
  `send_to_agent/4` answers `:queued` when the message is accepted, and an
  agent that has not dequeued it yet reads as idle — so a helper that sent and
  then waited for idle could return before the turn began, with an empty
  transcript, and count that as the agent having done nothing.

  Measured 2026-09-17 on story 1070's criterion 3543: three runs, three
  agents told something, three "called nothing at all", the whole measurement
  in 28 seconds. The messages were delivered; nothing waited for what they
  caused.
  """
  def message_agent_and_wait(agent_id, text, timeout) do
    with {:ok, _} <- send_agent_message(agent_id, text) do
      await_mailbox_turn(agent_id, System.monotonic_time(:millisecond) + timeout)
    end
  end

  defp await_mailbox_turn(agent_id, deadline) do
    agent = Repo.get!(CodeMySpec.Agents.Agent, agent_id)
    scope = %Scope{active_account_id: agent.account_id, active_project_id: agent.project_id}

    pending =
      Enum.any?(
        AgentMailbox.entries(scope, agent_id),
        &(&1.state in [:queued, :claimed, :consumed, :uncertain])
      )

    cond do
      not pending ->
        with {:ok, messages} <- CmsHarness.Agents.history(agent_id),
             do: {:ok, inspect(messages, pretty: true, limit: :infinity)}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :message_timed_out}

      true ->
        Process.sleep(20)
        await_mailbox_turn(agent_id, deadline)
    end
  end

  defdelegate agent_tools(agent_id), to: CmsHarness.Agents, as: :tools
  defdelegate agent_tool_context(agent_id), to: CmsHarness.Agents, as: :tool_context

  @doc """
  Send every agent's turn events to the server over `socket`.

  The one hop an in-process agent has always been missing. `CmsHarness.Agents`
  defaults `on_event` to a lookup in the harness registry, which in a spex
  finds nothing and answers `:ok` — so every agent the suite has ever started
  ran with its transcript going nowhere, and a criterion asking what an agent
  *did* had only the agent's own account of itself to read.

  Through the bridge for the same reason `install_workspace_runner/2` is: a
  criterion cannot name `CodeMySpecTest`, and should not.

  `socket` must be a joined `harness_project` channel. Uninstalls itself when
  the test ends; the key is global, so this is `async: false` territory.
  """
  @spec relay_turn_events(Phoenix.Socket.t()) :: :ok
  defdelegate relay_turn_events(socket), to: CodeMySpecTest.TurnEventRelay, as: :install

  @doc """
  Swap the agent transport for one that hands dispatched messages back to
  this process instead of delivering them for real.

  Through the bridge for the same reason `install_workspace_runner/2` is: a
  criterion cannot name `CodeMySpecTest`, and should not. Needed for
  criterion 1376 (story 1046) — `Promotion.tell_the_agent/4`'s correction on
  a failed restart is a fire-and-forget dispatch with no other observable
  surface: no DB row, no MCP response. Routes only `project`, so tests that
  each route their own project can run concurrently.
  """
  @spec install_recording_agent_transport(term()) :: :ok
  def install_recording_agent_transport(project),
    do: CodeMySpecTest.RecordingAgentTransport.listen(project)

  @doc "Route `project`'s agent traffic to `transport`, for this test alone."
  @spec route_agent_transport(term(), module()) :: :ok
  def route_agent_transport(project, transport),
    do: CodeMySpecTest.AgentTransportRouter.route(project, transport)

  @doc "Route one agent's traffic to `transport`, without touching its project's route."
  @spec route_agent(String.t(), module()) :: :ok
  def route_agent(agent_id, transport),
    do: CodeMySpecTest.AgentTransportRouter.route_agent(agent_id, transport)

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

  @doc "Count pending notifications through the inbox's visibility rules."
  defdelegate count_pending_notifications(user_id), to: Notifications

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

  @doc "Project IDs visible to this spex's database connection, including escaped committed rows."
  def visible_project_ids do
    Repo.all(Project) |> Enum.map(& &1.id)
  end

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
    # The call is made by the LiveView process rather than the test, but
    # `Req.Test` resolves ownership through `$callers` and LiveView
    # propagates it to the process it spawns — a per-process stub set by
    # this (the test's own) process is already visible there. No shared
    # mode needed; see `fake_providers/1`'s moduledoc for the full story.
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

  @doc """
  Reverses `seal_three_amigos/2`, directly.

  There is no product-facing door to walk back through: `ThreeAmigos.evaluate/2`
  only ever seals, on a passing check, never unseals. So this writes the field
  the checker reads (`BddRulesChecker.sealed?/2`) the one way available, the
  same way `seal_three_amigos/2`'s own doc explains why it does not.
  """
  @spec unseal_three_amigos(term(), term()) :: :ok
  def unseal_three_amigos(scope, story) do
    {:ok, _story} = CodeMySpec.Stories.update_story(scope, story, %{three_amigos_sealed: false})
    :ok
  end

  @doc """
  Starts an agent task the way the removed `POST /api/agent-tasks/start`
  controller used to, for a spex whose criterion is about the task's own
  behaviour rather than about having an HTTP endpoint for it -- LocalWeb, and
  that route with it, is gone (issue f532f990).

  Mirrors the JSON response's string-keyed shape (`"prompt"`/`"error"`) so a
  spex written against the HTTP call needs no change beyond how it gets the
  response.
  """
  @spec start_agent_task(Scope.t(), map()) :: map()
  def start_agent_task(%Scope{} = scope, params) do
    args = %{
      external_id: params["external_id"],
      session_type: params["session_type"],
      module_name: params["module_name"]
    }

    case AgentTasks.StartAgentTask.run(scope, args) do
      {:ok, prompt, _sync_result} -> %{"prompt" => prompt}
      {:error, reason} -> %{"error" => inspect(reason)}
    end
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

    stub_no_preview_by_default()

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
    #
    # Checking `Process.whereis/1` and branching on it used to be how this
    # decided which of those two cases it was in, and it is a check-then-act
    # race: two async tests whose setup runs at the same moment can both see
    # `nil`, both call `start_link`, and whichever loses crashes its own setup
    # with `{:error, {:already_started, pid}}` instead of reading as a second
    # install. Attempting the start and handling that outcome is the atomic
    # form of the same idea — the name registration itself is the only lock
    # that actually holds across processes.
    start_runner_with_ordered_teardown(opts)

    :ok
  end

  # `Workspaces.instance_env/1` asks `PreviewTunnel.ensure/1` for every boot of
  # a main copy, so booting the fake now reaches a real `Req.Test` client
  # (`config/test.exs` pins one for every test). A caller here wants a
  # workspace to come up, not a tunnel — same reasoning as `stub_stripe_by_default/0`
  # in `CodeMySpecSpexCase`: nobody installing this fixture should also have to
  # stand up a fake Cloudflare. Answering with `success: false` is enough:
  # `PreviewTunnel.create/2` reads it as `{:error, {:cloudflare, body}}`, which
  # `preview_env/1` already treats as best-effort and drops. A scenario whose
  # subject is the preview itself stubs `PreviewTunnel` again afterward, in its
  # own test process, which simply replaces this one.
  defp stub_no_preview_by_default do
    Req.Test.stub(CodeMySpec.Workspaces.PreviewTunnel, fn conn ->
      conn
      |> Conn.put_resp_content_type("application/json")
      |> Conn.send_resp(200, Jason.encode!(%{"success" => false, "errors" => []}))
    end)
  end

  @doc """
  Stand the fake in for Docker as a dev box provider, with the app's own
  instance runner left as `Runner.Local` (what every dev app has) so a Docker box
  that wrongly went through the instance runner cannot pass.
  """
  @spec install_docker_dev_box_runner(keyword()) :: :ok
  def install_docker_dev_box_runner(opts \\ [healthy?: true, serving: :serving]) do
    install_workspace_runner(opts,
      runner: CodeMySpec.Workspaces.Runner.Local,
      dev_box_runners: %{docker: FakeWorkspaceRunner}
    )
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

  @doc "Every `start` the context made on the fake workspace, oldest first."
  @spec workspace_start_calls() :: [tuple()]
  defdelegate workspace_start_calls(), to: FakeWorkspaceRunner, as: :calls

  @doc """
  The files the fake workspace was started with, `%{path_in_container => contents}`:
  where a secret that must stay out of the container's environment is put instead.
  """
  @spec workspace_mounted_files() :: %{String.t() => String.t()}
  defdelegate workspace_mounted_files(), to: FakeWorkspaceRunner, as: :mounted_files

  defp start_runner_with_ordered_teardown(opts) do
    started_before = WorkspaceWatchers.running()

    case FakeWorkspaceRunner.start_link(opts) do
      {:ok, runner} -> register_runner_teardown(started_before, runner)
      # Lost the race to start it: somebody else's setup registered the name
      # first, a moment too early for our own `Process.whereis/1` (if we still
      # had one) to have seen it. Reconfiguring it is exactly what the other
      # branch of the old check did, and leaving its teardown in place is
      # correct — only the test that actually started it should tear it down.
      {:error, {:already_started, _pid}} -> FakeWorkspaceRunner.configure(opts)
    end
  end

  defp register_runner_teardown(started_before, runner) do
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
  Set whether the fake workspace's container is alive at all -- the one
  reason `Workspaces.state/1` answers `:down` outright, before `serving/1`
  is even asked (story 1030, criterion 1115: a container that died after
  the workspace was already running must stop reading as up).
  """
  defdelegate put_workspace_alive(alive?), to: FakeWorkspaceRunner, as: :put_alive

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

  @doc "Starts a workspace with its real boot watcher while the fake app waits to answer."
  @spec boot_waiting_workspace(Scope.t()) :: :ok
  def boot_waiting_workspace(%Scope{} = scope) do
    install_workspace_runner(healthy?: false, alive?: true, serving: :down)
    {:ok, _workspace} = CodeMySpec.Workspaces.boot(scope)
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

  @doc "Requests observed by the stateful Resend fake, oldest first."
  @spec resend_requests(pid()) :: [{String.t(), String.t()}]
  def resend_requests(resend), do: resend |> Agent.get(& &1.requests) |> Enum.reverse()

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

  @doc "Ensure the project has its default analyzer and deployment configuration."
  def ensure_configuration!(scope) do
    Configurations.get_or_create(scope)
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
  def add_phoenix_project_shape(%Scope{} = scope),
    do:
      add_phoenix_project_shape(%{
        execution_context: UsersFixtures.fixture_execution_context(scope)
      })

  def add_phoenix_project_shape(%{execution_context: env}) do
    :ok = ExecutionContexts.write_file(env, "mix.exs", "# stub for PhoenixProject.evaluate\n")
    :ok = ExecutionContexts.write_file(env, "lib/.gitkeep", "")
    :ok = ExecutionContexts.write_file(env, "config/.gitkeep", "")
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
  def remove_mix_exs(%Scope{} = scope),
    do: remove_mix_exs(%{execution_context: UsersFixtures.fixture_execution_context(scope)})

  def remove_mix_exs(%{execution_context: env}) do
    :ok = ExecutionContexts.delete_file(env, "mix.exs")
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

  # -- Terminal agents (timeline spex fixture setup) --
  @doc """
  Creates a terminal agent (with optional tasks and controllable
  `inserted_at`/`updated_at`). Agents originate from the SessionStart hook in
  production; the bridge surfaces direct creation so spex can stage specific
  states without driving a full session.
  """
  defdelegate terminal_agent_fixture(scope, attrs \\ %{}), to: TerminalAgentFixtures

  # -- QA spex fixture setup, Stories 726/727 --
  @doc """
  Creates a terminal agent (role main, so it takes no team seat) holding an active
  `qa_complete` task linked to the given
  story. Used by QA spex setup to seed `context.story` and `context.task_id`
  without needing the full requirement prerequisite chain satisfied.

  Returns `{story, task_id, agent}`.
  """
  @spec qa_story_task_fixture(Scope.t(), keyword()) ::
          {Story.t(), String.t(), CodeMySpec.Agents.Agent.t()}
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

    story = Stories.get_story!(scope, story.id)

    story =
      if story.qa_ready_at && story.qa_ready_commit do
        story
      else
        {:ok, certified} = Stories.set_qa_ready(scope, story, String.duplicate("a", 40))
        certified
      end

    task_id = Ecto.UUID.generate()

    # Embedded as given, with no activation rules: a scenario may stage QA work
    # for the same story on more than one agent.
    agent =
      TerminalAgentFixtures.terminal_agent_fixture(scope, %{
        role: :main,
        tasks: [
          %{
            id: task_id,
            status: :active,
            session_type: QaStory,
            requirement_name: "qa_complete",
            story_id: story.id,
            project_id: scope.active_project_id,
            started_at: DateTime.utc_now()
          }
        ]
      })

    task = TaskOwner.find_task(agent, task_id)

    {:ok, _review} = CodeMySpec.Qa.capture_story_review(scope, agent, task)
    {:ok, agent} = CodeMySpec.Agents.fetch_agent(scope, agent.id)

    {story, task.id, agent}
  end

  @doc """
  A recorded task on the agent's own row — `TaskOwner`'s shape, not a session's.
  Defaults to active; `:status` can establish a pre-existing terminal task for
  scenarios about rejecting an operation on historical work.

  `start_task` is what a real Alloy agent calls to claim work, and it goes
  through `TaskOwner.add_task/3` directly on the agent — there is no session in
  the middle. 

  Returns `{agent, task}`, both the updated agent and the task recorded on
  it — spex files reach `CodeMySpec` only through this bridge, so the caller
  should not need a second call through `TaskOwner` just to read back what was
  just staged.
  """
  @spec agent_task_fixture(Scope.t(), CodeMySpec.Agents.Agent.t(), keyword()) ::
          {CodeMySpec.Agents.Agent.t(), CodeMySpec.Agents.Agent.Task.t()}
  def agent_task_fixture(%Scope{} = scope, %CodeMySpec.Agents.Agent{} = agent, opts \\ []) do
    task_id = Keyword.get(opts, :id, Ecto.UUID.generate())

    {:ok, agent} =
      TaskOwner.add_task(scope, agent, %{
        id: task_id,
        status: Keyword.get(opts, :status, :active),
        requirement_name: Keyword.get(opts, :requirement_name, "qa_complete"),
        # The task module `evaluate_task` dispatches to; unset is a task with none.
        session_type: Keyword.get(opts, :session_type),
        story_id: Keyword.get(opts, :story_id),
        issue_id: Keyword.get(opts, :issue_id),
        # Settable, because a criterion about how long a task has been open
        # cannot produce elapsed time any other way and must not sleep for it.
        started_at: Keyword.get(opts, :started_at, DateTime.utc_now())
      })

    {agent, TaskOwner.find_task(agent, task_id)}
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
    {:ok, _question} = MainAgent.give_up_on_question(scope, question_id)
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
  def cadence_tick(%Scope{} = scope), do: MainAgent.check_in(scope)

  @doc "Start a real recovery timer for a scheduling spec and clean up its supervised child."
  @spec start_recovery_timer(Scope.t()) :: :ok
  def start_recovery_timer(%Scope{} = scope) do
    {:ok, pid} = MainAgent.ensure_cadence(scope)

    ExUnit.Callbacks.on_exit(fn ->
      DynamicSupervisor.terminate_child(CodeMySpec.Agents.Main.CadenceSupervisor, pid)
    end)

    :ok
  end

  @doc "Wait for recovery events and verify the public cadence report advanced."
  def await_recovery_check(read_report, since, within_ms \\ 5_000)
      when is_function(read_report, 0) do
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "cadence:checks")

    try do
      deadline = System.monotonic_time(:millisecond) + within_ms
      wait_for_recovery_check(read_report, since, deadline)
    after
      Phoenix.PubSub.unsubscribe(CodeMySpec.PubSub, "cadence:checks")
    end
  end

  defp wait_for_recovery_check(read_report, since, deadline) do
    body = read_report.()

    checked_at =
      with [_, timestamp] <- Regex.run(~r/last check:\s*(\S+)/i, body),
           {:ok, instant, _} <- DateTime.from_iso8601(timestamp),
           :gt <- DateTime.compare(instant, since) do
        instant
      else
        _ -> nil
      end

    cond do
      checked_at ->
        checked_at

      System.monotonic_time(:millisecond) >= deadline ->
        raise "No new recovery check was observable through cadence in time: #{body}"

      true ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:recovery_checked, _project_id, _checked_at} ->
            wait_for_recovery_check(read_report, since, deadline)
        after
          remaining ->
            raise "No new recovery check was observable through cadence in time: #{body}"
        end
    end
  end

  @doc "How often this project's main agent is woken, in seconds."
  @spec cadence_interval(Scope.t()) :: pos_integer()
  def cadence_interval(%Scope{} = scope), do: MainAgent.cadence_interval(scope)

  @doc """
  Set how often this project's main agent is woken.

  Through the configuration the product writes, not a module attribute — the
  whole of criterion 3331 is that the number is somewhere it can be changed
  without a deploy.
  """
  @spec set_cadence_interval(Scope.t(), pos_integer()) :: :ok
  def set_cadence_interval(%Scope{} = scope, seconds),
    do: MainAgent.set_cadence_interval(scope, seconds)

  @doc "Whether this project's cadence is still waking its main agent."
  @spec cadence_running?(Scope.t()) :: boolean()
  def cadence_running?(%Scope{} = scope), do: MainAgent.cadence_running?(scope)

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

  @doc "Recompute this checkout's graph now, as `sync_project` does."
  def recompute_graph(%Scope{} = scope) do
    _ = Requirements.recompute(scope)
    :ok
  end

  @doc "Why the writer serving this project's reads last failed, or nil."
  def graph_last_error(%Scope{active_project_id: project_id}) do
    case GraphReport.writer_status(project_id) do
      %{last_error: %{message: message}} -> message
      _ -> nil
    end
  end

  @doc """
  Make this project's graph writer raise instead of recomputing.

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
  Switch an agent on, the way the continuous control does -- the counterpart of
  `pause_agent/2`.

  A scenario that needs an agent to hold a task before it can be woken creates
  it not continuous (nothing offers it work), has it claim, and switches it on
  here; an agent holding a task is not offered another (a3354bfc).
  """
  @spec continue_agent(Scope.t(), Ecto.UUID.t()) :: {:ok, map(), atom()} | {:error, term()}
  def continue_agent(%Scope{} = scope, agent_id) do
    CodeMySpec.Agents.set_agent_continuous(scope, agent_id, true)
  end

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
    {:ok, agent} = CodeMySpec.Agents.fetch_owner(scope, nil, session_id)
    {:ok, _agent} = CodeMySpec.TaskOwner.set_continuous(agent, true)
    :ok
  end

  @spec start_turn(Scope.t(), String.t(), keyword()) :: :ok
  def start_turn(%Scope{} = scope, agent_id, opts \\ []) do
    socket = %Phoenix.Socket{assigns: %{scope: scope}}

    event =
      ChannelClient.encode_turn_event(%{
        event: Keyword.get(opts, :event, :turn_started),
        turn: Keyword.get(opts, :turn, 1),
        payload: Keyword.get(opts, :payload)
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

  @doc "Seed an operator instruction already present before the tested agent turn."
  def prior_operator_instruction(%Scope{} = scope, %{id: agent_id}, text) do
    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent_id
      )

    {:ok, _message} = Conversations.add_message(conversation, :operator, text, "operator")
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
  Put this agent's outstanding turn request in the past.

  A turn offered to an agent stands for five minutes; an agent that never takes
  the turn is offered again once that lapses, and main is told it stalled. Time
  passing has no surface, so this moves the agent's offer history back by
  `seconds` the way `age_agent_messages/3` backdates a transcript.

  All of it, not just the open request: a stall counts only turns requested
  after the agent's last settled one (`Offers.unstarted_turn/1`), so a request
  moved behind a settlement that stayed put reads as no stall at all.
  """
  @spec age_turn_request(Scope.t(), String.t(), number()) :: :ok
  def age_turn_request(%Scope{} = _scope, agent_id, seconds) do
    secs = round(seconds)

    from(o in CodeMySpec.Agents.Offer,
      where: o.agent_id == type(^agent_id, :binary_id),
      update: [
        set: [
          turn_requested_at: datetime_add(o.turn_requested_at, ^(-secs), "second"),
          outcome_at: datetime_add(o.outcome_at, ^(-secs), "second")
        ]
      ]
    )
    |> Repo.update_all([])

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
    naive = at |> DateTime.to_naive()

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
  #
  # The criterion is either a real one (it carries `:number`, and `:id` is its
  # database id) or the map `GetStory` parses, whose `:id` is the number the
  # agent sees. Each is matched on its own key: matching either key against
  # both took a criterion whose *id* equalled another's *number* — which only
  # happens on a fresh database, where ids are small (892 in a gate shard).
  def spec_file_path(%{id: story_id}, %{id: _} = wanted) do
    story = Repo.get!(Story, story_id) |> Repo.preload(:criteria)

    criterion =
      case wanted do
        %{number: number} when is_integer(number) ->
          Enum.find(story.criteria, &(&1.id == wanted.id))

        %{id: number} ->
          Enum.find(story.criteria, &(&1.number == number))
      end

    unless criterion do
      raise ArgumentError,
            "criterion #{inspect(wanted.id)} does not belong to story #{inspect(story_id)}"
    end

    BddSpecs.spec_file_path(story, criterion)
  end

  # -- Problems --
  defdelegate problem_fixture(scope, attrs \\ %{}), to: ProblemsFixtures

  # -- Issues (QA triage / fix scenarios) --
  defdelegate issue_fixture(scope, attrs \\ %{}), to: IssuesFixtures
  defdelegate resolved_issue_fixture(scope, issue, resolution \\ "Fixed."), to: IssuesFixtures
  defdelegate retriaged_issue_fixture(scope, issue, story_id), to: IssuesFixtures

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
  Send `message` to `test_pid` from inside a stub — same reasoning as
  `notify_call/3`, generalised: some stubs need to report more than a
  request path (a parsed body, a decoded ingress list) for a spex's own
  `assert_receive`.
  """
  @spec notify(pid(), term()) :: term()
  def notify(test_pid, message), do: send(test_pid, message)

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

  @doc """
  A project, with its own account and owning user, committed for real —
  outside the Ecto Sandbox — so a spex's own subprocess (a separate OS
  process with its own fresh Postgres connection) can see it exactly as
  production would (story 1013, criterion 916; product's decision on the
  question it raised, after the sandbox user-agent seam was found not to
  reach this read: `ensure_local_credential/1`'s own database lookup is a
  plain query from that subprocess's own connection, not an HTTP request,
  so no header can carry sandbox metadata into it).

  `deploy_key` goes through the real `Projects.update_project/3` changeset,
  so it is encrypted and `deploy_key_hash` is set exactly as in production
  -- never written by hand.

  Deleted in `on_exit`, also outside the sandbox — a spex that leaves a
  committed row behind is a defect.
  """
  @spec committed_project_with_deploy_key!(String.t()) :: CodeMySpec.Projects.Project.t()
  def committed_project_with_deploy_key!(deploy_key) do
    {user, account, project} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(CodeMySpec.Repo, fn ->
        user = user_fixture()
        account = account_with_owner_fixture(user)
        scope = user_scope_fixture(user, account)
        project = project_fixture(scope, %{})

        {:ok, project} =
          CodeMySpec.Projects.update_project(scope, project, %{deploy_key: deploy_key})

        {user, account, project}
      end)

    ExUnit.Callbacks.on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(CodeMySpec.Repo, fn ->
        CodeMySpec.Repo.delete!(project)
        CodeMySpec.Repo.delete!(account)
        CodeMySpec.Repo.delete!(user)
      end)
    end)

    project
  end

  @doc """
  The partition suffix naming the live process's own `CodeMySpec.Repo`
  database right now -- e.g. `"hb057ea73"` for `code_my_spec_testhb057ea73`.

  A `scratch_worktree!/0` subprocess does not inherit this: `mix cms.spex`
  assigns each shard its own database by overriding `Application.get_env`
  at runtime, never by changing the OS-level `MIX_TEST_PARTITION` variable,
  so a spawned subprocess -- which only ever sees the real OS environment --
  resolves to whatever ambient partition this whole session started with,
  not this test's own shard (story 1013, criterion 916; found by comparing
  `Application.get_env(:code_my_spec, CodeMySpec.Repo)[:database]` read
  from this process against the same expression run inside a subprocess
  with no override: the two did not match). A spex that needs its own
  committed row visible to a real subprocess must pass this back in
  explicitly as `MIX_TEST_PARTITION`, via `scratch_worktree_env/1`.
  """
  @spec live_test_partition!() :: String.t()
  def live_test_partition! do
    Application.get_env(:code_my_spec, CodeMySpec.Repo)[:database]
    |> String.replace_prefix("code_my_spec_test", "")
  end

  @doc """
  A real Bandit listener for `CodeMySpecWeb.Endpoint`, on a free loopback
  port — the public twin of `HarnessHooksSpexHelpers`' private `listen/0`,
  for a spex that needs a reachable server URL without the rest of that
  helper's working-copy/channel machinery (story 1013, criterion 916).

  Not linked, and not stopped in `on_exit`, for the reason `listen/0`
  already documents: a listener linked to the test process closes
  mid-flight if something still serving through it outlives the test.
  Loopback-only, ephemeral, and reclaimed by the OS once this VM exits.
  """
  @spec start_live_listener!() :: {pid(), String.t()}
  def start_live_listener! do
    {:ok, listener} =
      Bandit.start_link(
        plug: CodeMySpecWeb.Endpoint,
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    Process.unlink(listener)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    {listener, "http://127.0.0.1:#{port}"}
  end

  @doc "A project's deploy key, minting one if it has none yet."
  def ensure_project_deploy_key(scope, project) do
    {:ok, project} = CodeMySpec.Projects.ensure_deploy_key(scope, project)
    project
  end

  @doc "Set and verify a project's sending domain."
  def verify_project_domain(project, domain) do
    now = DateTime.utc_now()

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

  @doc "Write a file into an environment (bridge to ExecutionContexts)."
  def write_env_file(env, path, content), do: ExecutionContexts.write_file(env, path, content)

  @doc """
  Remove a file through the scope's environment.

  The counterpart to `write_env_file/3`, and the only way a spex can retire a
  component: there is no `delete_component` an agent can call (issue
  `c23f4427`), and components are projections of files, so a component stops
  existing when nothing names its module any more.
  """
  def delete_env_file(env, path), do: ExecutionContexts.delete_file(env, path)

  @doc "Run a command in an environment (bridge to ExecutionContexts)."
  def env_cmd(env, command, args), do: ExecutionContexts.cmd(env, command, args)
  def env_cmd(env, command, args, opts), do: ExecutionContexts.cmd(env, command, args, opts)

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

  @doc "Whether the harness's in-memory keyring (story 1132) holds this specific key."
  @spec harness_holding_key?(String.t()) :: boolean()
  def harness_holding_key?(key), do: key in CmsHarness.SopsKeyring.keys()

  @doc "The path the sops key socket (story 1132) listens on."
  @spec sops_key_socket_path() :: Path.t()
  def sops_key_socket_path, do: CmsHarness.SopsKeySocket.path()

  @doc """
  A shell command that runs this checkout's own `cms sops-key` through
  `mix run --no-start`, standing in for the packaged `cms` binary a real
  dev box runs: the `cms` already installed on this dev machine's own
  PATH is an unrelated release of this project and never reflects an
  uncommitted source change. `mix run`'s own final step execs into the
  BEOM VM without forking (confirmed empirically), so this process's
  reported parent is whatever actually launched the shim — `sops` itself,
  when `SOPS_AGE_KEY_CMD` points here.
  """
  @spec sops_key_shim_path!() :: Path.t()
  def sops_key_shim_path! do
    dir = spex_tmp_dir!("sops-key-shim")
    path = Path.join(dir, "cms-sops-key-shim")
    root = File.cwd!()

    spex_write_file!(path, """
    #!/bin/sh
    cd #{root} || exit 1
    exec env MIX_ENV=test mix run --no-start --no-compile -e 'CmsHarness.Cli.SopsKey.start([])'
    """)

    File.chmod!(path, 0o700)
    path
  end

  @doc "Every path the harness's own local HTTP router answers, for a criterion about what it does not."
  @spec harness_web_route_paths() :: [String.t()]
  def harness_web_route_paths do
    CmsHarness.Web.Router.__routes__() |> Enum.map(& &1.path)
  end

  @doc """
  The one escape hatch for `System.cmd/3` in a spec, for a criterion whose
  subject is inherently an OS-level program (`sops`, `age-keygen`) rather
  than anything the app's own LiveView/hook/MCP surface could run or
  observe. See `.code_my_spec/knowledge/bdd/spex/boundaries.md`.

  Also the one way a spec drives a `mix` task as product directed for
  story 1013's criteria 916-918: as a separate OS process, not `apply/3`
  and not a direct call into the module under test, asserting only what
  can be seen from outside (exit status, output, files, database rows).
  """
  @spec run_cmd(String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def run_cmd(cmd, args, opts \\ []) do
    opts = Keyword.put_new(opts, :stderr_to_stdout, true)
    System.cmd(cmd, args, opts)
  end

  @doc """
  Like `run_cmd/3`, but for a `mix` subprocess that must not outlive this
  test -- story 1013's criteria 916-918 learned why the hard way.

  `System.cmd/3` blocks this process until the external program exits, and
  an ExUnit test timeout kills this process outright rather than letting it
  unwind: the port closes, but the `erl` VM `mix` execs into is a real OS
  process on the other side of it, and nothing reaps it. Orphaned (`ppid`
  1), it kept running at ~190% CPU, and every run like it slowed the whole
  machine enough to produce another one -- a 6-problem spex run compounded
  to 11 before the cause was found.

  Spawns via `Port.open/2` so the OS pid is known immediately, registers
  its kill with `on_exit/1` (which ExUnit runs on every path out of a
  test -- pass, fail, or its own timeout), and races the command against
  `timeout_ms`, strictly shorter than the test's own `spex_timeout/0`, so a
  genuinely stuck command fails here and is killed here, long before ExUnit
  would ever have to kill the test process itself.
  """
  @spec run_cmd_bounded(String.t(), [String.t()], keyword(), pos_integer()) ::
          {String.t(), non_neg_integer() | :timeout}
  def run_cmd_bounded(cmd, args, opts \\ [], timeout_ms \\ 120_000) do
    executable = System.find_executable(cmd) || raise "#{cmd} not found on PATH"

    port_opts =
      [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: args]
      |> put_port_opt(:cd, opts[:cd])
      |> put_port_opt(:env, env_charlists(opts[:env]))

    port = Port.open({:spawn_executable, String.to_charlist(executable)}, port_opts)
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    ExUnit.Callbacks.on_exit(fn -> kill_os_pid(os_pid) end)

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_bounded(port, os_pid, deadline, "")
  end

  defp put_port_opt(opts, _key, nil), do: opts
  defp put_port_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp env_charlists(nil), do: nil

  defp env_charlists(env),
    do: Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

  # `after` on a bare `receive` is an inactivity timer, not a deadline -- it
  # resets on every message, and a real `mix compile` sends one every few ms.
  # `remaining/1` turns that into an absolute bound: total elapsed matters,
  # not the gap since the last line of compiler output.
  defp collect_bounded(port, os_pid, deadline, acc) do
    receive do
      {^port, {:data, data}} -> collect_bounded(port, os_pid, deadline, acc <> data)
      {^port, {:exit_status, status}} -> {acc, status}
    after
      remaining(deadline) ->
        kill_os_pid(os_pid)
        {acc <> "\n[run_cmd_bounded] killed after exceeding its deadline", :timeout}
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp kill_os_pid(os_pid) do
    System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
    Process.sleep(200)
    System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  @doc """
  Runs `fun` with `CodeMySpec.Repo` redirected to `database`, a name nothing
  has used, for story 1013's criteria 916-918: driving the real
  onboarding/migration code in-process against a genuinely fresh database,
  instead of a real `mix` subprocess whose own full recompile proved too
  heavy for this shared machine (main, 2026-10-22).

  Two redirects, both required: `Application.put_env/3` so `Repo.config/0`
  (and anything that reads it, like `creatable/1`) names `database`; a
  second, unpooled connection via `put_dynamic_repo/1` so queries *through*
  `Repo` -- `Ecto.Migrator`, `SQL.query/3` -- reach it too. `Repo.config/0`
  does not consult the dynamic repo's own startup options, so the first
  redirect alone would leave every config read naming `database` while
  every query still ran against whatever this process was already
  connected to.

  Drops `database` on exit, whether `fun` created it or not -- the
  pending-migrations check this exists to drive always ends by creating
  one, so that is not an edge case here, but a run that answers earlier
  (an unreachable postgres, say) should not leave a scratch database for
  the next one to collide with.

  On exit, not inline `after`: a scenario's `then_` steps run *after*
  `fun` returns, in the same test, and still need `database` to exist --
  an inline `after` tore it down the instant `fun` returned, before any
  `then_` could see it created at all (story 1013, criterion 917).
  `on_exit/1` runs once, at the true end of the test, after everything
  the scenario itself does.
  """
  @spec with_throwaway_database(String.t(), (-> result)) :: result when result: term()
  def with_throwaway_database(database, fun) do
    original_config = Application.get_env(:code_my_spec, CodeMySpec.Repo)

    Application.put_env(
      :code_my_spec,
      CodeMySpec.Repo,
      Keyword.put(original_config, :database, database)
    )

    dyn_config =
      CodeMySpec.Repo.config()
      |> Keyword.put(:name, nil)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)
      # The database does not exist when this pool starts, so its connections
      # go into reconnect backoff. The check must still fail fast on that (it is
      # how it learns to create the database), but once created, the migration
      # waited on connections still backing off at the default ceiling and
      # timed out under gate load. A short ceiling brings them back promptly.
      |> Keyword.put(:backoff_min, 100)
      |> Keyword.put(:backoff_max, 500)

    {:ok, pid} = CodeMySpec.Repo.start_link(dyn_config)
    previous = CodeMySpec.Repo.get_dynamic_repo()
    CodeMySpec.Repo.put_dynamic_repo(pid)

    ExUnit.Callbacks.on_exit(fn ->
      CodeMySpec.Repo.put_dynamic_repo(previous)
      stop_dynamic_repo(pid)
      Application.put_env(:code_my_spec, CodeMySpec.Repo, original_config)

      run_cmd("psql", [
        "postgres://postgres:postgres@localhost/postgres",
        "-tAc",
        "drop database if exists #{database}"
      ])
    end)

    fun.()
  end

  # By the time `on_exit` runs, the test process that `start_link`ed this
  # repo has already exited; a non-:normal exit (ExUnit does not always use
  # :normal) propagates to this linked, non-trapping child too. That is a
  # race against the `GenServer.stop/1` below it, not a reason to skip the
  # stop: `Process.alive?/1` can see the pid as alive and then have it start
  # dying before `GenServer.stop/1`'s own call lands, which that call
  # reports as an EXIT rather than swallowing. The database is already
  # dropped right after this regardless of how the pid went down.
  defp stop_dynamic_repo(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  @doc """
  `CodeMySpec.Repo.config/0`, naming a different database -- for a spex that
  has to ask whether a config naming some other partition would be allowed
  to create it (story 1013, criterion 918), without calling into
  `CodeMySpec.Repo` from the spex file itself.
  """
  @spec repo_config_naming(String.t()) :: keyword()
  def repo_config_naming(database), do: Keyword.put(CodeMySpec.Repo.config(), :database, database)

  @doc """
  `CmsHarness.Onboarding.mint/2`, for a spex driving onboarding's own
  credential resolution in-process (story 1013, criterion 916).
  """
  @spec onboard_mint(Path.t(), String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def onboard_mint(root, project_id), do: CmsHarness.Onboarding.mint(root, project_id)

  @doc """
  `CodeMySpec.TestMigrations.refuse_if_behind!/0`, for a spex driving the
  real first-run migration check in-process (story 1013, criterion 917).
  """
  @spec check_test_migrations_refuse_if_behind!() :: :ok
  def check_test_migrations_refuse_if_behind!, do: CodeMySpec.TestMigrations.refuse_if_behind!()

  @doc """
  `CodeMySpec.TestMigrations.creatable/1`, for a spex asking whether a
  config naming some partition may be created (story 1013, criterion 918).
  """
  @spec check_test_migrations_creatable(keyword()) :: :ok | {:error, String.t()}
  def check_test_migrations_creatable(config), do: CodeMySpec.TestMigrations.creatable(config)

  @doc """
  Sets an OS env var for the rest of the test, restored (or unset, if it
  was never set) on exit -- so a spex asserting about `CMS_DEPLOY_KEY` or
  similar never calls `System.put_env/2` itself.
  """
  @spec set_env_var!(String.t(), String.t()) :: :ok
  def set_env_var!(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        nil -> System.delete_env(name)
        value -> System.put_env(name, value)
      end
    end)

    :ok
  end

  @doc """
  Unsets an OS env var for the rest of the test, restored on exit -- the
  "ensure it is absent" counterpart to `set_env_var!/2`.
  """
  @spec ensure_env_var_unset!(String.t()) :: :ok
  def ensure_env_var_unset!(name) do
    previous = System.get_env(name)
    System.delete_env(name)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        nil -> :ok
        value -> System.put_env(name, value)
      end
    end)

    :ok
  end

  @doc """
  Lets `mod`'s `Req.Test` stub answer a request made from a persistent named
  process (story 1013, criterion 916: `CmsHarness.Token`'s GenServer, already
  started by the app supervisor, not spawned per test) rather than only from
  the calling test process itself. A no-op when nothing is registered under
  `mod`; multi-clause, not a `case`, so a spex's own `setup` can call it
  without tripping `NoControlFlowInTests`.
  """
  @spec allow_stub(module()) :: :ok
  def allow_stub(mod), do: mod |> Process.whereis() |> allow_stub_pid(mod, self())

  defp allow_stub_pid(nil, _mod, _owner), do: :ok
  defp allow_stub_pid(pid, mod, owner), do: Req.Test.allow(mod, owner, pid)

  @doc "A fresh tmp directory for a spec's own scratch files, removed on exit."
  @spec spex_tmp_dir!(String.t()) :: Path.t()
  def spex_tmp_dir!(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  @doc "Writes a file for a spec's own setup (e.g. feeding `sops` a plaintext input)."
  @spec spex_write_file!(Path.t(), String.t()) :: :ok
  def spex_write_file!(path, contents) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, contents)
  end

  @doc "Reads a file a spec's own setup or an external command wrote, or \"\" if absent."
  @spec spex_read_file_or_blank(Path.t()) :: String.t()
  def spex_read_file_or_blank(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _reason} -> ""
    end
  end

  @doc "Whether a file exists, for a spec checking something an external command or the harness wrote outside any app surface."
  @spec spex_file_exists?(Path.t()) :: boolean()
  def spex_file_exists?(path), do: File.exists?(path)

  @doc "A file's stat, for a spec checking permission bits an app surface cannot report."
  @spec spex_file_stat(Path.t()) :: {:ok, File.Stat.t()} | {:error, term()}
  def spex_file_stat(path), do: File.stat(path)

  @doc "Whether `path` exists and its mode denies every bit to group and other (0700/0600-style)."
  @spec spex_user_only?(Path.t()) :: boolean()
  def spex_user_only?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o077) == 0
      {:error, _reason} -> false
    end
  end

  @doc "Generates an age keypair under `dir`, returning `{public_recipient, private_key}`."
  @spec age_keypair!(Path.t()) :: {String.t(), String.t()}
  def age_keypair!(dir) do
    keyfile = Path.join(dir, "age-#{System.unique_integer([:positive])}.txt")
    {_out, 0} = run_cmd("age-keygen", ["-o", keyfile])
    {pub, 0} = run_cmd("age-keygen", ["-y", keyfile])

    priv =
      keyfile
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.find(&String.starts_with?(&1, "AGE-SECRET-KEY-"))

    {String.trim(pub), priv}
  end

  @doc """
  A real, well-formed age private key nobody's data is actually encrypted
  to -- for a scenario that only needs *a* key `CmsHarness.SopsKeyring`
  will hold, not one that has to decrypt anything.

  `SopsKeyring` is one process shared by the whole spex run; whatever any
  scenario installs into it stays there for every scenario that runs
  after it in the same `mix spex` invocation. A string like
  `"AGE-SECRET-KEY-1DEV"` reads as a plausible key but is not one --
  `age` fails to parse it as an identity at all, and a *malformed*
  identity poisons the whole blob `cms sops-key` hands back to `sops`,
  not just the one entry (confirmed: age refuses the lot rather than
  skipping it), breaking a *different*, real-key-dependent scenario
  elsewhere in the same run. A real key age can always parse is safe to
  mix in: unrelated to any given file's recipient, it is simply tried and
  passed over.
  """
  @spec unique_age_private_key!() :: String.t()
  def unique_age_private_key! do
    dir = spex_tmp_dir!("unique-age-key")
    {_pub, priv} = age_keypair!(dir)
    priv
  end

  @doc """
  Encrypts `plaintext` (dotenv format) to `recipient` under `dir`, writing
  it to `name`, and returns the path to the encrypted file.

  `--config /dev/null` keeps this project's own `.sops.yaml` (its real
  recipients) from being consulted for a spec's own throwaway keypair.
  """
  @spec sops_encrypt_dotenv!(Path.t(), String.t(), String.t(), String.t()) :: Path.t()
  def sops_encrypt_dotenv!(dir, name, plaintext, recipient) do
    plain_path = Path.join(dir, "plain-#{name}")
    enc_path = Path.join(dir, name)
    spex_write_file!(plain_path, plaintext)

    {out, 0} =
      run_cmd("sops", [
        "--config",
        "/dev/null",
        "--age",
        recipient,
        "-e",
        "--input-type",
        "dotenv",
        "--output-type",
        "dotenv",
        plain_path
      ])

    spex_write_file!(enc_path, out)
    enc_path
  end

  @doc "Decrypts a dotenv-format sops file, with optional `:env` (e.g. `SOPS_AGE_KEY`, `SOPS_AGE_KEY_CMD`)."
  @spec sops_decrypt_dotenv(Path.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def sops_decrypt_dotenv(enc_path, opts \\ []) do
    env = Keyword.get(opts, :env, [])

    case run_cmd(
           "sops",
           [
             "--config",
             "/dev/null",
             "-d",
             "--input-type",
             "dotenv",
             "--output-type",
             "dotenv",
             enc_path
           ],
           env: env
         ) do
      {out, 0} -> {:ok, out}
      {out, _status} -> {:error, out}
    end
  end

  @doc """
  This project's own `justfile`'s `recipe`'s body, as text, for criterion
  2348 (story 1132) -- there being no project a spec generates here, the
  real justfile on disk is the only one to check.
  """
  @spec justfile_recipe_body(String.t()) :: String.t()
  def justfile_recipe_body(recipe) do
    justfile = spex_read_file_or_blank(Path.join(File.cwd!(), "justfile"))

    case String.split(justfile, ~r/\n#{recipe} \*args:\n/, parts: 2) do
      [_before, after_recipe] ->
        [body | _rest] = String.split(after_recipe, ~r/\n\S/, parts: 2)
        body

      [_only] ->
        ""
    end
  end

  @doc """
  Point `CmsHarness.SopsKeyring.path/0` at a fresh, empty tmp path for the
  rest of this test, restored on exit.

  A "no keyring file was written" assertion against the real default path
  (the dev machine's own `~/.config/sops/age/keys.txt` or OS equivalent)
  would pass or fail on whatever that engineer's own machine happens to
  hold, never on what this test did. Isolating `SOPS_AGE_KEY_FILE` is what
  makes the assertion about this test's own run.
  """
  @spec isolated_sops_keyring_path!() :: Path.t()
  def isolated_sops_keyring_path! do
    previous = System.get_env("SOPS_AGE_KEY_FILE")
    path = Path.join(System.tmp_dir!(), "sops-keyring-spex-#{System.unique_integer([:positive])}")
    System.put_env("SOPS_AGE_KEY_FILE", path)

    ExUnit.Callbacks.on_exit(fn ->
      File.rm(path)

      case previous do
        nil -> System.delete_env("SOPS_AGE_KEY_FILE")
        value -> System.put_env("SOPS_AGE_KEY_FILE", value)
      end
    end)

    path
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
    alias CodeMySpec.Environments

    Environments.put(scope, name, %{ip: ip})
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
    alias CodeMySpec.Environments
    alias CodeMySpec.Servers

    with {:ok, _} <- CodeMySpec.Devices.link_provider_machine(scope, %{name: server_name}),
         %{id: device_id} <- Servers.get_linked(scope, server_name) do
      Environments.put(scope, environment_name, %{device_id: device_id})
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
    alias CodeMySpec.Environments

    Environments.list_deployment(scope)
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
    alias CodeMySpec.Environments
    alias CodeMySpec.Environments.Environment

    # Seed first, so the initial rows exist and can be pruned to the set asked
    # for rather than racing whatever creates them lazily.
    Environments.list_deployment(scope)

    for environment <- CodeMySpec.Repo.all(Environment),
        environment.project_id == project_id,
        environment.name not in names do
      CodeMySpec.Repo.delete!(environment)
    end

    for name <- names, do: Environments.put(scope, name, %{})

    Environments.deployment_names(scope)
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
  A completed full run for `source`, with no commit recorded — the run its
  findings came from. Not a run at HEAD, so it does not certify a promotion.
  """
  def completed_analysis_run(%Scope{} = scope, source) do
    CodeMySpec.AnalysisFixtures.analysis_run_fixture(scope, %{
      source: source,
      status_override: :completed
    })
  end

  @doc """
  Start a full analyzer run, the way a real sweep enqueues one.

  Split from `complete_analysis_run/2` so a scenario can put work between the
  two.
  """
  @spec start_analysis_run(Scope.t(), String.t()) :: CodeMySpec.Analysis.Run.t()
  def start_analysis_run(%Scope{} = scope, source) do
    {:ok, run} =
      RunsRepository.start_run(scope, %{source: source, kind: :full})

    run
  end

  @doc """
  Finish a run through `Reconciler.reconcile/4`, the production path.

  `fresh_analysis_runs/2` stamps the ledger directly, which is right for a
  fixture whose job is "this source has run" and wrong for a criterion about
  what reconciling a run does.
  """
  @spec complete_analysis_run(Scope.t(), CodeMySpec.Analysis.Run.t()) :: :ok
  def complete_analysis_run(%Scope{} = scope, run) do
    {:ok, _finished} =
      Reconciler.reconcile(scope, run, %{
        problems: [],
        output: "",
        exit_status: 0,
        stats: %{}
      })

    :ok
  end

  defp sync_ledger(scope) do
    case WorkingCopies.execution_context(scope) do
      %{type: :harness} ->
        :ok

      _ ->
        {:ok, _} = FileSync.sync(scope, base_dir: scope.cwd)
        :ok
    end
  end

  @doc """
  The scope on `copy_id`, with that copy reading the fixture's in-memory
  runtime (`context.execution_context`) rather than a checkout. For a spex that joins
  a copy and keeps its files in memory.
  """
  @spec in_memory_copy(map(), Ecto.UUID.t()) :: Scope.t()
  def in_memory_copy(%{scope: scope, execution_context: env}, copy_id) do
    :ok = ExecutionContexts.unregister({:working_copy, copy_id})
    :ok = ExecutionContexts.register({:working_copy, copy_id}, env)
    %{scope | active_working_copy_id: copy_id}
  end

  @doc """
  Stamp a completed analysis run per source.

  `tests_passing` / `spex_passing` require a completed run in the analysis
  ledger (v1.5.36) — zero persisted problems no longer reads as "passing" on a
  project whose suites never ran. The latest completed run answers however old
  (28d72f8a).

  `at_head: true` stamps the runs as a harness records them: started on a
  clean tree at the working copy's HEAD and finished there — what the promote
  gate reads (28d72f8a). The copy's root must be a git checkout.

  Syncs first: fingerprints hash the Files table, and fixture-written files
  the stop hook hasn't synced yet would otherwise shift the fingerprint at
  stop time — the stamp would read stale and real analyzers would run
  against the synthetic project.
  """
  def fresh_analysis_runs(
        %Scope{} = scope,
        sources \\ ["compiler", "credo", "exunit", "spex"],
        opts \\ []
      ) do
    # A full sync, not an incremental one, and that is the whole of it.
    #
    # A full sync first, so the files a reader will see are in the ledger
    # before the run is stamped — the way the thing that reads it syncs
    # (criteria 6529, 6532, 6533 were flaky without it while runs carried
    # fingerprints of the file set). A copy served by its harness is kept
    # current by the harness's manifests; the server has no tree to walk.
    :ok = sync_ledger(scope)

    result =
      CodeMySpec.AnalysisFixtures.fresh_analysis_runs_fixture(
        scope,
        sources,
        at_head(scope, opts)
      )

    # Settled before returning, so the graph agrees with the world this fixture
    # has just finished building. Runs are not a graph input, but the sync is.
    #
    # Announcing alone leaves a window: the pass is scheduled, the fixture
    # returns, and whether the scenario's first read sees the finished setup
    # depends on which lands first. That is not a wait — `settle/1` does the
    # pending pass synchronously — and it is the difference between criteria
    # 6529/6533 passing and 6532 failing about one run in four on the same
    # fixture.
    GraphWatcher.settle(scope)

    result
  end

  defp at_head(%Scope{active_working_copy_id: id} = scope, opts) do
    env = WorkingCopies.execution_context(scope)

    if Keyword.get(opts, :at_head, false) do
      {:ok, %{root: root}} = CodeMySpec.WorkingCopies.fetch(id)
      {sha, 0} = ExecutionContexts.cmd(env, "git", ["rev-parse", "HEAD"], cd: root)
      [commit: String.trim(sha)]
    else
      []
    end
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
    {:ok, _} = FileSync.sync(scope, base_dir: scope.cwd)
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
