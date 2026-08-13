defmodule CodeMySpecSpex.Case do
  @moduledoc """
  Base case for spex (BDD spec) tests.

  Provides:
  - Phoenix.ConnTest for HTTP assertions
  - Phoenix.LiveViewTest for driving LiveViews
  - SexySpex DSL (spex/scenario/given_/when_/then_)
  - DB sandbox setup
  - Auth helpers via Fixtures (no direct Users context access)

  Specs compose Givens and interact through the Web layer. They cannot
  reach into the app — that's the job of `CodeMySpecSpex.Fixtures`, the
  approved bridge.
  """
  use ExUnit.CaseTemplate

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      @endpoint CodeMySpecLocalWeb.Endpoint

      # `ownership_timeout` was already raised for recording; ExUnit's own test
      # timeout never was, and it is the shorter of the two. Registering a
      # sending domain and waiting for a provider to see its DNS takes minutes
      # against the 60s default.
      #
      # This stayed hidden because every recording found the previous
      # recording's domains still on the account and verified instantly — the
      # residue was doing the waiting. A genuinely clean account timed out all
      # seven criteria, which is the honest cost of the work.
      #
      # Replay keeps the default: nothing is waiting on anything, so a spex
      # that runs long there is hung rather than patient.
      @moduletag timeout: CodeMySpecSpex.Case.spex_timeout()

      use CodeMySpecLocalWeb, :verified_routes
      use SexySpex

      # Half of setup is a subprocess, so `with_full_cassette` — which needs
      # this import — is reachable from every spex rather than from the ones
      # that remembered to ask for it.
      use ExCliVcr

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import CodeMySpecSpex.Case
    end
  end

  @doc """
  How long one criterion may take, given what it is actually waiting on.

  Recording waits on real DNS propagating and a provider re-checking it, which
  is minutes per criterion. Replay waits on nothing and keeps ExUnit's default,
  so a long-running replay reads as hung rather than as patient.
  """
  def recording_ownership_timeout do
    if System.get_env("SPEX_CASSETTE_MODE") == "record",
      do: :timer.minutes(45),
      else: :timer.minutes(15)
  end

  def spex_timeout do
    # Replay is not instant. `await_environment_server/3` alone waits up to 90s
    # by default, so ExUnit's 60s ceiling meant a spex could time out inside a
    # helper it was entitled to call — a failure about the clock, reported as
    # if the criterion were hung. Three minutes clears every helper's own
    # window and still catches something genuinely stuck.
    if System.get_env("SPEX_CASSETTE_MODE") == "record",
      do: :timer.minutes(20),
      else: :timer.minutes(3)
  end

  @doc """
  The workspace runner spex drive instead of Docker.

  Named here rather than referenced directly from a spex: the runner lives in
  the test-support namespace, which spex are not allowed to reach into, and
  Docker is an external system the criteria are not about.
  """
  def workspace_runner, do: CodeMySpecTest.FakeWorkspaceRunner

  setup tags do
    # `ownership_timeout` has to outlast the work, not the request. Recording a
    # spex waits on a provider verifying DNS — minutes, not milliseconds — and
    # the default reclaimed the connection mid-poll, so the LiveView came back
    # to a sandbox that no longer had an owner. The error names process
    # ownership and says nothing about the wait that caused it.
    #
    # Fifteen minutes was enough while recordings finished in four, which they
    # only did because the previous run's sending domains were still on the
    # account and verified instantly. Against a clean account a 969 recording
    # runs about eighteen, and the connection was being reclaimed during
    # `on_exit` — so teardown could not read what it was meant to remove and
    # left real DNS records and sending domains behind. A teardown that cannot
    # reach the database is the one failure that costs money, so this is
    # generous on purpose.
    pid =
      Sandbox.start_owner!(CodeMySpec.Repo,
        shared: not tags[:async],
        ownership_timeout: tags[:ownership_timeout] || recording_ownership_timeout()
      )

    on_exit(fn -> Sandbox.stop_owner(pid) end)

    # DNS resolution cannot live in a cassette — the authoritative lookup is a
    # syscall, and it has to stay authoritative because a recursive resolver
    # caches the absence of a just-published record for the zone's negative
    # TTL. Recording writes the real answer down; replaying reads it back, so a
    # spex stops asking the world about records it has already torn down.
    Application.put_env(:code_my_spec, :dns_resolver, Fixtures.dns_resolver(cassette_mode()))
    on_exit(fn -> Application.delete_env(:code_my_spec, :dns_resolver) end)

    # Repositories go to the throwaway organisation when one is configured, so
    # a recording never creates anything in somebody's personal account. The
    # step already supports this (`:org` to create there, `:owner` to look for
    # an existing one); it only needed telling.
    if owner = spex_owner() do
      previous_step_opts = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

      Application.put_env(
        :code_my_spec,
        :provisioning_step_opts,
        Keyword.merge(previous_step_opts, org: owner, owner: owner)
      )

      on_exit(fn ->
        Application.put_env(:code_my_spec, :provisioning_step_opts, previous_step_opts)
      end)
    end

    stage_local_only_push()

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that connects every provider the setup sequence uses.

      setup :connect_providers

  Steps look up a credential before they make a request, so a scope with no
  connection fails with "GitHub is not connected" long before the cassette is
  consulted — the spex then proves the disconnected path, whatever it says it
  is testing. Stories that mean to test a revoked credential call
  `Fixtures.disconnect_provider/2` explicitly, which now reads as the
  deliberate act it is.
  """
  def connect_providers(%{scope: scope} = context) do
    refuse_to_run_on_residue()

    start_cassette_session()

    # The provider plug is put back here, not only by `with_provider_cassette`.
    #
    # That function restores in an `after`, which does not run when the test
    # process is killed by an exit signal rather than an exception — a LiveView
    # crashing inside a cassette block takes the linked test process down
    # without unwinding anything. The plug then stays installed for the rest of
    # the VM, and every later spex that reaches a provider *outside* a cassette
    # gets that dead cassette instead of its own.
    #
    # Which is not a hypothetical: 972's criterion 8034 died that way on a
    # missing cassette, and 973's 8040 and 974's 8032 were then both reported
    # failing for `content_publish_single_command` — a cassette neither of them
    # names. Their own failures were real and correctly attributed; only the
    # reason was another spex's, and the spex responsible was invisible because
    # a process killed by a signal never reports one either.
    #
    # `on_exit` runs in its own process and fires however the test ended, so it
    # gives the guarantee `after` cannot. It is registered before any step runs,
    # and callbacks fire last-registered-first, so a `tear_down_after` cassette
    # still opens and closes normally before this resets everything.
    pristine_providers =
      Enum.map(provider_modules(), &{&1, Application.get_env(:code_my_spec, &1, [])})

    on_exit(fn ->
      for {module, config} <- pristine_providers,
          do: Application.put_env(:code_my_spec, module, config)
    end)

    # Nothing is really happening on replay, so there is nothing to wait for.
    # The pollers still ran their sleeps between replayed reads, which is where
    # a passing criterion's five and a half minutes went.
    Application.put_env(
      :code_my_spec,
      :provisioning_waits,
      if(recording?(), do: :real, else: :none)
    )

    # Recording waits longer before its first read of the inbox.
    #
    # The inbound teardown removes the MX it published, so the next recording
    # republishes it and mail does not route until that propagates. The default
    # 60s settle plus 60 polls is about six minutes, which is under it: three
    # recordings in a row polled to exhaustion against a domain that was
    # verified, receiving-enabled, and whose MX resolved by the time I checked.
    # The one that succeeded in 77s did so because a previous run's MX was
    # still live.
    #
    # Five minutes before the first read, so a cold domain has time and a warm
    # one costs only the wait. Replay is unaffected — `:provisioning_waits` is
    # `:none` there, so `Wait.sleep/1` is a no-op and the request count is
    # identical either way.
    if recording?() do
      previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

      Application.put_env(
        :code_my_spec,
        :provisioning_step_opts,
        Keyword.put_new(previous, :settle_ms, :timer.minutes(5))
      )

      on_exit(fn ->
        Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
      end)
    end

    refuse_recording_into_a_personal_account()

    for provider <- [:github, :cloudflare, :resend] do
      grant = live_grant(provider)

      Fixtures.connect_provider(scope, provider,
        access_token: grant.access_token,
        refresh_token: grant.refresh_token,
        expires_at: grant.expires_at
      )
    end

    context
  end

  # Real when recording, placeholder otherwise. A placeholder is correct for
  # replay — the HTTP never leaves — but recording with one produces a
  # cassette full of 401s, which replays perfectly and proves nothing.
  #
  # ## Why this reads the dev database rather than an env var
  #
  # Cloudflare and Resend rotate the refresh token on **every** use and revoke
  # the grant when a spent one is presented. A `CMS_*_TOKEN` env var is a
  # *second copy* of a single-use credential: the app refreshes, the stored
  # token rotates, and the exported copy is now spent — so the next recording
  # run presents a dead token and the provider revokes the whole grant. That is
  # what forced a manual reconnect between recording sessions. It was never the
  # refresh logic failing; it was two owners of one rotating secret.
  #
  # So there is exactly one owner: the integration row. `fetch_access_token/2`
  # refreshes under a row lock and persists the rotation, and recording borrows
  # the result rather than keeping its own copy. Nothing to export, nothing to
  # go stale. Same code path the running app uses, which is also the point.
  #
  # `connect_providers/1` reads each grant once and spreads it across the three
  # fields, so this is one query per provider per spex, not three.

  # The grant deliberately does NOT carry its refresh token: a credential that
  # rotates on every use gets exactly one owner, and that is the dev row. So the
  # copy handed to a spex cannot renew itself, and Resend's access token lives
  # about fifteen minutes while a full recording takes longer than that.
  #
  # `live_provider_grant/1` re-reads from dev when the snapshot nears expiry,
  # which is what keeps a long recording alive without ever making a second
  # owner of the refresh token. This comment used to claim the copy carried one;
  # it never did, and the run died at `:reauthorize_required` looking like a
  # revoked grant.
  #
  # The connected grant from the dev database, read through a short-lived
  # connection of its own: the spex sandbox owns `CodeMySpec.Repo` and points at
  # the test database, which has no integrations in it.
  #
  # Only consulted while recording. On replay the HTTP never leaves the box, so
  # placeholders are not merely adequate, they are correct — a replay that
  # depended on a live credential would fail on a machine that has none.
  # Refuse to record when the throwaway organisation is not configured.
  #
  # `Repository.ensure/3` asks GitHub who the token is when no `:owner` was
  # supplied, and the Case supplies one only when `GITHUB_SPEX_OWNER` is in
  # `System.get_env/1`. That variable lives in `envs/.env`, which Dotenvy loads
  # into config and never into the process environment — so unless the operator
  # exported it by hand, recording quietly creates repositories in whoever's
  # personal account the grant belongs to.
  #
  # It is not hypothetical: a drill created `johns10/spex-story972-criterion8039`
  # in a personal account this way, and nothing could delete it afterwards
  # because the app's grant has no `delete_repo` scope by design and the admin
  # token had expired. Silence was the whole problem — the run looked like it
  # was doing the right thing.
  #
  # Replay is unaffected; it creates nothing.
  # Do every local git operation, and skip the one that talks to GitHub.
  #
  # `git` is a subprocess rather than HTTP, so no cassette intercepts it. A
  # replay therefore pushed to a repository that existed only while the
  # recording was being made, and whether that succeeded depended on whether the
  # repository still happened to be there — the app's grant has no
  # `delete_repo` scope by design, so some survive and some do not. The same
  # criterion passed or failed by the age of its cassette, reporting
  # `remote: Repository not found`, which reads as a defect in the step.
  #
  # The push is also the part with nothing to prove here: it is slow, it needs
  # the network, and no criterion in this suite asserts anything about GitHub
  # having received the objects. The repository is still created, the commit is
  # still made, the remote is still set, and the recorded sha is the real one.
  defp stage_local_only_push do
    previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

    Application.put_env(
      :code_my_spec,
      :provisioning_step_opts,
      Keyword.merge(previous, push_remote: false)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
    end)
  end

  # The throwaway organisation every spex repository belongs in.
  #
  # Defaulted rather than read from the environment alone, because whether this
  # is set changes the *shape of the run*, not just where a repository lands.
  # `Repository.ensure/3` asks GitHub who the token is — `GET /user` — only when
  # no `:owner` was supplied. Recording always supplies one, because
  # `refuse_recording_into_a_personal_account/0` will not let a recording start
  # without it. So no cassette contains that request.
  #
  # A replay on a machine that had not exported the variable therefore made a
  # request no recording holds, missed, and errored the repository step — the
  # first step of the run. Everything after it never ran, which is how a
  # perfectly good cassette produced "14 step(s) have nothing behind them" with
  # `server` among the missing, and sent three separate investigations after
  # provider capacity, an inventory bug and a placement fallback.
  #
  # The value lives in `envs/.env`, which Dotenvy loads into config and never
  # into the process environment, so it is absent unless someone exported it by
  # hand — meaning the cassettes replayed only on the machine that recorded
  # them. The environment still wins when it is set; this only stops the shape
  # of a replay from depending on a shell.
  @spex_owner "codemy-my-spec-test"

  defp spex_owner do
    case System.get_env("GITHUB_SPEX_OWNER") do
      owner when is_binary(owner) and owner != "" -> owner
      _ -> @spex_owner
    end
  end

  # A credential a *recording* actually needs, or a refusal that arrives before
  # the first provider call.
  #
  # `System.get_env(var, "spex-placeholder-…")` is exactly right on replay and
  # catastrophic on record: the recording proceeds with the literal placeholder,
  # every provider answers 401, and the cassette is poisoned. `refuse_poisoned_cassette/1`
  # does catch that — afterwards, keeping a `.rejected` file — but for the mail and
  # setup criteria "afterwards" is minutes to tens of minutes of real calls, and the
  # cause is only visible to someone who knows to read the rejected cassette
  # (deac6edf).
  #
  # Checked here rather than up front with `GITHUB_SPEX_OWNER`, deliberately.
  # A single pre-flight demanding every provider's credentials would refuse a
  # GitHub-only recording for the want of a Hetzner key it never uses. This
  # fires only where a credential is genuinely about to be spent, so it cannot
  # turn a valid recording away.
  #
  # The export incantation is repeated rather than referenced because this is
  # the failure where knowing *that* envs/.env exists does not help: Dotenvy
  # loads it into config for `env!/2` and never into the process environment,
  # so the file can be correct and the child still sees nothing.
  defp recording_credential(var, placeholder) do
    value = System.get_env(var)

    cond do
      not recording?() ->
        value || placeholder

      value in [nil, ""] ->
        raise """
        Refusing to record: #{var} is not set.

        This recording is about to spend real provider calls, and without this
        it would send "#{placeholder}" — so every request answers 401 and the
        cassette is poisoned. You would find out after the recording, from the
        .rejected file.

        It is in envs/.env, which Dotenvy loads into config rather than the
        process environment, so it has to be exported:

            set -a; source envs/.env; set +a
        """

      true ->
        value
    end
  end

  defp refuse_recording_into_a_personal_account do
    if recording?() and System.get_env("GITHUB_SPEX_OWNER") in [nil, ""] do
      raise """
      Refusing to record: GITHUB_SPEX_OWNER is not set.

      Recording creates real repositories. Without this, they land in the
      personal account behind the GitHub grant instead of the throwaway
      organisation, and the app cannot delete them afterwards.

      It is in envs/.env, which Dotenvy loads into config rather than the
      process environment, so it has to be exported:

          set -a; source envs/.env; set +a
      """
    end
  end

  defp live_grant(provider) do
    if recording?() do
      fetch_live_grant(provider)
    else
      %{
        access_token: "spex-placeholder-token",
        refresh_token: "spex-placeholder-refresh",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }
    end
  end

  defp fetch_live_grant(provider), do: Fixtures.live_provider_grant(provider)

  # Answer the TLS step's HTTPS probe without a deployed application.
  #
  # stage_certificate(context)
  #
  # The TLS step proves a certificate the only honest way — an HTTPS request that
  # a bad certificate would fail. That needs something serving HTTPS on the host,
  # which means a deployed app; a freshly provisioned box serves nothing, so the
  # step errors for a reason that has nothing to do with the certificate.
  #
  # Whether a real deploy gets a real certificate is story 966's claim and is
  # proved there. What is left here — and is genuinely proved, against real
  # Cloudflare data — is that the records setup writes are **unproxied**, so the
  # HTTP-01 challenge reaches the origin rather than terminating at Cloudflare.
  # That is the part the records decide, and the part this criterion is about.
  # Point the backup script at a database that really exists.
  #
  # setup :real_backup_database
  #
  # A backup criterion cannot be proved against a stub: the claim is that a dump
  # restores with rows in it, and only a real `pg_dump`/`psql` round-trip can say
  # so. On a provisioned box `bin/backup` reads `DATABASE_URL` out of the app's
  # encrypted env file; here there is no such box, so the test database — which is
  # a real Postgres with real tables — stands in for it.
  # A criterion whose premise is "this resource exists" has to be the thing that
  # creates it. When a previous run crashed before `on_exit`, the resource is
  # still there and the criterion passes without ever having created it —
  # silently, and only until someone runs the suite against a clean account.
  #
  # So a run that starts on residue stops instead, naming what it found. Not
  # deleted automatically: a recording may be in flight, and deleting somebody
  # else's live resource is worse than refusing to start.
  #
  # Once per BEAM — the check costs a provider round trip and the answer cannot
  # change while the suite that would change it is the one asking.
  defp refuse_to_run_on_residue do
    case :persistent_term.get({__MODULE__, :residue_checked}, nil) do
      nil ->
        :persistent_term.put({__MODULE__, :residue_checked}, true)
        leaked = Fixtures.leaked_spex_resources()

        if leaked != [] do
          raise """
          this account already holds spex resources from an earlier run:

            #{Enum.join(leaked, "\n  ")}

          A criterion whose premise is "this exists" would pass on them without
          creating anything. Clear them first:

            MIX_ENV=test mix cms.provisioning_leaks --delete
          """
        end

      _ ->
        :ok
    end
  end

  @doc """
  Drive a run from a script instead of from providers.

      setup {:scripted_run, %{domain: {:error, "Cloudflare said no"}}}

  Story 963's criteria are claims about the **runner**: a failing step halts
  the rest, a re-run picks up where it stopped, retrying one step leaves the
  others alone, an option turned off never appears. None of them are claims
  about Hetzner or Cloudflare, and proving them through real providers made
  each one mint a server and a repository, need a cassette per outcome, and
  fail for reasons that had nothing to do with the ordering under test.

  `Provisioning.run_step/3` already takes `:verify` and `:execute` for exactly
  this. Scripting them makes the failure modes the criteria are *about* —
  errored, paused, a provider's own message — reachable directly, and reachable
  reliably, instead of being coaxed out of a real provider that would rather
  succeed.

  Steps not named in the script succeed with no resources. `:verify` is
  scripted too: without it, the run asks providers whether each step is already
  satisfied and short-circuits past the very step the criterion wants to watch.
  """
  def scripted_run(context, script \\ %{}) do
    Fixtures.store_provider_secrets(context.scope)

    previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

    Application.put_env(
      :code_my_spec,
      :provisioning_step_opts,
      Keyword.merge(previous,
        verify: fn _scope, _key -> {:ok, :absent} end,
        execute: fn _scope, key, _opts ->
          case Map.get(script, key, {:ok, []}) do
            # A zero-arity function so a criterion can hold a step open.
            # Scripted steps finish instantly, which makes "Sam sees a step
            # running" unobservable — the state the criterion is about would
            # be gone before the page could show it.
            fun when is_function(fun, 0) -> fun.()
            outcome -> outcome
          end
        end
      )
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
    end)

    context
  end

  @doc """
  Run setup in a task, so the page has states to show while it runs.

      setup :watchable_run

  Runs are synchronous under test on purpose — a detached task races the
  test's lifetime, and the run then holds a sandbox connection nobody owns.
  The cost is that every intermediate state is gone by the time the click
  returns, so a criterion about *watching* a step change has nothing to watch.

  Safe here because spex own their sandbox in shared mode, so the spawned run
  uses the same connection rather than a detached one. Pair it with a script
  that holds a step open, or the run still finishes faster than the page can
  be read.
  """
  def watchable_run(context) do
    previous = Application.get_env(:code_my_spec, :provisioning_run_async, true)
    Application.put_env(:code_my_spec, :provisioning_run_async, true)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_run_async, previous)
    end)

    context
  end

  @doc """
  Wait until a step reaches a state, then hand back the page.

  A run is asynchronous, so a criterion that renders immediately after
  clicking reads the page before anything has happened, and one that waits for
  the whole run to settle has missed every intermediate state. This waits for
  the one transition the criterion is about.
  """
  def await_step_state(view, step, state, timeout \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_step_state(view, step, state, deadline, nil)
  end

  defp await_step_state(view, step, state, deadline, _last) do
    html = Phoenix.LiveViewTest.render(view)

    cond do
      html =~ ~r/data-step="#{step}"[^>]*data-state="#{state}"/ ->
        html

      System.monotonic_time(:millisecond) > deadline ->
        html

      true ->
        Process.sleep(100)
        await_step_state(view, step, state, deadline, nil)
    end
  end

  @doc """
  Advance the clock the backup health check reads, by several nights.

      setup :several_nights_later

  A criterion about backups that stopped landing needs dumps that are old.
  S3 sets `last_modified` itself, so a dump cannot be backdated and the only
  honest lever is the other side of the comparison: ask whether backups are
  current *later*, which is exactly what "the scheduled dump has failed for
  several nights" means.
  """
  def several_nights_later(context) do
    previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

    Application.put_env(
      :code_my_spec,
      :provisioning_step_opts,
      Keyword.put(previous, :now, fn -> DateTime.add(DateTime.utc_now(), 5, :day) end)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
    end)

    context
  end

  def real_backup_database(context) do
    url = Fixtures.database_url()

    previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

    Application.put_env(
      :code_my_spec,
      :provisioning_step_opts,
      Keyword.put(previous, :database_url, url)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
    end)

    context
  end

  def stage_certificate(context) do
    previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

    Application.put_env(
      :code_my_spec,
      :provisioning_step_opts,
      Keyword.put(previous, :probe, fn _host, _opts -> :ok end)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
    end)

    context
  end

  @doc """
  Print each step's state and reason, when `SPEX_DRILL_TRACE` is set.

  A halted provisioning sequence says nothing about itself. A step that refuses
  goes from `not_started` to `not_started`, and the run reads as though it
  never happened — three drills were spent working out that the sequence was
  reaching `deploy` at all.

  Reads `boot-failure` and `paused-instructions` alongside `escalation`,
  because the deploy step's provider error lives only in the first of those
  (they were printing the same sentence twice) and a pause is not an error at
  all. Looking at `escalation` alone shows a blank reason for both.

  Lives here rather than in the spex: a branch inside a `_spex.exs` is a test
  reacting to state it should control, and credo rejects it — rightly. This is
  scaffolding for a drill, not part of any criterion.
  """
  def trace_steps(view, keys) do
    case System.get_env("SPEX_DRILL_TRACE") do
      nil -> :ok
      "" -> :ok
      _ -> print_step_trace(view, keys)
    end
  end

  # Which slice of a long message to show.
  #
  # Neither end is right for a failing `docker build`. The head is the layers
  # that succeeded; the tail is layer-download progress, which is where a build
  # spends most of its output — 600 characters of
  # `sha256:0954… 26.21MB / 44.57MB` and not one word about what broke.
  #
  # buildkit puts the reason on a line starting `ERROR:`, so when there is one,
  # show that and what follows it. Falling back to the tail otherwise, since a
  # step that failed without buildkit usually ends with its reason.
  @trace_width 1_200

  defp interesting(message) do
    # A crashed container first, because its exception is the diagnosis and
    # everything after it is consequence. kamal reports the container dying as
    # `target failed to become healthy within configured timeout`, which lands
    # at the very end and so wins the tail every time — while the `** (…)` that
    # says *why* it died sits thousands of characters earlier and gets cut off.
    # A deploy spent a whole cloud cycle reporting a timeout for an app that
    # was raising at boot.
    crashed(message, String.contains?(message, "** ("))
  end

  defp crashed(message, true) do
    message
    |> String.split(~r/(?=\*\* \()/)
    |> Enum.filter(&String.starts_with?(&1, "** ("))
    |> List.last()
    |> String.slice(0, @trace_width)
  end

  defp crashed(message, false) do
    shown = tail(message)

    # The tail is usually right — an error is at the end of what produced it —
    # and it carries the context the error alone does not. `mix assets.deploy`
    # failing says only "exit code: 1"; what it printed beforehand says why.
    #
    # The ERROR line is the fallback, for a message long enough that the tail
    # misses it. That was the common case while `inspect/1` was truncating the
    # log, and became the rare one once it stopped.
    if String.contains?(shown, "ERROR") or not String.contains?(message, "ERROR") do
      shown
    else
      message
      |> String.split(~r/(?=ERROR)/)
      |> Enum.filter(&String.starts_with?(&1, "ERROR"))
      |> List.last()
      |> String.slice(0, @trace_width)
    end
  end

  defp tail(message) do
    if String.length(message) > @trace_width do
      "…" <> String.slice(message, -@trace_width, @trace_width)
    else
      message
    end
  end

  defp print_step_trace(view, keys) do
    doc = view |> Phoenix.LiveViewTest.render() |> Floki.parse_document!()

    for key <- keys do
      step = Floki.find(doc, "[data-test='setup-step'][data-step='#{key}']")
      state = step |> Floki.attribute("data-state") |> List.first()

      named =
        step
        |> Floki.find(
          "[data-test='escalation'], [data-test='boot-failure'], [data-test='paused-instructions']"
        )
        |> Floki.text()

      # Fall back to the step's whole text when none of those carry anything.
      # A step that reads `errored` and explains itself nowhere is the drill's
      # most common failure — six of the first eight — and a trace that only
      # reads the selectors it expects reproduces the same blindness.
      why = if String.trim(named) == "", do: Floki.text(step), else: named

      why = why |> String.replace(~r/\s+/, " ") |> String.trim()

      IO.puts("STEP #{String.pad_trailing(to_string(key), 11)} #{state}  #{interesting(why)}")
    end

    :ok
  end

  @doc """
  Run the box-side steps against the local fleet rather than a recorded address.

  The registry and database steps shell docker commands over SSH to the server
  the run just created. On replay that address comes out of the cassette, and it
  stopped being ours weeks ago — so the step reached a stranger's machine, waited
  out the connect timeout, and failed. `serve_registries/5` halts on the first
  error, so nothing downstream recorded a resource and setup reported every step
  from `server` onward as having nothing behind it. That is story 841's 1961,
  1967 and 1969, all three of which have clean cassettes with both servers
  created.

  Needs the fleet up:

      docker/fleet/fleet.sh up

  Deliberately raises rather than skipping when it is not. A criterion that
  quietly passed without running the commands it is about would be the same
  failure this whole exercise has been chasing — something green that never ran.
  """
  def fleet_box(%{scope: scope} = context) do
    key = Path.expand("docker/fleet/keys/fleet", File.cwd!())

    File.exists?(key) ||
      raise """
      No fleet key at #{key}.

      This criterion runs the registry and database steps for real, against the
      local fleet's app box. Bring it up with:

          docker/fleet/fleet.sh up
      """

    previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

    Application.put_env(
      :code_my_spec,
      :provisioning_step_opts,
      Keyword.merge(previous,
        run: Fixtures.fleet_runner(scope.environment, ssh_key_path: key),
        # The fleet box carries no private network address, so the registry
        # publishes on loopback there. `serve_one_registry/5` uses `put_new`,
        # which is what lets this stand.
        bind: "127.0.0.1"
      )
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
    end)

    context
  end

  @doc """
  Generate a fresh application with `mix cms.new` and point the project at it.

  `setup_active_project` makes a stub directory holding a `mix.exs`, which is
  enough for the working-dir plug and nothing else. The deploy step runs
  `bin/deploy migrate <environment>` from the project's `cwd`, so against a
  stub there is no script to run and the step fails for a reason that has
  nothing to do with deploying.

  ## Generated, not kept

  This used to point at `code_my_spec_test_repos/devops_drill_v2`, one checkout
  reused by every run. That deployed a months-old snapshot of the generator's
  output rather than exercising the generator, so the first two thirds of what
  these criteria claim — that `cms.new` produces a deployable application, and
  that the other generators leave it deployable — was never run at all.

  It also manufactured failures that only existed because the checkout
  persisted. The deploy step commits the run's own `.sops.yaml` and
  `envs/*.enc.env`, because the builder is sent `git archive HEAD` and cannot
  see anything uncommitted; six such commits accumulated, each carrying secrets
  encrypted to an age key held by a project row the next run did not have, and
  a later run met `no identity matched any of the recipients` at the server
  step. A whole reset mechanism existed to undo that. Generating fresh deletes
  the class outright.

  Generation costs 0.4s. There was never a reason to reuse one.

  ## What gets generated

  Recording runs the whole chain — `cms.new`, then `mix deps.get`, then the
  `cms_gen.*` generators a real project gets — because that chain is the
  subject. Replay generates the skeleton only: the cassette answers every
  command, so the dependencies would be fetched to satisfy nobody, and the
  minute-plus it costs would be paid by every sweep in every checkout.

  ## Where the generator lives

  `CMS_NEW` names the `cms_new` checkout. Without it the usual sibling
  locations are tried, and a clear refusal beats generating something subtly
  different from what a customer gets.
  """
  def drill_working_directory(%{scope: scope, project: project} = context) do
    path = generate_application(project)

    {:ok, project} = Fixtures.set_project_local_path(project, path)

    context
    |> Map.put(:project, project)
    |> Map.put(:scope, %{scope | active_project: project})
    |> real_working_directory()
  end

  # A name the generator accepts and the provider resources can carry: lowercase
  # letters, digits and underscores, starting with a letter.
  defp generated_app_name(project) do
    "cms_drill_" <> (project.id |> to_string() |> String.replace(~r/[^0-9a-z]/, ""))
  end

  # The generators a real project gets, in the order a project gets them.
  # `cms.new` emits the application; these emit what it is *for*.
  #
  # `phx.gen.auth` first, and not optional: `cms_gen.accounts` builds on the
  # scope module it writes and refuses without it —
  #
  #   ** (Mix) It looks like mix phx.gen.auth has not been run yet.
  #   The following expected files are missing:
  #     * lib/<app>/users/scope.ex
  #
  # `--live` rather than leaving it to the prompt, because a generator asking a
  # question of a process with no terminal is a hang, not a default.
  @project_generators [
    # `Users`, not `Accounts`: `cms_gen.accounts` looks for
    # `lib/<app>/users/scope.ex` and phx.gen.auth writes the scope under the
    # context it is given, so the wrong context leaves it reporting that
    # phx.gen.auth "has not been run yet" after a run that succeeded.
    ["phx.gen.auth", "Users", "User", "users", "--live"],
    # `phx.gen.auth` adds `bcrypt_elixir` to mix.exs and offers to fetch it
    # behind a prompt, which a process with no terminal never answers — so the
    # next generator met "the dependency is not available, run mix deps.get".
    ["deps.get"],
    ["cms_gen.accounts"],
    ["cms_gen.content"],
    ["cms_gen.support_widget"]
  ]

  defp generate_application(project) do
    {:ok, parent} = Briefly.create(directory: true)
    name = generated_app_name(project)
    path = Path.join(parent, name)

    cms_new = cms_new_path()
    generate(cms_new, path, name)
    pin_toolchain(cms_new, path)

    # Only while recording. The generators need the dependencies, and the
    # dependencies are minutes that replay has no use for.
    if recording?() do
      mix_in(path, ["deps.get"])
      for args <- @project_generators, do: mix_in(path, args)
    end

    commit_generated_application(path)

    path
  end

  # What a child `mix` must not inherit from the one running this suite.
  #
  # `nil` removes the variable. MIX_ENV is the obvious one — the suite runs
  # under `test` and the generator would inherit it — but MIX_BUILD_PATH is the
  # dangerous one: the analyzer sets it to its own tree, and a generated
  # application compiling into `_build/analyzer` corrupts the suite the
  # analyzer is running. MIX_TEST_PARTITION for the same reason one directory
  # over.
  #
  # Written out rather than borrowed from `CodeMySpec.Environments`, which
  # `CodeMySpecSpex` may not reach into.
  @child_mix_env [
    {"MIX_ENV", "dev"},
    {"MIX_BUILD_PATH", nil},
    {"MIX_BUILD_ROOT", nil},
    {"MIX_DEPS_PATH", nil},
    {"MIX_TARGET", nil},
    {"MIX_TEST_PARTITION", nil},
    {"ERL_LIBS", nil}
  ]

  # Let the child pick its own Elixir, rather than inheriting this suite's.
  #
  # asdf's shim resolves a version from the working directory and then puts
  # *that version's* bin directory on PATH for what it runs. Everything the
  # suite spawns therefore inherits a PATH naming Elixir 1.19.4 outright, with
  # the shims behind it — so a child `mix` in `cms_new`, which pins 1.20.2,
  # still ran on 1.19.4 and the generator refused itself:
  #
  #   ** (Mix) You're trying to run :cms_new on Elixir v1.19.4 but it has
  #   declared in its mix.exs file it supports only Elixir ~> 1.20
  #
  # Which reads as a constraint someone should relax and is really two
  # checkouts on two Elixirs with the shim bypassed. Putting the shims back in
  # front restores per-directory resolution. Measured, same call, same `cd`:
  # inherited PATH gives Mix 1.19.4, shims-first gives Mix 1.20.2.
  #
  # `PWD` too, since `cd:` moves the process and not the variable, and some
  # resolvers read the variable.
  defp child_mix_env(dir) do
    shims = Path.expand("~/.asdf/shims")

    path =
      case File.dir?(shims) do
        true -> [{"PATH", shims <> ":" <> (System.get_env("PATH") || "")}]
        false -> []
      end

    path ++ [{"PWD", dir} | @child_mix_env]
  end

  # Build the generated application on the toolchain its generator targets.
  #
  # `cms.new` emits a `mix.exs` requiring `elixir: "~> 1.20"` and no toolchain
  # pin, so on a machine whose global asdf version is older — this one's is
  # 1.19.4 — a freshly generated application cannot run its own `mix deps.get`.
  # Copying the generator's pin is what a drill wants: the application is built
  # the way the generator was built for.
  #
  # Whether `cms.new` should emit this itself is a real question and not one to
  # answer here. Pinning users to this machine's exact Erlang would be wrong;
  # shipping no pin at all with a `~> 1.20` requirement is what produced this.
  defp pin_toolchain(cms_new, path) do
    source = Path.join(cms_new, ".tool-versions")
    if File.exists?(source), do: File.cp!(source, Path.join(path, ".tool-versions"))
    :ok
  end

  defp generate(cms_new, path, name) do
    case System.cmd("mix", ["cms.new", path, "--app", name, "--no-install"],
           cd: cms_new,
           stderr_to_stdout: true,
           env: child_mix_env(cms_new)
         ) do
      {_, 0} ->
        :ok

      {output, status} ->
        raise "mix cms.new failed (#{status}) in #{cms_new}:\n\n#{output}"
    end
  end

  defp mix_in(path, args) do
    case System.cmd("mix", args,
           cd: path,
           stderr_to_stdout: true,
           env: child_mix_env(path)
         ) do
      {_, 0} ->
        :ok

      {output, status} ->
        raise "mix #{Enum.join(args, " ")} failed (#{status}) in #{path}:\n\n#{output}"
    end
  end

  # The builder is sent `git archive HEAD`, so an application that is generated
  # and not committed ships nothing at all.
  #
  # `add -A` is right here and nowhere else in this repository: the tree was
  # made seconds ago by a generator and every file in it is intended.
  defp commit_generated_application(path) do
    git = fn args -> System.cmd("git", args, cd: path, stderr_to_stdout: true) end

    git.(["init", "-q", "-b", "main"])
    git.(["add", "-A"])

    git.([
      "-c",
      "user.email=setup@codemyspec.com",
      "-c",
      "user.name=CodeMySpec Setup",
      "commit",
      "-q",
      "-m",
      "Generated by mix cms.new"
    ])

    :ok
  end

  defp cms_new_path do
    candidates =
      [System.get_env("CMS_NEW")] ++
        Enum.map(
          ["../cms_new", "../../cms_new", "../../../cms_new", "../../../../cms_new"],
          &Path.expand(&1, File.cwd!())
        )

    Enum.find(candidates, &(is_binary(&1) and File.exists?(Path.join(&1 || "", "mix.exs")))) ||
      raise """
      Cannot find the `cms_new` checkout, so there is nothing to generate with.

      These criteria deploy an application produced by `mix cms.new` — that is
      the subject, not a fixture. Set CMS_NEW to the checkout.

      Tried:
      #{Enum.map_join(Enum.reject(candidates, &is_nil/1), "\n", &("  " <> &1))}
      """
  end


  @doc """
  What a setup step reported, for a failure message that would otherwise name
  only the expectation.

  "expected the server step to be done" says what was wanted and nothing about
  what happened, which has cost several rounds of guessing on this suite.
  """
  @spec step_detail(String.t(), String.t() | atom()) :: String.t()
  def step_detail(html, key) do
    step =
      html
      |> Floki.parse_document!()
      |> Floki.find("[data-test='setup-step'][data-step='#{key}']")

    state = step |> Floki.attribute("data-state") |> List.first()
    detail = step |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.slice(0, 300)

    "#{key} step state=#{inspect(state)} detail=#{inspect(detail)}"
  end

  @doc """
  The address an inbound probe should be sent to, or `nil` for the default.

  Resend delivers only to addresses configured for a domain and drops anything
  else in silence, which is why `steps.ex` insists the address is given rather
  than invented. The fixture user's email has a random local part, so on a
  freshly created domain the probe is always sent somewhere that does not
  exist — 8048 sends, gets a message id, and waits out sixty polls for mail
  that was discarded on arrival.

  `RESEND_SPEX_INBOX` names a permanently verified receiving domain with a
  catch-all (e.g. `probe@spex-inbound.astralbi.com`). Unset, criteria keep
  today's behaviour, so nothing changes until the domain exists.
  """
  @spec probe_inbox() :: String.t() | nil
  def probe_inbox do
    case System.get_env("RESEND_SPEX_INBOX") do
      address when is_binary(address) and address != "" -> address
      _ -> nil
    end
  end

  @doc """
  Click the inbound probe, addressed to `probe_inbox/0` when one is configured.

  The form already accepts a `to`, so this needs nothing from the product.
  """
  @spec click_inbound_probe(term()) :: String.t()
  def click_inbound_probe(view) do
    element = Phoenix.LiveViewTest.element(view, "[data-test='mail-inbound-probe']")

    case probe_inbox() do
      nil -> Phoenix.LiveViewTest.render_click(element)
      address -> Phoenix.LiveViewTest.render_click(element, %{"to" => address})
    end
  end

  @doc """
  Point the widget step at a real application and at the fleet's site.

      setup :widget_on_the_fleet

  The widget step's first act is to run a mix generator in the project's
  working directory, and the default stub holds a one-line `mix.exs` that is a
  marker for the working-dir plug and nothing else. Mix answered with both
  "the task could not be found" *and* "no mix.exs was found in the current
  directory", which reads as a missing generator and is really a missing
  application.

  Only the recording needs any of this. `ExCliVcr` matches on command and
  args, not on the directory the command ran in, so on replay the cassette
  answers and no application, no fleet and no site are required. That is the
  point: the criteria were green only on the machine that happened to have a
  site running, which is not a test.

  `CMS_FLEET_SITE` names the application. It defaults to
  `code_my_spec_test_repos/fleet_site`, which is a committed `mix cms.new`
  checkout — deliberately pristine, so the generator writes rather than
  prompting to overwrite, which would hang the run waiting on stdin.

  Recording needs the fleet up and the site serving:

      docker/fleet/fleet.sh up
      docker/fleet/site.sh          # the wired app on :4100
  """
  def widget_on_the_fleet(%{scope: scope, project: project} = context) do
    path =
      System.get_env("CMS_FLEET_SITE") ||
        Path.expand("code_my_spec_test_repos/fleet_site", File.cwd!())

    recording? = recording?()

    (not recording? or File.exists?(Path.join(path, "mix.exs"))) ||
      raise """
      No application at #{path} to install the widget into.

      The widget step runs `mix cms_gen.support_widget`, which needs a real
      generated application. Point CMS_FLEET_SITE at one, or generate it with
      `mix cms.new`.
      """

    # The generator writes into the checkout. Recording leaves it dirty, and
    # the next recording would then hit the overwrite prompt and hang on
    # stdin — which looks like the suite freezing, not like residue.
    recording? && ExUnit.Callbacks.on_exit(fn -> reset_site_checkout(path) end)

    {:ok, project} = Fixtures.set_project_local_path(project, path)

    previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

    Application.put_env(
      :code_my_spec,
      :provisioning_step_opts,
      Keyword.merge(previous, site_url: "http://127.0.0.1:4100", deploy_key: "dk_fleet_spex")
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
    end)

    context
    |> Map.put(:project, project)
    |> Map.put(:scope, %{scope | active_project: project})
    |> real_working_directory()
  end

  defp reset_site_checkout(path) do
    System.cmd("git", ["checkout", "--", "."], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["clean", "-fd"], cd: path, stderr_to_stdout: true)
    :ok
  end

  @doc """
  Swap the project's environment for a real one on disk.

      setup :setup_active_project
      setup :real_working_directory

  For spex whose subject is a real subprocess. `sops` and `age` are binaries —
  they read and write actual files, and the memory environment the default
  fixture installs is invisible to them. The encrypt reported success and the
  file it was meant to write was never anywhere, which surfaces as "the
  encrypted file does not carry the key" three assertions later.

  The directory is the project's own `local_path`, so nothing else has to
  change: the plug, the project row and the environment all still agree about
  where the project is.
  """
  def real_working_directory(%{scope: scope, project: project} = context) do
    env = Fixtures.local_environment_fixture(working_dir: project.local_path)

    Fixtures.unregister_environment(project.id)
    Fixtures.register_environment(project.id, env)
    ExUnit.Callbacks.on_exit(fn -> Fixtures.unregister_environment(project.id) end)

    context
    |> Map.put(:environment, env)
    |> Map.put(:scope, %{scope | environment: env, cwd: env.cwd})
  end

  @doc """
  Choose the project's setup options through the options form.

  `given_ "Sam has chosen his setup options"` was a comment saying the
  defaults were fine and no code at all. That reads as established until the
  defaults change underneath it, at which point the failure surfaces in a
  `then_` counting credential fields — pointing at the field list rather than
  at the options that decide it.

  Driven through `setup-options-form` rather than written to the project,
  because which options are on is exactly what that form decides, and a spex
  that set them directly would not notice it breaking.
  """
  def choose_setup_options(view, options) when is_list(options) do
    # The change event, not the form element. `render_change/2` on a form
    # *merges* the given values into what the DOM already has, and every
    # checkbox on this form renders checked — so a payload naming six options
    # arrived as all eight and nothing ever turned off. The spex passed while
    # asserting the opposite of what it said.
    #
    # This is the payload a browser sends: unchecked boxes are absent from the
    # form data entirely, which is exactly how `toggle_options` reads them.
    Phoenix.LiveViewTest.render_change(view, "toggle_options", %{
      "options" => Map.new(options, &{to_string(&1), "true"})
    })
  end

  @doc """
  Every option the setup page offers, turned on.

  For the criteria whose subject is "all of it at once" — 7981 asks that one
  sitting covers every credential the run will need, and that is only a real
  question when every option is actually on.
  """
  def all_setup_options(view) do
    options = rendered_options(view)
    choose_setup_options(view, options)
    options
  end

  # Wait for a background setup run to settle, and return the page.
  #
  # `start-setup` returns as soon as the run begins, so a `then_` that asserts a
  # final state has to wait for one. Without this the test ends while the run is
  # still going, the sandbox connection closes underneath it, and Postgrex logs
  # a disconnect at `:error` — which fails the spex for a reason that has
  # nothing to do with the story.
  #
  # Polls the rendered page rather than waiting on a message: the run publishes
  # to the *LiveView*, not to the test, and having the test subscribe as well
  # would mean two things listening for the same event and a spex that passes
  # because it read its own subscription rather than the page.
  #
  # Criteria that assert on a step being mid-run assert first and settle after.
  @doc """
  Give the project exactly these environments.

  "Sam has turned production off" is a statement about which environments the
  project has, not about a checkbox — there is no `prod` option on the setup
  form. Steps fan out over whatever environments exist, so removing one is what
  turning it off means.
  """
  def only_environments(scope, names), do: Fixtures.set_environments(scope, names)

  @doc """
  Every file in the project tree, as paths relative to its root.

  `Environments.list_directory/2` lists one level, which is right for what it
  is. The generated artifacts are nested — `config/deploy.yml`,
  `lib/…_web/router.ex`, `envs/prod.enc.env` — so a criterion asking "did the
  generator produce this" has to see the whole tree, not the top of it.
  Listing one level and finding only `config` reads as "nothing was
  generated".
  """
  def project_tree(env, path \\ ".", depth \\ 6)

  def project_tree(_env, _path, 0), do: []

  def project_tree(env, path, depth) do
    case CodeMySpec.Environments.list_directory(env, path) do
      {:ok, names} -> Enum.flat_map(names, &tree_entry(env, path, &1, depth))
      _ -> []
    end
  end

  defp tree_entry(env, path, name, depth) do
    child = if path in [".", ""], do: name, else: path <> "/" <> name

    # A directory lists; a file does not. Cheaper than a stat call through an
    # abstraction that does not offer one.
    case CodeMySpec.Environments.list_directory(env, child) do
      {:ok, []} -> [child]
      {:ok, _} -> [child | project_tree(env, child, depth - 1)]
      _ -> [child]
    end
  end

  @doc """
  Put a repository at the name setup would use, before setup runs.

  For the criteria whose subject is a repository that is *already there*. They
  were passing only because an earlier run had left one behind — a premise that
  holds on a dirty account and fails on a clean one. Now they state it.

  `commits: true` when the criterion needs the push to be rejected: a fresh
  history cannot fast-forward onto a repository that already carries one.
  """
  def existing_repository(project, opts \\ []) do
    name = Fixtures.repository_name(project)
    Fixtures.create_spex_repository(name, opts)
    tear_down_repository(project)
    project
  end

  @doc """
  Remove the repository this spex creates, when a harness token allows it.

  The app's own grant deliberately cannot delete repositories — see
  `CodeMySpecSpex.Fixtures.delete_spex_repository/1`. With
  `GITHUB_SPEX_ADMIN_TOKEN` set, each recording starts from a repository that
  does not exist yet, which is what criterion 8182 needs: it pushes a fresh
  history, and a repository carrying an earlier run's commits rejects that push
  as non-fast-forward (correctly — 8184 is the criterion for exactly that).

  Without the token this is a no-op and the repository is left behind.
  """
  def tear_down_repository(project) do
    name = Fixtures.repository_name(project)

    ExUnit.Callbacks.on_exit(fn ->
      safe_teardown(name, fn -> Fixtures.delete_spex_repository(name) end)
    end)

    project
  end

  @doc """
  Declare that the repository setup would create is already this project's.

  Recording repeatedly leaves the repository behind — the grant has no
  `delete_repo` scope — so the next run finds it. Setup then pauses, correctly,
  because a repository it did not make is Sam's to decide about. Stating the
  fact up front (it *was* made by an earlier run of this spex) keeps the run
  moving to the steps actually under test instead of stopping at position 0.
  """
  def own_repository(project), do: Fixtures.own_repository(project)

  @doc """
  Adopt the repository and resume, if the run paused on a name collision.

  GitHub's grant here has no `delete_repo` scope, so a repository a spex made
  cannot be removed afterwards — the next recording finds it and the step
  pauses asking whether to adopt it or pick another name (criterion 8185).
  That pause is correct behaviour, and it halts the run before every later
  step, so any criterion whose subject is further down the sequence has to get
  past it. Adopting is the honest answer: the repository really is this
  project's, made by an earlier run of this very spex.

  A no-op when the run did not pause, so it is safe to call unconditionally.
  """
  def adopt_repository_if_paused(view) do
    if Phoenix.LiveViewTest.has_element?(view, "[data-test='adopt-existing-repository']") do
      view
      |> Phoenix.LiveViewTest.element("[data-test='adopt-existing-repository']")
      |> Phoenix.LiveViewTest.render_click()

      view
      |> Phoenix.LiveViewTest.element("[data-test='start-setup']")
      |> Phoenix.LiveViewTest.render_click()

      await_provisioning(view)
    end

    view
  end

  def await_provisioning(view, timeout \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    # Wait for the run to *start* before waiting for it to stop. Polling
    # straight away returns on the first read — nothing is running yet, which
    # looks identical to finished, and the assertion then reads a page where
    # nothing has happened.
    await_start(view, System.monotonic_time(:millisecond) + 5_000)
    settle(view, deadline)
  end

  @doc """
  Wait until an environment shows a server on the page.

  `await_provisioning/2` waits for "nothing is running", which cannot tell a
  finished *previous* run from a finished current one — after a halted run
  every step is already in a settled state, so the wait can return the page as
  it was before the new run wrote anything. Waiting for the thing the
  assertion is about is the honest version of that wait.
  """
  def await_environment_server(view, environment, timeout \\ 90_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_environment_server(view, environment, deadline, nil)
  end

  defp await_environment_server(view, environment, deadline, _last) do
    html = Phoenix.LiveViewTest.render(view)

    server =
      html
      |> Floki.parse_document!()
      |> Floki.find("[data-test='environment'][data-environment='#{environment}']")
      |> Floki.attribute("data-server")
      |> List.first()

    cond do
      is_binary(server) and server != "" ->
        html

      System.monotonic_time(:millisecond) > deadline ->
        html

      true ->
        Process.sleep(500)
        await_environment_server(view, environment, deadline, server)
    end
  end

  defp await_start(view, deadline) do
    html = Phoenix.LiveViewTest.render(view)

    # Started means *any* step has moved, not that every step has. The old
    # test — nothing is `not_started` — is only true of a run that got all the
    # way to the end, so a run that halts partway (the usual case for the
    # criteria about halting) never looked started and polled out the whole
    # five-second window. That was five seconds on every such criterion, and
    # eleven on the one that resumes.
    started? =
      Enum.any?(
        ~w(running done errored paused),
        &(html =~ ~s(data-state="#{&1}"))
      )

    cond do
      started? -> :started
      System.monotonic_time(:millisecond) > deadline -> :never_started
      true -> Process.sleep(50) && await_start(view, deadline)
    end
  end

  defp settle(view, deadline) do
    html = Phoenix.LiveViewTest.render(view)

    cond do
      not (html =~ ~s(data-state="running")) ->
        html

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk("setup was still running when the wait expired")

      true ->
        Process.sleep(100)
        settle(view, deadline)
    end
  end

  @doc """
  Every option except the named ones.

  For `given_ "Sam has turned the email option off"`. Derived from what the
  form renders rather than from `Provisioning.available_options/0`, because a
  spex may not reach into `CodeMySpec` — the boundary is the point, and the
  page is the surface the story owns anyway.
  """
  def choose_all_setup_options_except(view, excluded) when is_list(excluded) do
    off = MapSet.new(excluded, &to_string/1)
    kept = view |> rendered_options() |> Enum.reject(&MapSet.member?(off, &1))

    choose_setup_options(view, kept)
    kept
  end

  defp rendered_options(view) do
    view
    |> Phoenix.LiveViewTest.render()
    |> Floki.parse_document!()
    |> Floki.find("[data-test='setup-options-form'] input[type='checkbox']")
    |> Floki.attribute("name")
    |> Enum.map(&(&1 |> String.replace_prefix("options[", "") |> String.trim_trailing("]")))
  end

  @doc """
  Paste every credential setup asks Sam to type.

  Setup refuses to start while a required credential is missing (criterion
  7985), so a `given_` that runs the whole sequence has to supply them first —
  otherwise the run is refused and the spex reports whatever it was really
  testing as broken.

  Real values when recording, placeholders otherwise. A placeholder is correct
  for replay because the HTTP never leaves; recording with one produces a
  cassette full of 401s that replays perfectly and proves nothing.
  """
  def paste_provider_credentials(view) do
    view
    |> Phoenix.LiveViewTest.form("form[phx-submit='save_credentials']", %{
      "credentials" => %{
        "hetzner_api_token" => recording_credential("HETZNER_API_TOKEN", "spex-placeholder-token"),
        "hetzner_s3_access_key_id" =>
          recording_credential("HETZNER_S3_ACCESS_KEY_ID", "spex-placeholder-id"),
        "hetzner_s3_secret_access_key" =>
          recording_credential("HETZNER_S3_SECRET_ACCESS_KEY", "spex-placeholder-secret")
      }
    })
    |> Phoenix.LiveViewTest.render_submit()
  end

  @doc """
  Commit what setup wrote into the checkout.

  The secrets step writes `.sops.yaml` and `envs/<env>.enc.env` into the
  repository — encrypted, so they are meant to be committed — and `bin/deploy`
  refuses to run on a dirty tree, correctly, since the image it deploys is
  versioned by commit SHA. So a project that has just been set up cannot deploy
  until somebody commits what setup produced:

      working tree is dirty — commit or stash first
      M .sops.yaml
      D envs/prod.enc.env
      M envs/uat.enc.env

  A real customer hits this on their first run, and it is a gap worth closing
  in the product — setup already creates and pushes the repository, so
  committing what it then generates is not a new kind of act. Doing it here
  keeps the drill honest in the meantime: it does what the user would do,
  rather than pretending the files were never written.
  """
  def commit_generated_files(path, message \\ "Setup-generated configuration") do
    System.cmd("git", ["add", "-A"], cd: path, stderr_to_stdout: true)

    System.cmd(
      "git",
      [
        "-c",
        "user.email=drill@example.com",
        "-c",
        "user.name=Drill",
        "commit",
        "-q",
        "-m",
        message
      ],
      cd: path,
      stderr_to_stdout: true
    )

    :ok
  end

  @doc """
  Fill in the project's Hetzner storage credentials through the setup page.

  Driven through the form rather than written straight into `ProjectSecrets`,
  because that form is a surface the story owns — Hetzner mints object-storage
  keys in the console only, so pasting them is the actual user journey and a
  spex that bypassed it would not notice the form breaking.

  Real values come from the environment when recording a cassette; replay
  needs only that the lookup succeeds, so a placeholder is correct there and a
  live key in the repository would not be.
  """
  def paste_storage_credentials(view) do
    view
    |> Phoenix.LiveViewTest.form("form[phx-submit='save_credentials']", %{
      "credentials" => %{
        "hetzner_s3_access_key_id" =>
          recording_credential("HETZNER_S3_ACCESS_KEY_ID", "spex-placeholder-id"),
        "hetzner_s3_secret_access_key" =>
          recording_credential("HETZNER_S3_SECRET_ACCESS_KEY", "spex-placeholder-secret")
      }
    })
    |> Phoenix.LiveViewTest.render_submit()
  end

  defp project_name(%{active_project: %{name: name}}) when is_binary(name), do: name
  defp project_name(_scope), do: "spex"

  # Teardown reads the recorded resources out of the database, and it runs as
  # the test process is going away — so it can lose the sandbox connection
  # mid-query when whichever process had it checked out exits first. The loss
  # is transient: the pool hands out another one. Without the retry a spex
  # whose assertions all passed failed in cleanup with a `DBConnection` error
  # that named nothing to do with the spex, and — worse — left the real
  # resources it had created behind.
  # Fixture teardowns run in ExUnit's on_exit process and need the database —
  # they read the provider token before they can call the provider at all. The
  # sandbox is sometimes already back in manual mode by then, and the failure
  # surfaces as a `DBConnection.OwnershipError` that fails a test whose
  # assertions all passed. Retry, then warn loudly rather than fail: the test
  # result should reflect the claim, and a cleanup that could not run is worth
  # saying out loud because it means a real resource was left behind.
  defp redact_sensitive_patterns(body) do
    Enum.reduce(sensitive_patterns(), body, fn {pattern, replacement}, acc ->
      String.replace(acc, pattern, replacement)
    end)
  end

  @doc """
  Register a teardown that runs against its cassette.

  The idiom is three closures deep written out — `on_exit` wrapping
  `safe_teardown` wrapping `with_provider_cassette` — and it appeared at five
  call sites, which is where most of this file's nesting came from. All three
  layers are needed: the removal has to be deferred, it has to survive a
  provider that will not answer, and it has to replay rather than reach for the
  network. Naming it once says that in one place.
  """
  def teardown_later(label, cassette, fun) do
    ExUnit.Callbacks.on_exit(fn ->
      safe_teardown(label, fn -> with_provider_cassette(cassette, fun) end)
    end)
  end

  def safe_teardown(label, fun, attempts \\ 3) do
    fun.()
  rescue
    error ->
      IO.warn("spex teardown for #{label} failed: #{Exception.message(error)}")
      :error
  catch
    :exit, _reason when attempts > 1 ->
      Process.sleep(100)
      safe_teardown(label, fun, attempts - 1)

    :exit, reason ->
      IO.warn("spex teardown for #{label} could not run: #{inspect(reason, limit: 3)}")
      :error
  end

  defp tear_down_steps_with_retry(scope, keys, opts, attempts \\ 3) do
    Fixtures.tear_down_steps(scope, keys, opts)
  rescue
    # `DBConnection.OwnershipError` is *raised*, not exited — the sandbox is
    # back in manual mode by the time on_exit runs. Catching only exits left it
    # failing tests whose assertions had already passed. Rescue clauses cannot
    # carry guards, so the retry decision is made in the body.
    error ->
      if attempts > 1 do
        Process.sleep(100)
        tear_down_steps_with_retry(scope, keys, opts, attempts - 1)
      else
        IO.warn("spex teardown could not reach the database: #{Exception.message(error)}")
        []
      end
  catch
    :exit, _reason when attempts > 1 ->
      Process.sleep(100)
      tear_down_steps_with_retry(scope, keys, opts, attempts - 1)

    :exit, reason ->
      IO.warn("spex teardown could not reach the database: #{inspect(reason, limit: 3)}")
      []
  end

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  # `CodeMySpecSpex.Story968.Criterion8011Spex` -> "spex story968 criterion8011",
  # which `Storage.bucket_name/2` turns into `spex-story968-criterion8011-prod`.
  # Long, and worth it: a bucket in the account says which spex made it.
  defp project_name_for(%{module: module}) do
    module
    |> Module.split()
    |> Enum.reject(&(&1 in ["CodeMySpecSpex", "Elixir"]))
    |> Enum.map_join(" ", &String.downcase/1)
    |> String.replace(~r/spex$/, "")
    |> String.trim()
    |> then(&"spex #{&1}")
  end

  defp project_name_for(_context), do: "spex project"

  @doc """
  Give the project a verified domain.

  `given_ "Sam owns his domain"` has to actually be true before the mail steps
  can do anything, and a domain is the one precondition a spex cannot create
  for itself — owning it is a fact about the world, not an action in the app.

  Defaults to the domain the account genuinely owns, so recording reads real
  verified state rather than registering a throwaway domain whose DNS would
  never resolve and whose verification would therefore never complete.
  """
  def own_domain(project, domain \\ nil) do
    Fixtures.verify_project_domain(project, domain || spex_domain())
  end

  @doc """
  Publish an MX at the zone apex and register its removal.

  Criterion 8029 asserts that setting up *sending* leaves an existing inbound
  MX alone, which cannot be observed unless one is there to begin with. Real,
  because the assertion is that setup did not touch a real record.
  """
  def existing_apex_mx(scope, project) do
    result =
      with_provider_cassette("setup_#{slug(project.domain)}_apex_mx", fn ->
        Fixtures.publish_apex_mx(scope, project.domain)
      end)

    # This record is published by a fixture rather than by a step, so no step
    # recorded it and `tear_down_after/3` — which removes only what a step
    # wrote — never touches it. Left behind it is a real MX on a real domain,
    # and the next spex reads it as an apex MX of its own.
    teardown_later(project.domain, "teardown_#{slug(project.domain)}_apex_mx", fn ->
      Fixtures.remove_apex_mx(scope, project.domain)
    end)

    result
  end

  # A domain nothing depends on, and never the one the product runs on.
  #
  # These spex create and destroy real sending domains, DNS records and
  # buckets. Pointing them at `codemyspec.com` put the live production sending
  # domain into a teardown list and it was duly deleted and recreated —
  # dropping inbound mail for it, because Resend fixes capabilities at
  # creation. A subdomain narrowed the blast radius but left the same zone and
  # the same account domain one mistake away.
  #
  # `astralbi.com` carries nothing. That is its entire qualification.
  # Recording waits on real DNS reaching a real provider. Replay waits on
  # nothing, so the generous window costs only the runs that need it.
  defp verification_opts do
    if cassette_mode() == :record do
      [attempts: 60, interval_ms: 5_000]
    else
      # Same number of attempts, none of the waiting. Replay used to fall back
      # to the production default, which is smaller than the count a recording
      # needed — so a poll that took twenty rounds against the real provider
      # gave up after ten against the cassette and reported the domain never
      # verified, when the answer was sitting in the next interaction.
      [attempts: 60, interval_ms: 0]
    end
  end

  defp spex_domain do
    System.get_env("CMS_SPEX_DOMAIN") ||
      "spex." <> System.get_env("CMS_SPEX_BASE_DOMAIN", "astralbi.com")
  end

  @doc """
  Replace a provider's credential with one the provider itself will reject.

  For criteria about *the provider's own error* reaching someone. A credential
  we refuse locally produces our message ("not connected"), which is a
  different claim — the point is that what Cloudflare or Resend actually said
  survives the trip. A token the provider rejects is the only way to get a real
  provider message, and it is reproducible in a way a genuinely under-scoped
  token is not.
  """
  def break_provider_credential(scope, provider) do
    Fixtures.connect_provider(scope, provider,
      access_token: "spex-deliberately-invalid-token",
      refresh_token: nil,
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    )
  end

  @doc """
  Give the project a domain that will never verify.

  For the criteria about setup *not* succeeding — a domain stuck unverified,
  a record at fault. Those states cannot be read off a healthy account, and
  reading a healthy one and asserting the unhappy path is how a test comes to
  prove nothing.

  A real subdomain of the account's domain whose DNS records are deliberately
  never published, so the provider genuinely refuses it. Stable per spex so
  the recorded URLs replay.
  """
  def unverifiable_domain(project, context) do
    base = System.get_env("CMS_SPEX_BASE_DOMAIN", "astralbi.com")

    # Hyphens, not the underscores `slug/1` produces: an underscore is not a
    # legal DNS label and Resend rejects the domain outright.
    label =
      context
      |> project_name_for()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    Fixtures.set_project_domain(project, "#{label}.#{base}")
  end

  # Make every environment's sending domain real and resolvable.
  #
  # Setup registers one sending domain per environment and is not satisfied
  # until all of them verify, so recording the successful path means UAT has to
  # be real too — production alone was what let the step look green while
  # quietly covering one environment.
  #
  # Every environment, production included. Production's sending domain used to
  # be the account's own apex — already verified, nothing to publish — and that
  # is exactly what put a live domain in teardown's path. Spex now run under a
  # subdomain of their own, so production's sending domain is one of theirs and
  # has to be made real like the rest.
  #
  # Records are removed on exit; they are real DNS in a real zone.
  @doc """
  Publish every sending record, leaving the domain unverified.

  The counterpart to `verified_sending_domains/3` for criteria whose subject is
  the *waiting* — a domain handed over already verified gives the step nothing
  to poll for.
  """
  def published_sending_domains(scope, project, environments \\ ["prod", "uat"]) do
    for environment <- environments do
      sending = Fixtures.sending_domain(project.domain, environment)

      case with_provider_cassette("setup_#{slug(sending)}_published", fn ->
             Fixtures.publish_all_records_unverified(scope, sending)
           end) do
        {:ok, created} ->
          teardown_later(sending, "teardown_#{slug(sending)}_published", fn ->
            Fixtures.remove_published_records(scope, created)
          end)

        {:error, reason} ->
          raise "could not publish #{sending}: #{inspect(reason)}"
      end
    end
  end

  @doc """
  Stage the account's SSH access key so the server step adopts rather than
  generates one. See `Fixtures.account_access_key/1` for why generation cannot
  survive replay.
  """
  def account_access_key(%{scope: scope} = context) do
    Fixtures.account_access_key(scope)
    context
  end

  @doc """
  Make each environment's sending domain exist, without publishing anything.

  The page renders no mail section until Resend knows the domain, so a
  criterion that needs to read the DNS panel *before* the step runs cannot
  start from nothing. This gives it the domain and stops there — the records
  stay the step's to publish, which is what 8029 is asserting about.
  """
  def registered_sending_domains(scope, project, environments \\ ["prod", "uat"]) do
    for environment <- environments do
      sending = Fixtures.sending_domain(project.domain, environment)

      case with_provider_cassette("setup_#{slug(sending)}_registered", fn ->
             Fixtures.register_sending_domain_only(scope, sending)
           end) do
        {:ok, _domain} ->
          teardown_later(sending, "teardown_#{slug(sending)}_registered", fn ->
            Fixtures.remove_sending_domain(scope, sending)
          end)

        {:error, reason} ->
          raise "could not register #{sending}: #{inspect(reason)}"
      end
    end
  end

  @doc """
  An app access token for the project, as the deployed app obtains one.

  The customer's app holds a refresh secret from provisioning and exchanges it;
  the browser never sees either. A criterion that needs a widget socket starts
  here rather than by naming a project id, which is not a credential.
  """
  def app_access_token(project), do: Fixtures.app_access_token(project)

  @doc """
  A project whose blog can actually be published, with somewhere to publish to.

  `ensure_publishable/1` refuses to start without a content bucket, a client
  API url and a deploy key — sync is trigger-only, so publishing into a project
  with no reachable client would put files in a bucket nothing is ever told
  about. A criterion whose premise is "Sam has a post ready" is asserting that
  those exist; without them the publish reports `trigger_failed` and the
  criterion fails on its own setup.

  The bucket has to exist for real while recording, too: publishing signs
  against the global `:ex_aws` config, which is the user's own AWS account by
  design, and a PUT to a bucket that was never created answers `NoSuchBucket`.
  The fixture named a bucket and nothing made one, so a recording session
  captured that 404 as the story's behaviour.

  Only while recording. On replay the cassette answers, and creating a real
  bucket per run would be pure cost for a request that never leaves the VM.
  """
  def publishable_project(scope, project, attrs \\ %{}),
    do: Fixtures.publishable_project(scope, project, attrs)

  @doc """
  Point publishing at the fleet: MinIO for storage, the fleet site for the
  trigger.

      setup :publishing_to_the_fleet

  A publish is two real things — objects written to S3, and a trigger POSTed to
  the deployed site — and both have a local counterpart here, so both can be
  exercised for real rather than against a stranger's Hetzner bucket.

  This used to argue that they should therefore not be recorded at all: "a
  cassette answers from a file no matter what the code did". That is true of a
  *hand-written* cassette and false of one recorded against a real MinIO and a
  real site. The recording is the real run; replay is the regression check.
  Skipping the recording did not make the criteria more honest, it made them
  green only on whichever machine happened to have the fleet up — and for
  months that machine's site lived in a session scratchpad with no commits, so
  nobody else could run them at all.

  Recording needs the fleet up and the site serving. Replay needs neither:

      docker/fleet/fleet.sh up
      docker/fleet/site.sh          # the generated app on :4100
      SPEX_CASSETTE_MODE=record mix spex --pattern "test/spex/972*/*_spex.exs"
  """
  def publishing_to_the_fleet(%{scope: scope, project: project} = context) do
    project =
      publishable_project(scope, project, %{
        content_bucket: "cms-spex-content",
        s3_endpoint: "http://127.0.0.1:9000",
        aws_access_key_id: "cms-fleet",
        aws_secret_access_key: "cms-fleet-secret",
        aws_region: "us-east-1",
        client_api_url: "http://127.0.0.1:4100",
        deploy_key: "dk_fleet_spex"
      })

    # The publish also fetches the post back from the live site to prove it
    # rendered — `verify_render/2` — and without a site URL it builds "/" and
    # dies inside Finch with `scheme is required for url: /`, which names
    # neither the site nor the step.
    previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

    Application.put_env(
      :code_my_spec,
      :provisioning_step_opts,
      Keyword.merge(previous,
        site_url: "http://127.0.0.1:4100",
        # What the step fetches back and what proves it rendered. The
        # LiveView supplies these for the standalone publish button; the
        # step reads them from here and `Keyword.fetch!/2`s them, so their
        # absence is a `key :path not found` rather than a default.
        # The post's own address, not the site root. 8036 asserts the check
        # requested it — a publish that only ever proved "/" renders has not
        # shown that the post did.
        path: "/blog/hello",
        expect: "Hello"
      )
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
    end)

    context
    |> Map.put(:project, project)
    |> Map.put(:scope, %{scope | active_project: project})
  end

  @doc """
  Configure the project so a publish can actually run.

      setup :publishing_configured

  `ContentPublishing.publish/1` refuses without `content_bucket`,
  `client_api_url` and `deploy_key` — "Publishing is not configured. Sync is
  trigger-only, so a publish without a reachable client would never reach the
  site." That refusal happens before anything is written, so a criterion about
  *storage* reads it as nothing having been published.

  A setup rather than a call in the `given_`, because the LiveView reads the
  project into its assigns when it mounts and every step it runs reads that
  copy — configuring the row after the mount updates the database and not the
  page, which is the trap story 965 was stuck behind.
  """
  def publishing_configured(%{scope: scope, project: project} = context) do
    project = publishable_project(scope, project)

    context
    |> Map.put(:project, project)
    |> Map.put(:scope, %{scope | active_project: project})
  end

  def verified_sending_domains(scope, project, environments \\ ["prod", "uat"], opts \\ []) do
    for environment <- environments do
      sending = Fixtures.sending_domain(project.domain, environment)

      # Inside a cassette, because this talks to Resend and Cloudflare for
      # real. A precondition that reaches a provider outside a recording works
      # while recording and then, on replay, tries the same live calls with a
      # placeholder credential — so the spex fails in its `given_` for a
      # reason that has nothing to do with what it is testing.
      # The same window the step itself gets. Verification is the slow part
      # either way, and a fixture that gives up sooner than the code it is
      # setting up for fails in `given_` for a reason that looks like the
      # story under test.
      case with_provider_cassette("setup_#{slug(sending)}_records", fn ->
             Fixtures.publish_all_records(scope, sending, verification_opts() ++ opts)
           end) do
        {:ok, created} ->
          teardown_later(sending, "teardown_#{slug(sending)}_dns", fn ->
            Fixtures.remove_published_records(scope, created)
          end)

        {:error, reason} ->
          raise "could not publish #{sending}: #{inspect(reason)}"
      end
    end

    project
  end

  @doc """
  A sending domain that is stuck for a *specific* reason.

  Everything Resend asks for is published, and then the DKIM is deleted — the
  way it happens for real is somebody tidying DNS who does not recognise
  `resend._domainkey`. The domain refuses to verify and the record at fault is
  identifiable, which is the difference between "verification timed out" and
  something Sam can act on.

  Deleting rather than withholding is what keeps this premise reachable. The
  step publishes whatever is missing, so a record that was never written comes
  straight back; a record that was deleted leaves its absence in a resolver's
  cache for the zone's SOA negative TTL, which outlasts the wait.

  Registers teardown of both the DNS records and the Resend domain. These are
  real records in a real zone; leaving them behind would change how mail for
  that name is handled.
  """
  def stuck_sending_domain(scope, project, context) do
    project = unverifiable_domain(project, context)

    case with_provider_cassette("setup_#{slug(project.domain)}_partial_records", fn ->
           Fixtures.publish_then_delete_dkim(scope, project.domain)
         end) do
      {:ok, created} ->
        teardown_later(project.domain, "teardown_#{slug(project.domain)}_dns", fn ->
          Fixtures.remove_published_records(scope, created)
        end)

        project

      {:error, reason} ->
        raise "could not set up the stuck-domain precondition: #{inspect(reason)}"
    end
  end

  @doc """
  Give the deployed app a refresh secret it can exchange.

      setup :register_log_in_setup_account
      ...
      given_ "a deployed app holds a valid credential", context do
        app_holds_refresh_secret(context.scope)
        ...

  Defaults to the literal the 971 spex use. No provider is involved — the
  secret is CodeMySpec's own, so this needs no cassette.
  """
  # Mint a widget socket token for the scope's project (via the bridge).
  def mint_socket_token(scope), do: Fixtures.mint_socket_token(scope)

  def app_holds_refresh_secret(scope, secret \\ "refresh-secret") do
    {:ok, _} = Fixtures.register_refresh_secret(scope, secret)
    secret
  end

  @doc """
  Stage a deploy so the deploy step can run without a real kamal cluster.

  The deploy-control-flow criteria (migration-before-swap, failed-migration,
  unhealthy-deploy) are about `Provisioning.Deploy`'s ordering and failure
  handling — not about kamal. So kamal is stubbed: a `bin/deploy` script that
  exits per the scenario, and the HTTPS health probe is injected as a function
  rather than reaching a host that does not exist yet.

  `scenario` is `:ok` (everything succeeds), `:migrate_fails`, or
  `:health_fails`. The required secrets are written so the deploy step's
  pre-flight passes, and step opts carry the host, environment and probe.
  """
  def stage_deploy(%{scope: scope, environment: env} = context, scenario \\ :ok) do
    # Secrets the deploy pre-flight requires.
    for {k, v} <- [
          {"SECRET_KEY_BASE", "staged-secret-key-base"},
          {"DATABASE_URL", "ecto://staged"}
        ] do
      {:ok, _} = CodeMySpecSpex.Fixtures.put_encrypted_secret(scope, "uat", k, v)
    end

    # bin/deploy stub: exits non-zero on `migrate` only under :migrate_fails,
    # succeeds otherwise. Kamal is not invoked.
    migrate_exit = if scenario == :migrate_fails, do: 1, else: 0

    script = """
    #!/usr/bin/env bash
    phase="$1"
    if [ "$phase" = "migrate" ]; then
      echo "migrated=stub"
      exit #{migrate_exit}
    fi
    echo "swapped=stub"
    exit 0
    """

    CodeMySpecSpex.Fixtures.env_cmd(env, "mkdir", ["-p", "bin"])
    :ok = CodeMySpecSpex.Fixtures.write_env_file(env, "bin/deploy", script)
    CodeMySpecSpex.Fixtures.env_cmd(env, "chmod", ["+x", "bin/deploy"])

    probe =
      case scenario do
        :health_fails -> fn _host, _opts -> {:error, "responded 503"} end
        _ -> fn _host, _opts -> :ok end
      end

    previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

    # `deploy_script` is the stub's absolute path: `System.cmd` resolves a
    # relative command against the process cwd, not the environment's, so a
    # bare "bin/deploy" is not found from the test process even though it
    # exists in the working dir. In production the two cwds coincide.
    deploy_script = Path.join(env.cwd, "bin/deploy")

    # A deterministic commit + registry image, so the deploy can record what
    # it shipped (criterion 8005): the image is tagged by the commit and comes
    # from the registry, not a local build.
    commit = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

    Application.put_env(
      :code_my_spec,
      :provisioning_step_opts,
      Keyword.merge(previous,
        environment: "uat",
        host: "staged.example.com",
        probe: probe,
        deploy_script: deploy_script,
        deployed_version: %{
          commit: commit,
          image: "registry.example.com/app:#{commit}",
          source: "registry"
        },
        # Said, not left to the default. `image_for/3` reads an absent `:build`
        # as "build" — a real deploy with no image to run has nothing to ship
        # otherwise, which is what let a drill take the CI path and deploy
        # nothing. This fixture is the opposite case: the version above is
        # already in the registry, and there is no builder staged to make
        # another. Unsaid, the deploy tried to build one and recorded nothing,
        # which is every failure in 966 and 8001.
        build: false
      )
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
    end)

    context
  end

  @doc """
  A setup run whose deploy step really runs and really builds — on nobody's
  hardware.

  Story 992's criteria are about the build: that deploying causes one, that the
  architecture is checked, that the builder goes away either way. None of them
  are about Docker, and none are about object storage, so the box, the build
  and the registry's bucket are injected while everything the deploy step
  itself does stays real.

  Every other step is scripted, because a criterion about the build should not
  provision a server to reach the deploy.

  Options:

    * `:architecture` — what the environment's box runs (default `:arm`)
    * `:builds` — what the build produces; `:error` for a build that fails,
      otherwise the architecture it actually produced (default: matches)
    * `:on_destroy` — called with the builder's id when it is destroyed
  """
  def stage_build(context, opts \\ []) do
    architecture = Keyword.get(opts, :architecture, :arm)
    builds = Keyword.get(opts, :builds, architecture)
    on_destroy = Keyword.get(opts, :on_destroy, fn _id -> :ok end)
    tag = Keyword.get(opts, :tag, "a1b2c3d4e5f6")

    context = stage_deploy(context)

    build =
      case builds do
        :error ->
          fn _scope, _server, _ref, _architecture ->
            {:error, {:build_failed, 1, "no space left on device"}}
          end

        produced ->
          fn _scope, _server, ref, _architecture ->
            {:ok, %{reference: "registry.example.com/app:#{ref}", architecture: produced}}
          end
      end

    previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

    Application.put_env(
      :code_my_spec,
      :provisioning_step_opts,
      Keyword.merge(previous,
        # No `:image`, which is what makes the deploy step build rather than
        # run something that already exists.
        image: nil,
        tag: tag,
        architecture: architecture,
        # Two keys, because `:build` already meant something here.
        #
        # `image_for/3` reads `:build` as the boolean "should this deploy build
        # at all", and `Builder.run/5` reads `:build_fun` as the function to
        # build with. They were one key until the collision surfaced — a real
        # drill passed `build: true` and died with "expected a function, got:
        # true" — and this fixture kept setting the function under the old
        # name afterwards, so the stub was never called. The deploy ran its
        # real build path with no server to build on and recorded no image,
        # which is every failure in story 992.
        build: true,
        build_fun: build,
        # The two seams that otherwise reach a provider for real.
        #
        # `with_access_key/2` asks Hetzner for the account's SSH key when
        # `:ssh_key_ids` is absent, and `with_builder_ssh/2` writes the private
        # half to disk when `:ssh_key_path` is. Neither is what story 992 is
        # about, and unstaged they made the deploy fail with a live
        # `{:hetzner_error, 401, ... "the token you have provided is invalid"}`
        # against the placeholder credential — so the step never reached the
        # build and recorded no image, which is what every criterion here was
        # reading.
        ssh_key_ids: [4242],
        ssh_key_path: "/dev/null",
        create: fn _scope, name, _o -> {:ok, %{"id" => 4242, "name" => name}} end,
        destroy: fn _scope, id -> on_destroy.(id) && {:ok, %{"id" => id}} end,
        ensure_registry: fn _scope, _o -> {:ok, "codemyspec-registry"} end,
        registry_host: "registry.example.com"
      )
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
    end)

    context
  end

  @doc """
  Script every step but the deploy, and let the deploy build for real.

  Pairs with `stage_build/2`: the sequence reaches the deploy without buying a
  server, and the deploy step then runs its own code rather than a stub.
  """
  def built_deploy_run(context, opts \\ []) do
    context = stage_build(context, opts)
    scope = context.scope

    scripted_run(context, %{
      deploy: fn -> Fixtures.run_provisioning_step(scope, :deploy) end
    })
  end

  @doc """
  The plan the account is on, read off the pricing page.

  Asked of the app rather than the database. `then_` observes through the
  public interface, and a spex reaching into `CodeMySpec.Accounts` also breaks
  the `CodeMySpecSpex` boundary — which is how these turned up.

  `/pricing` renders `CheckoutLive`, which badges the tier the account is
  currently on. Returns the tier as a string, or `nil` when no tier is badged
  (a free account, since free is not one of the purchasable tiers).
  """
  def plan_on_page(conn) do
    # `dispatch/4` rather than the `get/2` macro: that one expands to whatever
    # `@endpoint` the calling module set, and this helper lives here rather
    # than in the spex.
    conn
    |> Phoenix.ConnTest.dispatch(CodeMySpecWeb.Endpoint, :get, "/pricing")
    |> Phoenix.ConnTest.html_response(200)
    |> Floki.parse_document!()
    |> Floki.find("[data-test='current-plan']")
    |> Floki.attribute("data-plan")
    |> List.first()
  end

  @doc """
  What the provider reports when the servers screen asks it.

  The screen is the surface under test and is driven for real; the provider
  behind it is injected, because a criterion about how servers are displayed
  should not have to buy a box to say so.

  Pass a list of server maps, or `{:error, reason}` to make the provider
  unreachable — the difference between "no servers" and "could not ask" is
  itself a criterion (8259).

      stage_servers(context, [%{name: "fuellytics", ip: "46.225.105.88", ...}])
      stage_servers(context, {:error, :unauthorized})
  """
  def stage_servers(context, reported, opts \\ []) do
    previous = Application.get_env(:code_my_spec, CodeMySpec.Servers, [])

    staged =
      [
        list: fn _scope -> normalise_reported(reported) end,
        # What the provider says it can supply. Staged too, because the
        # provisioning form is built from availability — without it the size
        # select is empty and every provisioning scenario fails on a form it
        # could not fill rather than on the thing it is testing.
        options: fn _scope -> {:ok, Keyword.get(opts, :available, default_options())} end
      ] ++ Keyword.delete(opts, :available)

    Application.put_env(
      :code_my_spec,
      CodeMySpec.Servers,
      Keyword.merge(previous, staged)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, CodeMySpec.Servers, previous)
    end)

    context
  end

  defp normalise_reported({:error, reason}), do: {:error, reason}
  defp normalise_reported(servers) when is_list(servers), do: {:ok, servers}

  # Shaped like what `Servers.available_options/1` builds from the provider:
  # a location, and only the types that location can actually supply. Includes
  # an ARM type deliberately, so a scenario can ask for one and be refused the
  # way the real provider refused every ARM type during QA.
  #
  # Two locations, because the interesting failures are all per-location. QA
  # found the same size quoted at another location's price (34% under for
  # Singapore) and offered in a location that cannot supply it. Both are
  # invisible against a single-location fixture.
  defp default_options do
    [
      %{
        location: "fsn1",
        city: "Falkenstein",
        types: [
          %{name: "cpx11", architecture: "x86", cores: 2, memory: 2, disk: 40, hourly: 0.0328},
          %{name: "cax21", architecture: "arm", cores: 4, memory: 8, disk: 80, hourly: 0.0200},
          # Deliberately absent from sin below: a size one location has and
          # another does not is what makes an impossible pair expressible.
          %{name: "cpx31", architecture: "x86", cores: 4, memory: 8, disk: 160, hourly: 0.1178}
        ]
      },
      %{
        location: "sin",
        city: "Singapore",
        # The same cpx11, priced differently. Reading the first price in the
        # list rather than the chosen location's is exactly the bug.
        types: [
          %{name: "cpx11", architecture: "x86", cores: 2, memory: 2, disk: 40, hourly: 0.0184}
        ]
      }
    ]
  end

  @doc """
  A server as the provider reports one, with sensible defaults.

  Only the fields a scenario cares about need naming; the rest are filled in
  so a spec about display is not cluttered by a provider's whole payload.
  """
  def provider_server(attrs \\ %{}) do
    Map.merge(
      %{
        id: System.unique_integer([:positive]),
        name: "box-#{System.unique_integer([:positive])}",
        ip: "203.0.113.#{:rand.uniform(254)}",
        size: "cpx11",
        location: "fsn1",
        status: "running"
      },
      Map.new(attrs)
    )
  end

  @doc """
  Stage what each provider says the account holds.

  The seam is the enumeration, not the page. A criterion about how a dangling
  bucket is *displayed* should not need a real bucket at Hetzner; the page is
  still driven for real.

  Takes a map of provider to either a list of resources or `{:error, reason}`,
  so one provider can be unreachable while the others answer — which is a state
  the page has to survive and cannot be arranged any other way.

      stage_inventory(context, %{
        hetzner: [inventory_resource(%{kind: "bucket", location: "old-bucket"})],
        cloudflare: {:error, :unauthorized}
      })
  """
  def stage_inventory(context, by_provider) do
    previous = Application.get_env(:code_my_spec, CodeMySpec.Resources.Inventory, [])

    staged =
      Map.new(by_provider, fn
        {provider, {:error, reason}} -> {provider, {:error, reason}}
        {provider, resources} when is_list(resources) -> {provider, {:ok, resources}}
      end)

    Application.put_env(
      :code_my_spec,
      CodeMySpec.Resources.Inventory,
      Keyword.merge(previous, list: fn _scope -> staged end)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, CodeMySpec.Resources.Inventory, previous)
    end)

    context
  end

  @doc """
  A resource as a provider reports one.

  Shaped like an enumeration rather than like our record of having made it:
  the provider knows what a thing is and where it lives, and nothing about
  which project asked for it.
  """
  def inventory_resource(attrs \\ %{}) do
    Map.merge(
      %{
        kind: "bucket",
        location: "resource-#{System.unique_integer([:positive])}",
        identifier: nil
      },
      Map.new(attrs)
    )
  end

  @doc """
  Stage what trimming a resource does, instead of deleting it.

  The one seam that is not about speed. A criterion asserting *what gets
  deleted* must not delete anything to say so — the resources in question are
  DNS records and buckets, and neither comes back. The function is handed each
  resource trim would remove, so what was and was not offered up is checkable
  without a provider ever being called.

      stage_trim(context, fn resource -> send(owner, {:trimmed, resource.location}) end)
  """
  def stage_trim(context, fun) do
    previous = Application.get_env(:code_my_spec, CodeMySpec.Resources, [])

    Application.put_env(
      :code_my_spec,
      CodeMySpec.Resources,
      Keyword.merge(previous, trim: fn _scope, resource -> fun.(resource) && {:ok, resource} end)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, CodeMySpec.Resources, previous)
    end)

    context
  end

  @doc """
  Stage what a box reports is running on it.

  The seam is the SSH read, not the page. Criteria about how containers are
  *displayed* should not need a real box with a real Docker daemon, but the
  screen is always driven for real — same split as `stage_servers/3`.

  Pass a list of containers, or `{:error, reason}` for a box that cannot be
  reached. `{:error, :timeout}` is how a box that accepts connections and
  never answers arrives here, because the reader owns the deadline.
  """
  def stage_containers(context, reported) do
    previous = Application.get_env(:code_my_spec, CodeMySpec.Servers.Containers, [])

    Application.put_env(
      :code_my_spec,
      CodeMySpec.Servers.Containers,
      Keyword.merge(previous, list: fn _scope, _server -> normalise_reported(reported) end)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, CodeMySpec.Servers.Containers, previous)
    end)

    context
  end

  @doc """
  A container as a box reports one, with sensible defaults.

  Shaped like `docker ps` output rather than like our record of a deploy —
  `state` and `status` are what the daemon says, and `exit_code` is only
  meaningful once something has stopped.
  """
  def container(attrs \\ %{}) do
    Map.merge(
      %{
        name: "app-#{System.unique_integer([:positive])}",
        image: "ghcr.io/example/app:sha-abc123",
        state: "running",
        status: "Up 2 hours",
        exit_code: nil
      },
      Map.new(attrs)
    )
  end

  @doc """
  Stage the monitoring step's outcome without a real UptimeRobot account.

  Criterion 8010 is that each public host has a monitor with somewhere to
  shout — a property of the monitoring step's record, not of UptimeRobot's
  API. The monitors and their notify target are injected via step opts.
  """
  def stage_monitor(context, hosts, notify \\ "sam@example.com") do
    monitors = Enum.map(List.wrap(hosts), &%{host: &1, notify: notify})
    previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

    Application.put_env(
      :code_my_spec,
      :provisioning_step_opts,
      Keyword.put(previous, :monitors, monitors)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
    end)

    context
  end

  @doc """
  Run setup steps to completion so a later step has something to stand on.

  The commonest unestablished precondition in this epic. A `given_` that says
  *"a version is deployed and serving"* or *"the backup schedule was
  installed"* and then only mounts the page has stated a fact and made none of
  it true — the run fails later in a `then_` about the thing under test, which
  is the most expensive place to discover a missing precondition.

  Steps run through the page's own `run-step` button rather than by calling
  `Provisioning.run/3`, because arriving at a state the way Sam arrives at it
  is the only version that proves the state is reachable.

  Wrapped in one cassette for the whole sequence: a step that reaches two
  providers is normal here, and one cassette per step would need the author to
  predict which provider each touches.

      given_ "a version is deployed and serving", context do
        view = mount_provisioning(context)
        run_steps(view, [:repository, :server, :domain, :dns, :deploy], "deployed_uat")
        {:ok, Map.put(context, :view, view)}
      end
  """
  # A macro, and recording both halves: the deploy and backups steps shell out
  # as well as calling providers, and a cassette holding only the HTTP half
  # passes while recording then fails on replay — naming the subprocess, which
  # was not the thing that changed.
  defmacro run_steps(view, keys, cassette_name, opts \\ []) do
    quote do
      view = unquote(view)

      with_full_cassette unquote(cassette_name), unquote(opts) do
        for key <- unquote(keys) do
          view
          |> Phoenix.LiveViewTest.element(
            "[data-test='setup-step'][data-step='#{key}'] [data-test='run-step']"
          )
          |> Phoenix.LiveViewTest.render_click()

          CodeMySpecSpex.Case.await_step(view, key)
        end
      end
    end
  end

  @doc """
  Wait for a step to stop running.

  Clicking Run no longer waits. The step happens under a supervised task
  because a deploy takes minutes and cannot be held inside a LiveView event —
  so `render_click/1` returns while the step is still `running`, and a `given_`
  that moved straight to the next step would run them concurrently and assert
  against a page that had not caught up.

  Polls the rendered page rather than the database, because the page is what
  the criteria read and what a person watches. A step that never leaves
  `running` fails here rather than three assertions later.
  """
  @spec await_step(term(), atom(), pos_integer()) :: :ok
  def await_step(view, key, attempts \\ 600) do
    state =
      view
      |> Phoenix.LiveViewTest.render()
      |> Floki.parse_document!()
      |> Floki.find("[data-test='setup-step'][data-step='#{key}']")
      |> Floki.attribute("data-state")
      |> List.first()

    settled?(view, key, state, attempts)
  end

  defp settled?(_view, key, nil, _attempts) do
    raise "no step named #{key} on the page — nothing to wait for"
  end

  defp settled?(_view, _key, state, _attempts) when state in ~w(done errored paused), do: :ok

  defp settled?(view, key, _state, attempts) when attempts > 1 do
    Process.sleep(500)
    await_step(view, key, attempts - 1)
  end

  defp settled?(_view, key, state, _attempts) do
    raise "the #{key} step is still #{state} after five minutes"
  end

  @doc """
  Mount the setup status page for the context's project.

  Every `given_` in this epic starts here; spelling it out 60 times invites
  the drift where one of them mounts a different path.

  A macro rather than a function because `Phoenix.LiveViewTest.live/2` is one,
  and it reads `@endpoint` from the module it expands in. Called as a function
  from here it would resolve against this module's endpoint instead of the
  spex's — and two spex in this epic deliberately set a different one.
  """
  defmacro mount_provisioning(context) do
    quote do
      ctx = unquote(context)

      {:ok, view, _html} = live(ctx.conn, "/app/projects/#{ctx.project.id}/provisioning")

      view
    end
  end

  # -- Provider HTTP recording --

  @doc """
  Run `fun` with both an HTTP cassette and a shell cassette.

  Half of setup is HTTP and half is a subprocess, and several steps are both:
  the repository step calls the GitHub API *and* runs `git push`, the deploy
  step reads a provider *and* runs `bin/deploy`. Recording only the HTTP half
  produced a spex that passed while recording and failed on replay, because
  the git push went to a remote that had since been torn down — and the
  failure named the push, which was not the thing that had changed.

  `ExCliVcr` is a separate mechanism with its own cassette directory
  (`test/fixtures/cassettes`), so both have to be started, and the mode has to
  agree between them or one half records against the other's replay.

  Requires `use ExCliVcr` in the spex module — the macro it provides expands
  in the caller.
  """
  defmacro with_full_cassette(name, opts \\ [], do: block) do
    quote do
      cmd_mode = if CodeMySpecSpex.Case.recording?(), do: :all, else: :none

      # ExCliVcr loads the existing file and appends to it, and never clears —
      # so a recorded cassette grew across every run that ever touched it. The
      # 972 drill's held 785 commands and four different servers' addresses,
      # which is not a recording of a run, it is a pile of them. Cleared on
      # first entry per run, exactly like the HTTP side.
      if cmd_mode == :all do
        CodeMySpecSpex.Case.clear_cassette_once(unquote(name), ExCliVcr.cassette_dir())
      end

      # `sequential: true` for the same reason the HTTP side needs it: a step's
      # command sequence repeats commands whose answers change — `git
      # rev-parse HEAD` fails before the first commit and succeeds after —
      # and replaying the first match every time reports the wrong one.
      result =
        use_cmd_cassette unquote(name), record: cmd_mode, sequential: true do
          CodeMySpecSpex.Case.with_recorded_repository_owner(unquote(name), fn ->
            CodeMySpecSpex.Case.with_provider_cassette(unquote(name), unquote(opts), fn ->
              unquote(block)
            end)
          end)
        end

      # The command cassette records stdout verbatim and has no filtering of
      # its own — the HTTP filters do not reach it. `age-keygen` prints the
      # private key to stdout, so a run of the secrets step wrote two real age
      # private keys into the cassette in the clear. Scrub after writing.
      CodeMySpecSpex.Case.scrub_cmd_cassette(unquote(name))

      CodeMySpecSpex.Case.refuse_poisoned_cassette(unquote(name))

      result
    end
  end

  # Replay the repository step against the account the recording used.
  #
  # `Repository.ensure/3` asks GitHub who the token is (`GET /user`) only when
  # no `:owner` was supplied. The spex Case supplies one from
  # `GITHUB_SPEX_OWNER`, and that variable lives in `envs/.env`, which Dotenvy
  # loads into config — never into `System.get_env/1`. So the owner is present
  # exactly when the recording operator happened to export it in their shell,
  # and the recorded request sequence differs accordingly.
  #
  # Thirteen cassettes were recorded with it and ten without. The ten resolved
  # the owner at run time and carry `GET /user`; the thirteen went straight to
  # `/repos/<org>/<name>`. Replaying the thirteen without the variable inserts
  # a `GET /user` the cassette has never heard of, and since matching is
  # sequential the run dies on the first step of the first block.
  #
  # The cassette is the only durable record of that environment, so it is what
  # we read. A cassette carrying `GET /user` is left alone — handing it an
  # owner would skip a recorded interaction and desynchronise everything after
  # it, breaking the ten that currently work.
  @doc false
  def with_recorded_repository_owner(name, fun) do
    case recording?() do
      true -> fun.()
      false -> replay_as_recorded_owner(recorded_repository_owner(name), fun)
    end
  end

  defp replay_as_recorded_owner(nil, fun), do: fun.()

  defp replay_as_recorded_owner(owner, fun) do
    previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

    Application.put_env(
      :code_my_spec,
      :provisioning_step_opts,
      Keyword.merge(previous, org: owner, owner: owner)
    )

    try do
      fun.()
    after
      Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
    end
  end

  defp recorded_repository_owner(name) do
    with path when is_binary(path) <- cassette_path(name),
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      uris =
        decoded
        |> cassette_interactions()
        |> Enum.map(&get_in(&1, ["request", "uri"]))
        |> Enum.filter(&is_binary/1)

      case Enum.any?(uris, &(String.trim_trailing(&1, "/") == "https://api.github.com/user")) do
        true -> nil
        false -> owner_from_uris(uris)
      end
    else
      _ -> nil
    end
  end

  defp cassette_interactions(decoded) when is_list(decoded), do: decoded

  defp cassette_interactions(%{} = decoded),
    do: decoded["http_interactions"] || decoded["interactions"] || []

  defp cassette_interactions(_), do: []

  defp owner_from_uris(uris) do
    Enum.find_value(uris, fn uri ->
      case Regex.run(~r{^https://api\.github\.com/(?:repos|orgs)/([^/]+)}, uri) do
        [_, owner] -> owner
        _ -> nil
      end
    end)
  end

  # The HTTP cassette, which is not the only file under this name. A block
  # records two: ReqCassette writes `interactions` to `test/cassettes`, and
  # ExCliVcr writes `commands` to `test/fixtures/cassettes`. Reading the shell
  # one finds no requests and reports no owner, which looks exactly like a
  # cassette that resolved its own.
  defp cassette_path(name) do
    path = Path.join("test/cassettes", name <> ".json")
    if File.exists?(path), do: path
  end

  @doc false
  def scrub_cmd_cassette(name) do
    if recording?() do
      for dir <- ["test/fixtures/cassettes", "test/cassettes"] do
        path = Path.join(dir, name <> ".json")

        if File.exists?(path) do
          scrubbed =
            path
            |> File.read!()
            |> redact_recorded_env()
            |> wildcard_working_directories()
            |> redact_sensitive_patterns()

          File.write!(path, scrubbed)
        end
      end
    end

    :ok
  end

  # ExCliVcr records the *whole* environment each command was given, and the
  # steps now hand their scripts real credentials — object-storage keys, a
  # database URL. Those are matched on by nobody (the default is command and
  # args) but they are written to a file that gets committed, which is how a
  # live Hetzner S3 key ended up in a cassette in the clear.
  #
  # Redacted by variable *name* rather than by value: a value-based filter only
  # catches the secrets we thought to enumerate, and the whole point of a leak
  # is that it is the one you did not think of.
  @sensitive_env_names ~w(SECRET TOKEN PASSWORD CREDENTIAL PRIVATE)
  @sensitive_env_exact ~w(AWS_ACCESS_KEY_ID DATABASE_URL)

  defp redact_recorded_env(body) do
    case Jason.decode(body) do
      {:ok, %{"commands" => commands} = cassette} when is_list(commands) ->
        cassette
        |> Map.put("commands", Enum.map(commands, &redact_command_env/1))
        |> Jason.encode!(pretty: true)

      _ ->
        body
    end
  end

  defp redact_command_env(%{"opts" => %{"env" => env} = opts} = command) when is_map(env) do
    redacted =
      Map.new(env, fn {name, value} ->
        if is_binary(value) and sensitive_env_name?(name),
          do: {name, "<REDACTED>"},
          else: {name, value}
      end)

    %{command | "opts" => %{opts | "env" => redacted}}
  end

  defp redact_command_env(command), do: command

  defp sensitive_env_name?(name) do
    upper = String.upcase(name)
    upper in @sensitive_env_exact or Enum.any?(@sensitive_env_names, &String.contains?(upper, &1))
  end

  # A step that shells out to a generated script runs it by absolute path —
  # the script lives in the project, and `System.cmd` resolves a relative
  # command against the *process* cwd rather than the environment's. Under a
  # spex that project is a fresh temp directory, so the recorded command names
  # a path that will never exist again and the cassette cannot match itself on
  # replay.
  #
  # Rewritten to a glob rather than dropped from the match: `*/bin/backup`
  # still requires the script, and only forgives where it lived.
  defp wildcard_working_directories(body) do
    case Jason.decode(body) do
      {:ok, %{"commands" => commands} = cassette} when is_list(commands) ->
        cassette
        |> Map.put(
          "commands",
          Enum.map(commands, fn c -> c |> wildcard_command_path() |> wildcard_temp_args() end)
        )
        |> Jason.encode!(pretty: true)

      _ ->
        body
    end
  end

  # Only the directory the run happened to get, taken from the recorded `cd`
  # so a command that legitimately names an absolute path elsewhere is left
  # alone.
  defp wildcard_command_path(%{"command" => command, "opts" => %{"cd" => cd}} = entry)
       when is_binary(command) and is_binary(cd) do
    if String.starts_with?(command, cd <> "/") do
      %{entry | "command" => "*" <> String.trim_leading(command, cd)}
    else
      entry
    end
  end

  defp wildcard_command_path(entry), do: entry

  # The same problem one field over. `ssh-keygen -f <tmp>/id_ed25519` writes to
  # a directory named after the run, so the recorded argument names a path that
  # will never exist again and the recording cannot match itself.
  #
  # Only the temp root is forgiven: `*/id_ed25519` still requires the flag and
  # the filename, so this cannot start matching some other command that merely
  # happens to take a path.
  defp wildcard_temp_args(%{"args" => args} = entry) when is_list(args) do
    tmp = String.trim_trailing(System.tmp_dir!(), "/")

    %{entry | "args" => Enum.map(args, &wildcard_temp_arg(&1, tmp))}
  end

  defp wildcard_temp_args(entry), do: entry

  defp wildcard_temp_arg(arg, tmp) when is_binary(arg) do
    if String.starts_with?(arg, tmp <> "/") do
      "*/" <> Path.basename(arg)
    else
      arg
    end
  end

  defp wildcard_temp_arg(arg, _tmp), do: arg

  # Headers alone are not enough, and the gap is not hypothetical.
  #
  # Every provider here authenticates with `Authorization`, which is filtered
  # — so nothing leaks on the way *out*. What comes *back* is the problem: an
  # OAuth refresh answers with a fresh access token and, for Resend, a rotated
  # refresh token, both in the response body. A recording that happens to
  # cross a token expiry writes a live, long-lived credential into a file that
  # gets committed, and nothing about the cassette looks unusual afterwards.
  #
  # Presigned S3 URLs are the other one: SigV4 puts the access key id and the
  # signature in the query string, where a header filter never looks.
  # Four is enough for the epic: a project has at most `prod` and `uat`, and a
  # criterion that provisions both twice is the widest case there is. A fifth
  # distinct key would collide with the first, which degrades to the old
  # single-key behaviour rather than to anything unsafe.
  @replay_keypairs [
    {"age1lq9vzddcuspetghwdddfs28wxyzu5hrz9rj0wwqtnl2zq8w3pc6qy8e9yt",
     "AGE-SECRET-KEY-1H4P3933A0Y5GE7SFJYXTANPNPWVKZMJGWRZZVTD60QGKNH26AY6QN6MJM4"},
    {"age1dejwx5cnp9q689dhq93cdjwawvwqy9v8axs8x6gt8z62xsztz3eq0u7l6s",
     "AGE-SECRET-KEY-1EJWM9AEXKZKZKHH5R5L0VSV5VUHAPFQSJUTZ4RHJ0R2X92UUTYLS2T3C36"},
    {"age1jdsx0katyxc0vu56jm387ann7mfdme3u47lax7x8w4e6kyzjgfjsg2sj0c",
     "AGE-SECRET-KEY-1MHKPEY7QLYX3JZ9SNRVJ003XF3ZAV9ELRXJPKUREJAXGDVQ8RNNQ6MEGJC"},
    {"age12gswm4kz6pswkhtyzrqaaw5ac9a9sxn5n960d2mjxhkchgp5kezq2q29yr",
     "AGE-SECRET-KEY-1GLU5CYDL9MHXCFYCZZTNS7YA5RT56N0M4PT40A2DVNJ0DCN4TU7SGPFTRH"}
  ]

  @doc """
  The fixed keypairs recordings replay with.

  Exposed so the credential audit can tell these from a leak. They are the one
  case where a real age secret key belongs in the repository, and the audit
  cannot know that by looking — a rule that guessed from shape would have to
  choose between missing real keys and flagging these forever.
  """
  def replay_keypairs, do: @replay_keypairs

  # Rebuilds `age-keygen`'s output around one of the fixed pairs, keeping the
  # shape `Sops.parse_key/1` reads: the stderr line, the comments, then the
  # secret. The recorded public key picks the pair, so the mapping is stable
  # across every interaction in a cassette and across re-scrubs of the same
  # recording.
  # Leaves a pool secret as it found it; anything else is a real key and is
  # replaced. Idempotent by construction, which is what the block rule needs to
  # survive the filters being applied twice.
  @doc false
  def redact_bare_secret(match) do
    if Enum.any?(@replay_keypairs, fn {_pub, secret} -> secret == match end),
      do: match,
      else: elem(hd(@replay_keypairs), 1)
  end

  @doc false
  def replay_keypair(match) do
    recorded_public =
      case Regex.run(~r/# public key: (age1[a-z0-9]+)/, match) do
        [_, key] -> key
        _ -> match
      end

    # Already rewritten, so leave it exactly as it is. Without this the pair
    # stays internally consistent but *drifts* on every pass — pool[2] becomes
    # pool[3] becomes pool[1] — and these filters run on write and again on
    # read-back for matching. A stored value that the matcher recomputes
    # differently is precisely a "No matching interaction" miss, which is the
    # failure this whole keypair change set out to stop.
    if Enum.any?(@replay_keypairs, fn {public, _} -> public == recorded_public end) do
      match
    else
      rewrite_around(recorded_public)
    end
  end

  defp rewrite_around(recorded_public) do
    index = :erlang.phash2(recorded_public, length(@replay_keypairs))
    {public, secret} = Enum.at(@replay_keypairs, index)

    "Public key: #{public}\n# created: 2026-01-01T00:00:00-00:00\n" <>
      "# public key: #{public}\n#{secret}"
  end

  @doc false
  def sensitive_patterns do
    [
      # age keypairs. `age-keygen` writes both halves to stdout, so they land
      # in command cassettes; the secrets step generates one per environment.
      #
      # The whole block is rewritten at once, both halves together, because
      # the two previous attempts each broke replay by treating them
      # separately:
      #
      #   `<REDACTED>` — `Sops.parse_key/1` matches `AGE-SECRET-KEY-[A-Z0-9]+`
      #   and `<` is not in that class, so the step reported `:unparsable_key`.
      #
      #   `AGE-SECRET-KEY-1REDACTED000…` — shaped like a key and accepted by
      #   our regex, but age rejects the bech32 checksum, so `public_key/1`
      #   could never derive from it. Worse, only the *secret* was scrubbed:
      #   the real public keys stayed in the cassette, so replay produced a
      #   mismatched pair and nothing could open what it had encrypted.
      #
      # These are real keypairs, generated once, deliberately public, and they
      # protect nothing — a recording replays them into a temp directory.
      # Chosen by hashing the recorded public key, so two environments that
      # recorded different keys still replay as different keys, and the same
      # recorded key always maps to the same replacement.
      # Order matters, and it is the opposite of the obvious one. The bare rule
      # runs *first* so no real secret survives anywhere — including one echoed
      # in an error message, which is not inside an `age-keygen` block and
      # which the block rule would miss. The block rule then runs over the
      # result: it selects on the *public* key, still real at that point, so it
      # rewrites both halves to a matching pair.
      #
      # A key already in the pool is left alone, and that is load-bearing
      # rather than an optimisation. These filters get applied more than once
      # — on write and again on read-back — and a bare rule that always wrote
      # the same secret reset it on every pass while the public half kept what
      # the block rule had written. A fresh recording came out with four of
      # five pairs mismatched: pool[3]'s public against pool[0]'s secret.
      # Passing pool keys through makes re-application harmless.
      {~r/AGE-SECRET-KEY-[A-Z0-9]+/, &redact_bare_secret/1},
      {~r/(?:Public key: age1[a-z0-9]+\n)?# created: [^\n]*\n# public key: age1[a-z0-9]+\nAGE-SECRET-KEY-[A-Z0-9]+/,
       &replay_keypair/1},
      # PEM private keys, for the same reason — anything that prints a key.
      {~r/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/,
       "-----BEGIN PRIVATE KEY-----<REDACTED>-----END PRIVATE KEY-----"},
      # OAuth token payloads, whichever provider shape they arrive in.
      {~r/"(access_token|refresh_token|id_token|client_secret)"\s*:\s*"[^"]*"/,
       ~S("\1": "<REDACTED>")},
      # Form-encoded equivalents, which is how token endpoints are called.
      {~r/\b(access_token|refresh_token|client_secret|code_verifier)=[^&"\s]+/,
       ~S(\1=<REDACTED>)},
      # SigV4 in a query string — presigned URLs carry both halves.
      {~r/X-Amz-Credential=[^&"\s]+/, "X-Amz-Credential=<REDACTED>"},
      {~r/X-Amz-Signature=[^&"\s]+/, "X-Amz-Signature=<REDACTED>"},
      # Recognisable credential shapes, wherever they turn up. Cheap, and they
      # catch the case nobody predicted — a token echoed in an error message.
      #
      # No age rule here: the one above already covers the pattern and replaces
      # it with something `Sops.parse_key/1` can still parse. A second rule for
      # the same pattern ran after it and overwrote the valid placeholder with
      # `<REDACTED-AGE-KEY>`, which is exactly the unparseable shape the first
      # rule exists to avoid — the two arrived from different branches and both
      # survived the merge.
      {~r/\bgh[pous]_[A-Za-z0-9]{20,}/, "<REDACTED-GITHUB-TOKEN>"},
      {~r/\bcfat_[A-Za-z0-9]{20,}/, "<REDACTED-CLOUDFLARE-TOKEN>"},
      {~r/\bre_[A-Za-z0-9_-]{20,}/, "<REDACTED-RESEND-KEY>"}
    ]
  end

  # Belt and braces on the response body, because a regex over serialised JSON
  # is guessing at structure. This walks the parsed body instead, so a token
  # nested somewhere the pattern did not anticipate still gets redacted.
  @doc false
  def redact_token_fields(response) do
    case response do
      %{"body_json" => body} when is_map(body) ->
        Map.put(response, "body_json", redact(body))

      _ ->
        response
    end
  end

  @secret_keys ~w(access_token refresh_token id_token client_secret secret
                  private_key secret_access_key password token)

  @doc false
  def redact(%{} = map) do
    Map.new(map, fn
      {k, v} when is_binary(v) ->
        if k in @secret_keys, do: {k, "<REDACTED>"}, else: {k, redact(v)}

      {k, v} ->
        {k, redact(v)}
    end)
  end

  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  def redact(other), do: other

  @doc "Whether cassettes are being recorded this run."
  def recording?, do: cassette_mode() == :record

  @doc """
  Start a cassette session that lasts as long as the test.

  Registered before anything else registers a teardown, so it is torn down
  last — `on_exit` callbacks run in reverse, and the teardown blocks use
  cassettes of their own.
  """
  @spec start_cassette_session() :: :ok
  def start_cassette_session do
    session = ReqCassette.start_shared_session()
    Process.put(:cms_cassette_session, session)

    ExUnit.Callbacks.on_exit(fn -> ReqCassette.end_shared_session(session) end)

    :ok
  end

  # The test's session when there is a live one.
  #
  # Checked rather than assumed: the session is an `Agent.start_link`, so it is
  # linked to the process that started it and dies with it. A block entered
  # after that — a teardown running in `on_exit`, or anything after a crashed
  # test — would otherwise be handed a dead pid and fail with `shared session
  # Agent is not alive`, which is the error this whole change is about.
  #
  # Falling back to `shared: true` gives that block its own session, which is
  # what it had before and is correct for a block that is on its own anyway.
  @doc false
  @spec cassette_session(keyword()) :: keyword()
  def cassette_session(opts) do
    case Process.get(:cms_cassette_session) do
      pid when is_pid(pid) -> session_opt(opts, pid, Process.alive?(pid))
      _ -> Keyword.put_new(opts, :shared, true)
    end
  end

  defp session_opt(opts, pid, true), do: Keyword.put_new(opts, :session, pid)
  defp session_opt(opts, _pid, false), do: Keyword.put_new(opts, :shared, true)

  # Provider refusals that are about *our account*, not about the story.
  #
  # A recording that captures one of these writes a failure in as the expected
  # behaviour, and it then replays green-ish forever while proving nothing.
  # Three have bitten already: a NoSuchBucket from signing against the wrong
  # provider, an InvalidAccessKeyId from a project with no credentials, and a
  # server-limit 403 from a recording sweep that had eaten its own headroom —
  # that last one poisoned eight cassettes before anyone noticed.
  #
  # 412 `resource_unavailable` is deliberately NOT here: Hetzner answers that
  # for every create before the architecture fallback succeeds, so it is a
  # normal part of a healthy recording.
  @poison ~w(resource_limit_exceeded InvalidAccessKeyId NoSuchBucket unauthorized)

  @doc """
  Refuse a recording that captured a refusal about our own account.

  Raises at the moment of recording rather than letting the cassette be
  discovered as wrong a day later by a spex that reads it as the story's
  behaviour. The cassette is set aside as `.rejected` rather than deleted, so
  the evidence survives for whoever has to work out which limit was hit.
  """
  @spec refuse_poisoned_cassette(String.t()) :: :ok
  def refuse_poisoned_cassette(name), do: refuse_poisoned_cassette(name, recording?())

  # Recording only. On replay the cassette is an input, not an output — reading
  # one that already carries poison is a diagnosis for whoever recorded it, and
  # renaming it mid-replay would destroy the very file the run is reading.
  defp refuse_poisoned_cassette(_name, false), do: :ok

  defp refuse_poisoned_cassette(name, true) do
    path = Path.join("test/cassettes", name <> ".json")

    case File.read(path) do
      {:ok, body} -> check_poison(path, body, Enum.filter(@poison, &String.contains?(body, &1)))
      _ -> :ok
    end
  end

  defp check_poison(_path, _body, []), do: :ok

  defp check_poison(path, _body, found) do
    File.rename(path, path <> ".rejected")

    raise """
    refusing to keep this recording: it captured #{Enum.join(found, ", ")}.

      #{path}

    That is a refusal about this account, not about the story — a limit
    reached, a credential missing, a bucket signed for at the wrong provider.
    Kept as #{Path.basename(path)}.rejected so you can see which.

    Recording it would make the failure the story's expected behaviour, and it
    would then replay forever without ever touching a provider again.

    Fix the account condition and record again. For the server limit: this
    account allows 5 and two are permanently in use, so a recording has three
    slots — check headroom, not just residue, and make sure the criteria you
    are recording tear down what they make.
    """
  end

  @doc """
  Set a cassette aside the first time this run asks to record it, and never
  again.

  Both cassette libraries load whatever is on disk and append to it, so a
  recording accumulates across runs unless something clears it — and clearing
  it on every entry is worse, because a spex that enters the same cassette
  twice then keeps only the second half.

  Renamed to `.bak` rather than deleted. Re-recording starts by getting rid of
  the old recording and ends by writing a new one, so a run that dies in
  between destroys a cassette and puts nothing in its place —
  `content_publish_single_command.json` went that way and existed in no
  checkout, no branch and no backup, because it had never been committed. The
  cost of keeping the previous one is a file; the cost of not keeping it is a
  recording session against real infrastructure.

  Keyed in `:persistent_term`, which lasts exactly as long as the VM and so
  means "this `mix spex` run" without anything needing to be started or torn
  down.
  """
  @spec clear_cassette_once(String.t(), String.t()) :: :ok
  def clear_cassette_once(name, dir) do
    key = {__MODULE__, :cassette_cleared, dir, name}

    case :persistent_term.get(key, :fresh) do
      :cleared ->
        :ok

      :fresh ->
        path = Path.join(dir, name <> ".json")
        File.rename(path, path <> ".bak")
        :persistent_term.put(key, :cleared)
    end
  end

  @doc """
  Run `fun` with a cassette wired into every provisioning provider.

  `ReqCassette.with_cassette/3` hands the block a Req plug, and a provider only
  uses it if that plug is in its application environment — the two halves have
  to be connected or the block runs against the live API while a cassette sits
  unused beside it. Doing that per spex is 80-odd chances to connect them
  wrongly, and the failure mode when you do is a spex that passes by making
  real HTTP calls.

  Every provider is wired, not just the one a given step is expected to use.
  A step that reaches two providers is exactly the case a per-provider helper
  gets wrong, and the cassette records what actually happened rather than what
  the spex author predicted.

  ## Recording

  Mode comes from the `SPEX_CASSETTE_MODE` environment variable, defaulting to
  `:replay`. To record against the real providers:

      SPEX_CASSETTE_MODE=record mix spex --pattern "test/spex/968_*/*_spex.exs"

  Cassettes are recorded from real calls; hand-written ones encode the
  author's assumptions, which is precisely what the recording is meant to
  check.

  ## Matched on method and URI, deliberately not headers or body

  The default also matches headers and body, which makes a cassette break for
  reasons that are not about behaviour: the `authorization` header differs
  between the recording session and every replay, and the body changes
  whenever a request payload is legitimately corrected. Both produce a red
  spex that says nothing about the story.

  Authorization is filtered out of what gets written, so a recording never
  puts a live token in the repository.
  """
  @spec with_provider_cassette(String.t(), keyword(), (-> any())) :: any()
  def with_provider_cassette(name, opts \\ [], fun) when is_function(fun, 0) do
    # Recording publishes DNS from cold and then waits for a provider to see
    # it, which takes longer than the production default allows for. On
    # replay the wait is irrelevant — the cassette answers immediately — so
    # the longer window costs nothing there.
    if opts[:mode] == :record or cassette_mode() == :record do
      # Merged, not replaced. Replacing threw away whatever the spex had
      # already staged — a probe, a deploy script, a host — so a spex that set
      # one up and then entered a cassette silently lost it and exercised the
      # real thing instead. That surfaced as the TLS step reporting the host
      # did not answer over HTTPS, which is true and has nothing to do with
      # what the spex was asserting.
      Application.put_env(
        :code_my_spec,
        :provisioning_step_opts,
        Keyword.merge(
          [attempts: 60, interval_ms: 5_000],
          Application.get_env(:code_my_spec, :provisioning_step_opts, [])
        )
      )
    else
      # Replay waits on nothing: the cassette answers a poll instantly, so the
      # interval between attempts is pure sleep. Left at its production
      # default, a step that polls a dozen times sat in one LiveView event for
      # long enough that the client timed out and took the sandbox connection
      # down with it — which surfaces as a DBConnection error and says nothing
      # about the sleeping.
      #
      # SSH is the same argument with a sharper edge. The registry step waits
      # for a freshly created box to answer — 90 attempts, 2s apart — which is
      # right when a box is genuinely booting and pure loss on replay, where
      # the address is a fiction the cassette supplied and nothing will ever
      # answer at it. Left alone it spent exactly 180s and ExUnit killed the
      # test on its timeout, which is how 8003 and 7965 started failing for a
      # wait rather than for anything they assert.
      #
      # One attempt, not zero: the step should still find out that nothing is
      # there, and say so, rather than proceed as though the box answered.
      Application.put_env(
        :code_my_spec,
        :provisioning_step_opts,
        Keyword.merge(
          Application.get_env(:code_my_spec, :provisioning_step_opts, []),
          interval_ms: 0,
          ssh_attempts: 1,
          ssh_interval_ms: 0
        )
      )
    end

    opts =
      opts
      |> Keyword.put_new(:mode, cassette_mode())
      # The body too, because without it two creates are the same request.
      #
      # `:record` mode replays whenever a recorded interaction matches, so
      # `POST /v1/servers {"name":"…-uat"}` matched the `…-prod` create
      # recorded seconds earlier and was handed prod's response. The step
      # believed it had UAT's box, recorded production's against the UAT
      # environment, and the deploy failed with "the provider has no such
      # server". Nothing in the recording showed a create for UAT, because
      # none was ever made.
      #
      # Headers stay out of the match — `authorization` differs between the
      # recording and every replay, which is the reason this list was narrowed
      # in the first place. The body is what tells two resources apart, and
      # `filter_sensitive_data` scrubs it before it is written.
      |> Keyword.put_new(:match_requests_on, [:method, :uri, :body])
      # …but a body that carries a freshly generated key can never match one.
      #
      # `generate_access_key/2` shells out to `ssh-keygen`, so every run mints a
      # different public half and `POST /v1/ssh_keys` arrives with a body no
      # recording can hold. Adding `:body` to the match — which was right, and
      # is what stopped a UAT create being handed production's response — made
      # that fatal rather than harmless.
      #
      # It is worth being precise about the blast radius, because it looked for
      # a while like the 412 placement fallback: every criterion that creates a
      # server creates a key first, so this one mismatch is the first request to
      # miss, and everything after it in the run never happens. The step reports
      # a cassette miss and the criterion reports nothing provisioned.
      #
      # Normalised on both sides. `filter_request` runs against the incoming
      # request before matching on replay and before writing on record, so the
      # stored body and the live one agree — while `:body` keeps telling a UAT
      # create apart from a production one, which is the whole reason it is in
      # the list.
      |> Keyword.put_new(:filter_request, &normalize_volatile_request/1)
      # Sequential, because several steps poll: bucket readiness, Resend's
      # domain verification, server boot. Matching only on method and URI
      # makes every poll iteration the same request, so the cassette answers
      # the first recorded response forever — a readiness check gets its
      # initial 404 back twenty times and reports the resource unusable.
      # Sequential consumes one interaction per request, so a recorded
      # 404,404,200 replays as 404,404,200.
      |> Keyword.put_new(:sequential, true)
      # Sequential state is per-process, and every step now runs in a
      # supervised task — a deploy takes minutes and cannot be held inside a
      # LiveView event. So each step began at the top of the cassette and
      # replayed the earliest matching interaction: the deploy step's
      # `GET /servers` was answered with the list recorded before any server
      # existed, and it reported that the box the previous step had just
      # created was not there.
      #
      # A shared session puts the cursor in an Agent, where every process sees
      # the same one. It belongs to the *test*, not to one `with_cassette`
      # block: `shared: true` starts and stops an Agent around each block, and
      # a supervised step that outlives its block then reaches a dead one —
      # `ReqCassette shared session Agent is not alive`. Started in setup and
      # ended in `on_exit` is the library's own documented shape for this.
      |> cassette_session()
      |> Keyword.put_new(:filter_request_headers, ["authorization", "cookie"])
      |> Keyword.put_new(:filter_response_headers, ["set-cookie"])
      |> Keyword.put_new(:filter_sensitive_data, sensitive_patterns())
      |> Keyword.put_new(:filter_response, &redact_token_fields/1)

    # `:record` appends to an existing cassette and replays anything already
    # in it, so a cassette written during a failed attempt poisons every run
    # after it — a stale token recorded one 401 and then served that 401
    # forever, which reads exactly like an auth bug that will not go away.
    # Deleting first makes re-recording mean what it says.
    #
    # Once per run, though, not once per entry. A spex that enters the same
    # cassette twice — a `given_` that runs the early steps, then the later
    # ones — had its first block deleted by its second, so the file on disk
    # held only the tail of the run. That is unreplayable, and worse, it threw
    # away the recording of the steps that failed: several cloud cycles went
    # into "why is there no server" with the answer sitting in a file that had
    # been erased moments after it was written.
    if opts[:mode] == :record do
      clear_cassette_once(name, opts[:cassette_dir] || "test/cassettes")
    end

    result =
      ReqCassette.with_cassette(name, opts, fn plug ->
        previous = Enum.map(provider_modules(), &{&1, Application.get_env(:code_my_spec, &1, [])})

        for module <- provider_modules() do
          Application.put_env(
            :code_my_spec,
            module,
            Keyword.put(Application.get_env(:code_my_spec, module, []), :plug, plug)
          )
        end

        try do
          fun.()
        after
          for {module, config} <- previous, do: Application.put_env(:code_my_spec, module, config)
        end
      end)

    # Here rather than in `with_full_cassette/3`, which is where it started and
    # where it covered almost nothing: 841, 963, 965, 966 and 969 all drive
    # providers through *this* function directly, so the guard never saw them.
    # It showed up as `841_1962_uat_only_complete_setup` keeping a
    # `403 resource_limit_exceeded` with no `.rejected` file beside it — a
    # recording of the account being full, replayed ever after as the story's
    # behaviour. `with_full_cassette/3` wraps this, so both paths are covered
    # from here.
    #
    # Per entry rather than once per run. The check only ever raises on poison,
    # so running it more often can only catch it sooner — and a spex that enters
    # the same cassette twice gets its first block checked before the second
    # appends to it.
    refuse_poisoned_cassette(name)

    result
  end

  @doc "Every provider whose HTTP a cassette should capture."
  def provider_modules do
    [
      CodeMySpec.Provisioning.Hetzner,
      CodeMySpec.Provisioning.Cloudflare,
      CodeMySpec.Provisioning.Resend,
      # DNS-over-HTTPS is an ordinary HTTP call, so public-resolver checks
      # record and replay like any other provider. Without it here, a spex
      # asserting "this resolves" hits real DNS on replay and fails as soon as
      # the record it asserted on has been torn down.
      CodeMySpec.Provisioning.Dns,
      CodeMySpec.GitHub,
      CodeMySpec.Content.S3Client,
      # The publish trigger is an ordinary HTTP POST to the deployed site, and
      # it was the one provider call escaping the cassette — so a replay sent it
      # to the real network, got nothing, and `trigger_client/2` failed the whole
      # publish. The criteria then reported that no objects were written, which
      # is true and says nothing about storage: the objects were never attempted
      # because the step gives up before them.
      #
      # It already reads a `:plug` from its own app env, exactly like the others.
      # It was only missing from this list.
      CodeMySpec.Content.TriggerClient,
      # And the same again, for the same reason. The widget step fetches the
      # deployed site to see whether the widget is on it; that GET was the only
      # request in story 973 leaving the cassette. The criteria passed while a
      # site happened to be running on this machine and failed everywhere else,
      # which is indistinguishable from a widget that does not install.
      CodeMySpec.Provisioning.Widget,
      # Three modules have now had this exact bug: each reads a `:plug` out of
      # its own app env, ready to be recorded, and was never handed one because
      # nobody added it to this list. The publish's render check is the third —
      # it fetches the post back from the deployed site, and that GET went to
      # the real network on every replay, so 972's criteria only passed where a
      # site was running. If a module reads a plug, it goes here.
      CodeMySpec.Provisioning.ContentPublishing
    ]
  end

  # An SSH public key is the one part of a recorded body that cannot be the same
  # twice: `generate_access_key/2` runs `ssh-keygen` per run.
  #
  # Replaced rather than dropped, so the field still has to be *present* and
  # still has to be a key — a request that stopped sending one would no longer
  # match, which is the point of matching on the body at all.
  #
  # The comment is the value, so a cassette that has been through here says so
  # to whoever reads it next.
  @normalized_public_key "ssh-ed25519 AAAA-normalized-by-spex-cassette-filter spex"

  @doc false
  @spec normalize_volatile_request(map()) :: map()
  def normalize_volatile_request(%{"body_json" => body} = request) when is_map(body) do
    %{request | "body_json" => normalize_body(body)}
  end

  def normalize_volatile_request(request), do: request

  # Same problem: the inbound probe mints a fresh subject and recipient per run,
  # so its `POST /emails` body never matches. The domain survives, so `:body`
  # still tells one domain's probe from another's.
  @normalized_probe_subject "cms-inbound-normalized-by-spex-cassette-filter"
  @normalized_probe_user "user-normalized-by-spex-cassette-filter"

  defp normalize_body(%{"public_key" => key} = body) when is_binary(key),
    do: %{body | "public_key" => @normalized_public_key}

  defp normalize_body(%{"subject" => "cms-inbound-" <> _} = body) do
    body
    |> Map.put("subject", @normalized_probe_subject)
    |> Map.replace_lazy("to", &normalize_probe_recipients/1)
  end

  defp normalize_body(body), do: body

  defp normalize_probe_recipients(to) when is_list(to),
    do: Enum.map(to, &normalize_probe_recipient/1)

  defp normalize_probe_recipients(to), do: normalize_probe_recipient(to)

  defp normalize_probe_recipient(address) when is_binary(address) do
    String.replace(address, ~r/^user-\d+@/, @normalized_probe_user <> "@")
  end

  defp normalize_probe_recipient(address), do: address

  def cassette_mode do
    case System.get_env("SPEX_CASSETTE_MODE") do
      "record" -> :record
      "replay" -> :replay
      _ -> :replay
    end
  end

  @doc """
  Register teardown of everything the named steps provisioned.

      setup :connect_providers
      ...
      given_ "...", context do
        tear_down_after(context.scope, [:storage])
        ...
      end

  ## Why `on_exit` rather than a step in the scenario

  A teardown written as the last `then_` only runs when the ones before it
  passed — so the run that leaks resources is precisely the run that failed,
  which is the one you least want leaking. `on_exit` runs either way. It also
  removes the ordering trap: teardown must not run before a criterion asserts
  the resource *exists*, and "after the test" is that guarantee without each spex
  having to remember it.

  ## Teardown gets its own cassette

  `on_exit` fires after the scenario's cassette has closed, so teardown HTTP
  would otherwise go live on every replay — against placeholder credentials,
  which either errors noisily or, if the credentials happen to be real, does
  something much worse. A separate cassette means recording does the real
  cleanup and captures it, and replay exercises the teardown path while
  touching nothing.

  Failure is reported rather than swallowed: a teardown that quietly gave up
  leaves resources somebody pays for, which is the failure this exists to
  prevent.
  """
  def tear_down_after(scope, keys, opts \\ []) when is_list(keys) do
    # Per spex, not per step. Every spex tearing down storage wrote to one
    # `teardown_storage` cassette, so the last recorder won and the others
    # replayed a teardown of somebody else's buckets. The project name is
    # already unique per spex and is what the resource names derive from, so
    # it is the right thing to key on.
    name =
      Keyword.get(opts, :cassette) ||
        "teardown_#{slug(project_name(scope))}_#{Enum.join(keys, "_")}"

    teardown_later(name, name, fn ->
      for {key, result} <- tear_down_steps_with_retry(scope, keys, opts) do
        case result do
          {:ok, _removed} ->
            :ok

          {:error, {:left_behind, remaining}} ->
            IO.warn(
              "spex teardown left #{key} resources behind: " <>
                inspect(Enum.map(remaining, & &1.location))
            )
        end
      end
    end)
  end

  # -- Auth setup helpers (mirror ConnCase, but route through Fixtures only) --

  @doc """
  Setup helper that registers and logs in a user.

      setup :register_and_log_in_user
  """
  def register_and_log_in_user(%{conn: conn} = context) do
    user = Fixtures.user_fixture(%{email: spex_user_email(context)})
    scope = Fixtures.user_scope_fixture(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  # Stable per spex file, because the inbound probe sends to an address built
  # from this local part.
  #
  # `owner_address/2` takes the user's email local part and puts it on the
  # project's domain, so with `unique_user_email/0` the recording captured a
  # message to `user-576460752303406782@…` and replay went looking for
  # `user-<a different integer>@…`. `received?/3` compares the recipient
  # exactly — correctly, since a message to somebody else's inbox proves
  # nothing — so it never matched, the poll ran to its limit and exhausted the
  # cassette. Story 974 recorded green and replayed red for that reason alone.
  #
  # Shape is deliberate. `phash2` keeps it `user-<digits>`, which is what
  # delivered when recording; a readable local part like `spex-probe@` did not
  # arrive, twice. `default_inbound_probe/3` warns that Resend drops invented
  # local parts silently, so this stays as close to the known-good form as a
  # deterministic value can.
  #
  # Unique per file rather than constant: the sandbox isolates each test, but a
  # single test that registers two users would otherwise collide on the email
  # index.
  defp spex_user_email(%{module: module}) when is_atom(module),
    do: "user-#{:erlang.phash2(module)}@example.com"

  defp spex_user_email(_context), do: "user-#{System.unique_integer([:positive])}@example.com"

  @doc """
  Setup helper that sets up an active account for the user.

      setup :setup_active_account
  """
  def setup_active_account(%{user: user} = context) do
    account = Fixtures.account_with_owner_fixture(user)
    updated_scope = Fixtures.user_scope_fixture(user, account)

    Fixtures.select_active_account(updated_scope, account.id)

    Map.merge(context, %{account: account, scope: updated_scope})
  end

  # Setup helper that sets up an active project for the user.
  @doc """
  Say this project is meant to be deployed.

  `devops` defaults to `:off` — infrastructure is opt in, because every project
  is a project and only some are meant to have servers. A criterion whose
  premise is "a project that does DevOps" has to say so, rather than inheriting
  it from whatever the default happens to be that week.

  Add `setup :devops_on` above any spex whose subject is the DevOps routine.
  """
  def devops_on(%{scope: scope} = context) do
    Fixtures.enable_devops(scope)

    context
  end

  @doc """
  Sam's provider credentials are on file.

      setup :provider_credentials_on_file

  Separate from `devops_on` on purpose: "devops is enabled" and "the tokens are
  pasted in" are different premises, and a criterion about one must not pass by
  accident on the other.

  Without this, anything that runs setup stops at
  `hetzner: :hetzner_not_configured` before it reaches a provider — so the
  criterion fails on its own premise, and a recording of it captures nothing
  because no request was ever made.

  Real values when recording, placeholders otherwise; `store_provider_secrets/1`
  reads the environment for each. Proving a credential against a real provider
  is story 964's claim, not anyone else's.
  """
  def provider_credentials_on_file(%{scope: scope} = context) do
    Fixtures.store_provider_secrets(scope)

    context
  end

  @doc """
  Production is off; UAT is the whole plan (`devops: :uat`).

  Separate from `devops_on` because "Sam opted out of prod" is a different
  premise from "Sam has not set devops up", and a criterion about the first
  must not pass by accident on the second.
  """
  def devops_uat_only(%{scope: scope} = context) do
    Fixtures.set_devops(scope, :uat)

    context
  end

  @doc """
  DevOps is off (`devops: :off`).

  Already the default, and stated anyway: a criterion whose subject is what
  happens when devops is off should not depend on the default staying put.
  """
  def devops_off(%{scope: scope} = context) do
    Fixtures.set_devops(scope, :off)

    context
  end

  def setup_active_project(%{user: user, account: account, scope: scope} = context) do
    # Create a real stub directory with a mix.exs to satisfy the
    # WorkingDir plug (which hits File.exists?/File.dir? directly). Real
    # file I/O still goes through the in-memory environment — the stub
    # dir is just a marker for the plug and the project's local_path.
    stub_dir = Path.join(System.tmp_dir!(), "spex-#{System.unique_integer([:positive])}")
    File.mkdir_p!(stub_dir)
    File.write!(Path.join(stub_dir, "mix.exs"), "# stub for WorkingDir plug\n")
    # Real subdirs so FileWatcherServer.start_watcher/1 finds watchable
    # roots and doesn't error with :no_watchable_dirs. The memfs still
    # owns content; these are just empty directories on disk.
    File.mkdir_p!(Path.join(stub_dir, "lib"))
    File.mkdir_p!(Path.join(stub_dir, "test"))
    File.mkdir_p!(Path.join(stub_dir, ".code_my_spec/spec"))
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(stub_dir) end)

    env = Fixtures.memory_environment_fixture(working_dir: stub_dir)

    # Derived from the spex module, which makes it unique across spex and
    # identical across runs. Both halves are load-bearing:
    #
    # Unique, because provisioning turns the project name into real resource
    # names. Every spex sharing the fixture's "some name" derived the same
    # bucket — `some-name-prod` — so one spex's teardown deleted the buckets
    # another was still using: green alone, red together, and it reads as
    # flaky infrastructure rather than a name collision.
    #
    # Stable, because those names end up in recorded URLs. A counter made
    # every replay ask for a bucket the cassette had never heard of.
    project =
      Fixtures.project_fixture(scope,
        name: project_name_for(context),
        account_id: account.id,
        local_path: stub_dir,
        client_user_id: user.id
      )

    # Register the env so Scope.for_local_project (called by LiveViews that
    # rebuild scope from project) returns THIS env instead of a default
    # :local env. Registration is monitored — when the test process exits
    # the entry is cleaned up automatically.
    Fixtures.register_environment(project.id, env)
    ExUnit.Callbacks.on_exit(fn -> Fixtures.unregister_environment(project.id) end)

    updated_scope =
      user
      |> Fixtures.user_scope_fixture(account, project)
      |> Map.put(:cwd, stub_dir)
      |> Map.put(:environment, env)

    Fixtures.select_active_project(updated_scope, project.id)

    # The spex suite exercises the full development workflow — spec files,
    # design reviews, unit tests and everything gated on them. A fresh project
    # now defaults those three toggles OFF (it writes BDD spex and code and
    # nothing else), which is the right product default and the wrong baseline
    # for these specs: it silently removed the spec/review/test nodes from the
    # graph and took about seventy spex down with it, none of which mention a
    # configuration.
    #
    # Set here rather than in seventy files. Story 671's specs are about the
    # toggles themselves and drive the configuration LiveView explicitly, so
    # they override this and keep testing what they always tested.
    Fixtures.require_all!(updated_scope)

    Map.merge(context, %{project: project, scope: updated_scope, environment: env})
  end

  @doc """
  Setup helper that creates a fully-satisfied story with an active
  `qa_complete` session task.

  Applies the full project + story chain (project_setup → qa_setup,
  component subgraph, three_amigos_complete, bdd_specs_exist/passing)
  but leaves qa_complete open so the spex drives it.

  Requires context from `setup_active_project`. Produces:
  - `context.story` — the created story struct
  - `context.task_id` — an active `qa_complete` session task id
  - `context.session_id` — the external conversation id of the seeded session
  - `context.persona_id` and `context.persona_slug` (from project kickoff)
  - `context.component` — the synced architecture component

  Used by Stories 726 and 727 spex — all QA tool specs need a story with
  a valid session task so `submit_qa_result` can resolve `story_id` and
  `agent_id` from the session's tasks JSONB.

      setup :setup_active_project
      setup :setup_qa_story_task
  """
  def setup_qa_story_task(context) do
    # Apply the full project + story chain (component subgraph + three_amigos
    # + bdd_specs) but NOT qa_complete — the spex drives that itself.
    context = CodeMySpecSpex.FullSatisfactionFixtures.apply_without_qa_story(context)

    scope = context.scope
    story = context.story

    # Create an active session with a qa_complete task for this story
    {_story, task_id, session} = Fixtures.qa_story_task_fixture(scope, story: story)

    Map.merge(context, %{
      story: story,
      task_id: task_id,
      session_id: session.external_conversation_id
    })
  end

  @doc """
  Setup helper that registers, logs in, and sets up an active account.
  """
  def register_log_in_setup_account(context) do
    context
    |> register_and_log_in_user()
    |> setup_active_account()
  end

  @doc """
  Logs the given `user` into the `conn`.
  """
  def log_in_user(conn, user) do
    token = Fixtures.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  @doc """
  Synchronously drains the channel's mailbox so callbacks like
  `:after_join` have run before the next observation.

  Phoenix channels send `:after_join` to themselves and process it
  asynchronously. Without this barrier, a test that joins a channel
  and then immediately observes the LiveView can see stale state —
  the channel hasn't yet called `Presence.track`, so no diff has
  been broadcast.

  Use after `subscribe_and_join/3`:

      {:ok, _reply, channel_socket} = subscribe_and_join(...)
      wait_for_channel(channel_socket)
  """
  def wait_for_channel(%Phoenix.Socket{channel_pid: pid} = socket) do
    :sys.get_state(pid)
    socket
  end
end
