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
    deps: [CodeMySpec, CodeMySpec.Environments, CodeMySpec.Repo, CodeMySpecTest, CodeMySpecWeb]

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
    ProjectsFixtures,
    ProjectSync,
    QaFixtures,
    SessionsFixtures,
    QaIntegrationPlanFixtures,
    Sessions,
    SetupFixtures,
    Stories,
    TechnicalStrategyFixtures,
    UserPreferences,
    Users,
    UsersFixtures
  }

  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Configurations
  alias CodeMySpec.Requirements.RequirementGraph

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

  defp publish_records(scope, sending_domain, which) do
    alias CodeMySpec.Provisioning.{Cloudflare, Resend}

    zone_name = sending_domain |> String.split(".") |> Enum.take(-2) |> Enum.join(".")

    with {:ok, domain} <- Resend.ensure_domain(scope, sending_domain),
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
      case CodeMySpec.Provisioning.Resend.get_domain(scope, domain_id) do
        {:ok, body} ->
          records = CodeMySpec.Provisioning.Resend.records(body["data"] || body)

          if Enum.any?(records, &(&1["status"] == "verified")) do
            {:halt, :ok}
          else
            if rem(attempt, 5) == 0,
              do: CodeMySpec.Provisioning.Resend.verify_domain(scope, domain_id)

            Process.sleep(3_000)
            {:cont, :ok}
          end

        _ ->
          Process.sleep(3_000)
          {:cont, :ok}
      end
    end)
  end

  defp dkim?(record) do
    String.contains?(String.upcase(to_string(record["record"] || "")), "DKIM") or
      String.contains?(to_string(record["name"] || ""), "_domainkey")
  end

  defp qualify(name, zone) when name in [nil, "", "@"], do: zone
  defp qualify(name, zone), do: "#{name}.#{zone}"

  @doc "The sending domain an environment uses, so spex need not know the rule."
  @spec sending_domain(String.t(), String.t()) :: String.t()
  def sending_domain(base, environment),
    do: CodeMySpec.Provisioning.Resend.sending_domain(base, environment)

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
    with {:ok, created} <- publish_records(scope, sending_domain, :all) do
      # Publishing is not verifying. A `given_` that says "the domain is
      # verified" and only publishes records leaves it pending, and Resend
      # answers 403 to a send from a pending domain — so the spex fails on an
      # assertion about sending for a reason that is entirely about setup.
      #
      # Resend does not re-check on its own either; `poll_until_verified`
      # triggers the check and waits for it.
      case CodeMySpec.Provisioning.Resend.poll_until_verified(scope, created.domain_id, opts) do
        {:ok, _} -> {:ok, created}
        {:error, reason} -> {:error, {:never_verified, sending_domain, reason}}
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
      resolved = CodeMySpec.Provisioning.Dns.lookup_authoritative(name, type) != []
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
      {key, CodeMySpec.Provisioning.Teardown.step(scope, key, opts)}
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
    CodeMySpec.Integrations.IntegrationRepository.upsert_integration(scope, provider, %{
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
    read_model = Keyword.get(opts, :read_model, %CodeMySpec.Files.Scanner.ReadModel{})

    observations =
      scope.environment
      |> CodeMySpec.Files.Scanner.observe(read_model)
      |> Enum.map(&serialize_observation/1)

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
  Report a turn whose recording fails.

  Exercises the recorder directly rather than through the channel: the failure
  under test is the store's, and the channel has no opinion about it.
  """
  def record_turn_with_broken_store(%Scope{} = scope, request, response) do
    CodeMySpec.AgentHarness.ConversationRecorder.record_turn(
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
    to: CodeMySpec.Architecture.SpecStub,
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
  def validate_stop(%Scope{} = scope), do: CodeMySpec.Validation.validate_stop(scope, nil)

  @doc "Files the harness scanned but could classify into no role."
  def unclassified_files(%Scope{} = scope),
    do: CodeMySpec.Files.Scanner.unclassified(scope.environment)

  # -- Project Setup (Story 124) --
  defdelegate satisfy_setup_steps(env, steps), to: SetupFixtures, as: :satisfy
  defdelegate reset_setup_env(env), to: SetupFixtures, as: :reset
  defdelegate setup_steps(), to: AgentTasks.ProjectSetup
  defdelegate step_name(mod), to: AgentTasks.ProjectSetup
  defdelegate find_setup_step(id), to: AgentTasks.ProjectSetup, as: :find_step

  @doc "Returns the stub setup-step module that always errors. Used by Story 124's error-path spex."
  def erroring_setup_step, do: CodeMySpec.SetupFixtures.ErroringStep

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
  production-server round-trip. Wraps `CodeMySpec.Permissions.TapOut.respond/4`.
  """
  @spec respond_to_tap_out(map(), String.t(), String.t(), :approve | :reject) ::
          {:ok, CodeMySpec.Sessions.Session.t()} | {:error, term()}
  def respond_to_tap_out(scope, session_external_id, request_id, decision)
      when decision in [:approve, :reject] do
    session = CodeMySpec.Sessions.get_by_external_id(scope, session_external_id)
    CodeMySpec.Permissions.TapOut.respond(scope, session, request_id, decision)
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
  @spec get_session_by_external_id(Scope.t(), String.t()) :: CodeMySpec.Sessions.Session.t() | nil
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
          {:ok, CodeMySpec.Sessions.Session.t()} | {:error, Ecto.Changeset.t()}
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
          CodeMySpec.Projects.Project.t()
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
  @spec story_fixture(Scope.t(), map()) :: CodeMySpec.Stories.Story.t()
  def story_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        title: "QA Story #{System.unique_integer([:positive])}",
        description: "A story for QA spex testing",
        status: :in_progress
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

  # -- Sessions (QA spex fixture setup, Stories 726/727) --
  @doc """
  Creates an active session with a `qa_complete` task linked to the given
  story. Used by QA spex setup to seed `context.story` and `context.task_id`
  without needing the full requirement prerequisite chain satisfied.

  Returns `{story, task_id, session}`.
  """
  @spec qa_story_task_fixture(Scope.t(), keyword()) ::
          {CodeMySpec.Stories.Story.t(), String.t(), CodeMySpec.Sessions.Session.t()}
  def qa_story_task_fixture(scope, opts \\ []) do
    story =
      case Keyword.fetch(opts, :story) do
        {:ok, existing} ->
          existing

        :error ->
          story_fixture(scope, %{
            title: Keyword.get(opts, :title, "QA Story #{System.unique_integer([:positive])}"),
            description: Keyword.get(opts, :description, "Story for QA testing"),
            status: :in_progress
          })
      end

    task_id = Ecto.UUID.generate()
    session_external_id = "spex-qa-#{System.unique_integer([:positive])}"

    {:ok, session} =
      Sessions.create_session(scope, %{
        external_conversation_id: session_external_id,
        status: :active,
        type: CodeMySpec.AgentTasks.QaStory,
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
  defdelegate spec_file_path(story, criterion), to: BddSpecs

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
    to: CodeMySpec.Analytics.GoogleAnalytics,
    as: :attach_test_subscriber

  defdelegate detach_ga_test_subscriber(pid),
    to: CodeMySpec.Analytics.GoogleAnalytics,
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
      CodeMySpec.Auth.OAuthClient.save_client_user(user.id, user.email, token_data)

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

  @doc """
  Resets the in-process framework-issue stub. Spex setup should call
  this so each scenario starts with an empty server-side capture.
  """
  def reset_framework_issue_stub do
    CodeMySpec.Issues.RemoteClientStub.reset()
  end

  @doc """
  Returns the framework issues captured by the remote stub during this
  test. Lets a `then_` step assert "the framework write reached the
  server surface" through the approved bridge instead of touching the
  stub module directly.
  """
  def captured_framework_issues do
    CodeMySpec.Issues.RemoteClientStub.stored_issues()
  end

  @doc """
  Seeds a server-side incoming issue on the stub. Spex use this to
  prime the "server" before calling `start_task` for `issues_triaged`
  (which triggers the triage-start pull) or `accept_issue` /
  `dismiss_issue` / `resolve_issue` on a server-origin record.
  """
  def seed_server_incoming_issue(scope, attrs) do
    CodeMySpec.Issues.RemoteClientStub.seed_incoming_issue(scope, attrs)
  end

  @doc """
  Toggles the simulated server-unreachable flag on the stub. Set
  `true` before a `when_` step to exercise the fail-loud paths in 599
  (triage start) and 709 (disposition sync-back).
  """
  def simulate_server_unreachable(flag) when is_boolean(flag) do
    CodeMySpec.Issues.RemoteClientStub.simulate_unreachable(flag)
  end

  @doc """
  Returns the recorded `update_issue` calls the stub captured for a
  given issue id. Lets `then_` steps assert "the local disposition
  round-tripped to the server" through the approved bridge.
  """
  def server_update_calls_for(issue_id) when is_binary(issue_id) do
    CodeMySpec.Issues.RemoteClientStub.update_calls_for(issue_id)
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

  @doc "Set and verify a project's sending domain."
  def verify_project_domain(project, domain) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    project
    |> Ecto.Changeset.change(domain: domain, domain_verified_at: now)
    |> CodeMySpec.Repo.update!()
  end

  @doc """
  Record a repository on the project, so setup adopts it rather than prompting.

  The difference between adopting (8179/8184) and stopping to ask (8185) is
  whether the project already points at the repository — this is how a spex
  establishes the "already ours" side of that fork.
  """
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
    CodeMySpec.Provisioning.Steps.put_secret(scope, environment, key, value)
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

  @doc "The repository name setup would use for this project."
  def repository_name(project), do: CodeMySpec.Provisioning.Repository.default_name(project)

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
    with token when is_binary(token) <- System.get_env("GITHUB_SPEX_ADMIN_TOKEN"),
         owner when is_binary(owner) <- System.get_env("GITHUB_SPEX_OWNER") do
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
    case System.get_env("GITHUB_SPEX_ADMIN_TOKEN") do
      token when is_binary(token) and token != "" ->
        # Guarded twice: only names this harness generates, and only through a
        # token whose scope the operator chose. A teardown that could delete an
        # arbitrary repository is worse than a repository left behind.
        if String.starts_with?(name, "spex-") do
          owner = System.get_env("GITHUB_SPEX_OWNER", "johns10")

          Req.delete("https://api.github.com/repos/#{owner}/#{name}",
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
        else
          {:error, {:refused, name}}
        end

      _ ->
        :ok
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
    name = CodeMySpec.Provisioning.Repository.default_name(project)
    owner = System.get_env("GITHUB_SPEX_OWNER", "johns10")
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
      |> CodeMySpec.Mail.Mailbox.changeset(attrs)
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
      |> CodeMySpec.Mail.Email.changeset(email_attrs)
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
    {:ok, _} = CodeMySpec.Files.FileSync.sync_changed(scope, base_dir: scope.cwd)
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
      nil ->
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

      cached ->
        cached
    end
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
        CodeMySpec.Integrations.Integration
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

      scope = %Scope{user: CodeMySpec.Repo.get!(CodeMySpec.Users.User, integration.user_id)}

      case CodeMySpec.Integrations.fetch_access_token(scope, provider) do
        {:ok, access_token} ->
          # Re-read: fetch_access_token may have refreshed, moving expires_at.
          fresh =
            CodeMySpec.Repo.get!(CodeMySpec.Integrations.Integration, integration.id)

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
        case CodeMySpec.Provisioning.Hetzner.list_servers(%CodeMySpec.Users.Scope{}) do
          {:ok, list} -> Enum.map(list, &(&1["name"] || &1[:name]))
          _ -> []
        end

      buckets =
        case CodeMySpec.Provisioning.Storage.list_buckets(credentials, []) do
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
end
