defmodule CodeMySpecSpex.Drill do
  @moduledoc """
  Walk the provisioning sequence by hand, against real providers, keeping
  everything it makes.

  ## Why this exists

  Story 841's criteria are the acceptance gate and a poor debugger. One
  recording provisions two servers, builds a container from scratch and deploys
  it twice — about twenty minutes to observe one line of output, and it halts at
  the first failure, so eight steps behind that failure report nothing. Eight
  drills went into finding a single Let's Encrypt 429 that way, and about half
  of them produced no new information because the change under test was a
  diagnostic message rather than a fix.

  This drives the same code path `RunDevopsSetup` reaches — `Provisioning.run_step/3`,
  verify then execute then record — one step at a time, and *keeps going past a
  failure*. One walk names every broken step rather than the first one.

  ## Why keeping the resources is the point

  Every step adopts what is already there (`origin: "adopted"` throughout), so
  the second walk finds the server, the DNS records, the certificate and the
  buckets already standing and spends its time on the steps that have never
  run. That only holds if the things a fresh database would otherwise
  regenerate stay put:

    * the **SSH key**, or the box adopted from the last run cannot be reached
      with the key this run just generated;
    * the **generated application**, or `git archive HEAD` ships a tree that
      took five minutes to rebuild for no change;
    * the **name**, which is what every provider resource is derived from, and
      which `project_name_for/1` already keys off this module.

  ## Running it

      set -a; source envs/.env; set +a
      CMS_DRILL_APP=/path/to/checkout elixir -S mix test test/drill/provisioning_walk.exs

  ### It needs room for a fifth machine

  `deploy` builds the image on a **builder** server it creates and destroys, so
  a walk needs headroom for one more box than the environments it is making.
  Hetzner counts primary IPs rather than servers, and a dual-stack box holds
  two — so four servers exhaust an eight-IP account and `deploy` fails with

      resource_limit_exceeded … limits: [%{"name" => "primary_ip_limit"}]

  which reads as a leak and is not one: `GET /v1/primary_ips` showed all eight
  assigned to servers that should exist. A walk that reaches `deploy` and stops
  there, with `tls` and `widget` failing behind it, is this and not a defect.

  Options, all through the environment:

    * `CMS_DRILL_STEPS` — comma-separated step keys to run, in sequence order.
      **A subset that omits `server` will not deploy.** Environment rows are
      dropped and recreated on every walk (see `setup_project/1` for why —
      reusing them sent the server step SSHing to a released address), so a
      partial walk discards the server association the later steps read, and
      `deploy` correctly reports that the environment has no server.
      Defaults to the project's whole plan.
    * `CMS_DRILL_ENVIRONMENTS` — `uat` (the default: one box, one deploy) or
      `uat,prod` for the full default plan.
    * `CMS_DRILL_DOMAIN` — defaults to `spex-drill.legwork.ca`. It carries the
      `spex-` marker on purpose, so `mix cms.provisioning_leaks` can still find
      everything this leaves behind.
    * `CMS_DRILL_TEARDOWN=1` — unmake instead of make. Walks the same steps in
      reverse and reports what it removed and what survived. Run it, then run
      the drill again: a cold rebuild is the only thing that proves setup can
      do this from nothing rather than adopt what a previous walk left.
    * `CMS_DRILL_DB=dev` — point at `code_my_spec_dev` instead of the test
      database, so the deployed application and the provisioning being asked
      about it talk to the same CodeMySpec. Needed for the widget and inbound
      proofs, which read messages the deployed app sent.
    * `CMS_DRILL_CONFIRM_APEX=1` — answer the apex guard. `dns` will not
      repoint an apex that already resolves without a person saying go ahead,
      and the only other way to say it is a button in the web UI. Say it here
      only when you know what the name currently points at: on a drill domain
      after a teardown that is a recycled address, and in front of a customer
      it is their live site.

  Not a spex and not a test: the filename has no `_test` suffix, so nothing
  picks it up by accident. It asserts nothing — it reports.
  """

  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.AccountSecrets
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.Sequence
  alias CodeMySpec.Provisioning.Sops
  alias CodeMySpec.Provisioning.Teardown
  alias CodeMySpecSpex.Fixtures

  # Long enough for the full plan against cold infrastructure. The walk does not
  # halt at the first failure, so its worst case is every step's own timeout in
  # a row rather than the first one's.
  @moduletag timeout: :timer.hours(3)
  @moduletag ownership_timeout: :timer.hours(3)

  @default_domain "spex-drill.legwork.ca"

  setup :never_point_the_app_at_production
  setup :keep_what_the_last_walk_left
  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :provider_credentials_on_file
  setup :connect_providers
  setup :persistent_access_key
  setup :persistent_registry_password
  setup :drill_working_directory
  setup :persistent_age_keys
  setup :the_project_under_drill

  test "walk the provisioning sequence", context do
    scope = context.scope
    steps = steps_to_run(context.project)

    banner(scope, steps)
    :persistent_term.put({__MODULE__, :scope}, scope)

    results =
      if tearing_down?() do
        stepped = steps |> Enum.reverse() |> Enum.map(&tear_down_and_report(scope, &1))
        stepped ++ tear_down_environments(scope)
      else
        Enum.map(steps, &run_and_report(scope, &1))
      end

    summarise(results)
  end

  ## The walk

  # Before each step, not once at setup. Resend hands out fifteen-minute access
  # tokens and the borrowed copy cannot renew itself — it travels without its
  # refresh token on purpose.
  #
  # Except it is not worth what it costs. It was added believing an expired
  # token was behind the inbound step's `400 "API key is invalid"`; that turned
  # out to be a stale `provider_error` on the step row, written hours earlier
  # and printed in preference to the pause message. So this fixes a problem
  # that was never happening, and it opens a connection to code_my_spec_dev per
  # step to do it — which, against a Postgres already serving the dev server
  # and other worktrees, reached `too_many_connections`, dropped the grant
  # fetch, and handed every provider a placeholder. Setup-time refresh is
  # enough: `connect_providers` does it, and `usable?/1` re-fetches when the
  # cached grant actually is close to expiry.
  defp run_and_report(scope, key) do
    IO.puts("\n─── #{key} " <> String.duplicate("─", max(0, 60 - String.length(to_string(key)))))
    started = System.monotonic_time(:millisecond)

    outcome = Provisioning.run_step(scope, key, step_opts())

    elapsed = System.monotonic_time(:millisecond) - started
    report(key, outcome, elapsed)
  end

  # After the steps, because the steps own what they recorded and this owns
  # what the environment is.
  #
  # `Teardown.step/3` works from the resources a step recorded, and the apex
  # DNS record is recorded `adopted` — setup found it already there, from the
  # run before. So the step path skips it, every time, and the record outlives
  # the server it points at. Hetzner then recycles the address, and the next
  # run's `dns` step refuses to repoint a name that already resolves, which is
  # correct and leaves the stale record in place. Two right behaviours
  # composing into a subdomain takeover (7f999888).
  #
  # `Teardown.environment/2` is the path that gets this right and was never
  # called: it builds its own resources with `origin: "created"` and removes
  # the DNS record *before* releasing the server, which is the ordering its
  # own docstring exists to explain.
  defp tear_down_environments(scope) do
    Enum.map(environments(), fn name ->
      IO.puts("\n─── environment #{name} " <> String.duplicate("─", max(0, 48 - String.length(name))))
      started = System.monotonic_time(:millisecond)

      outcome =
        case Teardown.environment(scope, name, step_opts()) do
          {:ok, removed} -> {:ok, removed}
          {:error, reason, _removed} -> {:error, reason}
        end

      elapsed = System.monotonic_time(:millisecond) - started
      report_teardown(:"environment #{name}", outcome, elapsed)
    end)
  end


  # unmaking something has the opposite one: the DNS record has to go before
  # the server it points at is released, or the address is recycled to another
  # customer while a name under this domain still resolves to it.
  #
  # `Teardown.step/3` skips anything recorded `adopted`, which is most of what
  # a repeated walk records — so a drill that has adopted its way to green
  # tears down almost nothing and says so honestly. That is the number worth
  # reading here: it is the difference between "setup can rebuild this" and
  # "setup found this already built".
  defp tear_down_and_report(scope, key) do
    IO.puts("\n─── #{key} " <> String.duplicate("─", max(0, 60 - String.length(to_string(key)))))
    started = System.monotonic_time(:millisecond)

    outcome = Teardown.step(scope, key, step_opts())

    elapsed = System.monotonic_time(:millisecond) - started
    report_teardown(key, outcome, elapsed)
  end

  # Counted here rather than taken from `Teardown.step/3`, which returns
  # `{:ok, r}` both for a resource it destroyed and for one it skipped because
  # the resource was recorded `adopted` — and skipping is most of what a
  # repeated walk does. Reading that number as "removed" is how a 9.5-second
  # teardown reported 14/14 and "everything recorded came down" while releasing
  # a server and leaving the DNS record pointing at the released address.
  #
  # The skip itself is right and must stay: teardown once destroyed a real,
  # long-standing Resend sending domain that setup had merely adopted. What was
  # wrong is a summary that cannot tell the two apart, so this says both.
  defp report_teardown(key, {:ok, handled}, elapsed) do
    {skipped, removed} = Enum.split_with(handled, &(origin_of(&1) == "adopted"))

    IO.puts("  removed #{length(removed)}, skipped #{length(skipped)} as adopted, " <>
              "in #{seconds(elapsed)}")

    for resource <- removed, do: IO.puts("    · removed #{resource_line(resource)}")
    for resource <- skipped, do: IO.puts("    · kept    #{resource_line(resource)}")

    %{key: key, state: :done, elapsed: elapsed, reason: nil}
  end

  defp report_teardown(key, {:error, {:left_behind, remaining}}, elapsed) do
    IO.puts("  left behind #{length(remaining)} in #{seconds(elapsed)}")
    for resource <- remaining, do: IO.puts("    · #{resource_line(resource)}")

    %{
      key: key,
      state: :left_behind,
      elapsed: elapsed,
      reason: "still there: " <> Enum.map_join(remaining, ", ", &to_string(&1.location))
    }
  end

  defp origin_of(resource),
    do: Map.get(resource, :origin) || Map.get(resource, "origin") || "adopted"

  defp report(key, {:ok, step}, elapsed) do
    IO.puts("  #{step.state} in #{seconds(elapsed)}")
    for resource <- step.resources || [], do: IO.puts("    · #{resource_line(resource)}")
    %{key: key, state: step.state, elapsed: elapsed, reason: nil}
  end

  # A paused step records its instructions rather than an error and has nothing
  # in `attempted` — it did not fail at anything, it is waiting. Printing the
  # empty field made a step that behaved correctly read like one that broke
  # without saying where.
  defp report(key, {:halt, step, reason}, elapsed) do
    said = said(step, reason)

    IO.puts("  #{step.state} in #{seconds(elapsed)}")
    if step.attempted, do: IO.puts("  attempted: #{step.attempted}")
    IO.puts("  said: #{said}")
    if step.state == :errored, do: credentials_in_play()
    for resource <- step.resources || [], do: IO.puts("    · #{resource_line(resource)}")

    %{key: key, state: step.state, elapsed: elapsed, reason: said}
  end

  # A paused step's answer is its instructions, and only then anything else.
  #
  # The other order cost most of a night. `provider_error` survives on the row
  # from a previous attempt, so a step that paused correctly — "the records are
  # published and Resend is configured, but the message sent never arrived" —
  # printed a `400 "API key is invalid"` recorded hours earlier. Four walks,
  # each failing at a suspiciously constant 605 seconds, were chasing a field
  # nothing in that run had written, while the step underneath was reporting
  # the truth the whole time.
  #
  # The comment directly above this said paused steps record instructions
  # rather than an error. Reading `provider_error` first contradicted it.
  defp said(%{state: :paused} = step, reason),
    do: step.paused_instructions || step.provider_error || reason

  defp said(step, reason), do: step.provider_error || step.paused_instructions || reason

  # What the run was holding when the step gave up, classified rather than
  # printed. Never the token itself: the classification is what any of these
  # questions actually needed, and a bearer in a log is a bearer in a log.
  #
  # Resend answers `400 "API key is invalid"` to a *malformed* token and `401`
  # to a well-formed expired one — measured against the live API with a
  # placeholder, an empty bearer and a real token watched to its expiry. So the
  # 400 the inbound step reports says the run presented something that was not
  # a token, and this is the line that names which.
  defp credentials_in_play do
    for provider <- [:cloudflare, :resend] do
      state =
        case CodeMySpec.Integrations.fetch_access_token(scope_for_credentials(), provider) do
          {:ok, "spex-placeholder-token"} -> "placeholder"
          {:ok, token} when is_binary(token) and token != "" -> "real (#{byte_size(token)} bytes)"
          {:ok, _} -> "empty"
          {:error, reason} -> "unusable: #{inspect(reason)}"
        end

      IO.puts("  credential #{provider}: #{state}")
    end
  end

  defp scope_for_credentials, do: :persistent_term.get({__MODULE__, :scope})

  # Every step, not just the ones before the first failure.
  #
  # `Provisioning.run/3` halts, and it is right to: the ordering is a dependency
  # claim, and running `content` against a site that never deployed proves
  # nothing. But a *drill* is looking for defects, and the eight steps behind a
  # failure are exactly the ones that have never executed. Continuing gives one
  # walk's worth of evidence about all of them; the halt is still what the
  # product does, and the summary says which steps ran on a broken foundation.
  defp summarise(results) do
    IO.puts("\n" <> String.duplicate("═", 68))

    for %{key: key, state: state, elapsed: elapsed, reason: reason} <- results do
      IO.puts("  #{pad(key)} #{pad(state, 12)} #{seconds(elapsed)}")
      if reason, do: IO.puts("      #{String.slice(to_string(reason), 0, 400)}")
    end

    failed = Enum.reject(results, &(&1.state == :done))
    total = results |> Enum.map(& &1.elapsed) |> Enum.sum()

    IO.puts(String.duplicate("═", 68))
    IO.puts("  #{length(results) - length(failed)}/#{length(results)} done in #{seconds(total)}")

    case {failed, tearing_down?()} do
      {[], false} -> IO.puts("  the whole plan ran")
      {[], true} -> IO.puts("  nothing was left behind that teardown tried to remove")
      {_, false} -> IO.puts("  stuck: " <> Enum.map_join(failed, ", ", &to_string(&1.key)))
      {_, true} -> IO.puts("  left behind: " <> Enum.map_join(failed, ", ", &to_string(&1.key)))
    end
  end

  ## Premises

  # The residue check is what makes a spex trustworthy and what makes this
  # impossible: it refuses to start when the account already holds `spex-`
  # resources, and this drill's whole design is to leave them there.
  #
  # Flagged rather than skipped-by-configuration, so the refusal keeps working
  # for every spex in the same VM. The flag is the same one the check sets after
  # its first pass.
  # Where the deployed application talks back to, which must not be the hosted
  # service.
  #
  # Generated apps default `CODEMYSPEC_WIDGET_URL` to `wss://codemyspec.com/widget`,
  # and the drill's own CodeMySpec is a rolled-back test database that nothing
  # on the internet can reach. So a drill-deployed app with no explicit value
  # opens a widget socket against production and retries it every ten seconds
  # with a deploy key production has never issued — observed doing exactly that,
  # 403 at the edge, on a loop.
  #
  # `.invalid` is reserved by RFC 2606 and guaranteed never to resolve, which is
  # the honest destination for a socket whose real endpoint does not exist: the
  # app fails to connect to a name that cannot exist, rather than to somebody's
  # production server. `setup :never_point_the_app_at_production` runs first so
  # this is true before any step can write a secret.
  defp never_point_the_app_at_production(context) do
    previous = Application.get_env(:code_my_spec, :base_url)
    Application.put_env(:code_my_spec, :base_url, drill_base_url())
    on_exit(fn -> Application.put_env(:code_my_spec, :base_url, previous) end)

    context
  end

  # `dev.codemyspec.com`, which is reachable through the Cloudflare tunnel, and
  # never `codemyspec.com`. Overridable so a drill can be pointed somewhere else
  # without editing this, and `.invalid` — reserved by RFC 2606 and guaranteed
  # never to resolve — is the fallback rather than the hosted service.
  defp drill_base_url do
    System.get_env("CMS_DRILL_BASE_URL", "https://dev.codemyspec.com")
  end

  defp keep_what_the_last_walk_left(context) do
    :persistent_term.put({CodeMySpecSpex.Case, :residue_checked}, true)
    context
  end

  # One keypair for every walk, kept on disk beside the checkout.
  #
  # `ensure_access_key/2` reads the account's stored public key and generates one
  # when there is none. The sandbox rolls the database back after every run, so
  # each walk would generate a fresh key — and `Hetzner.ensure_ssh_key/3` matches
  # by fingerprint, so a new key means a new upload, while the box adopted from
  # the last walk still only trusts the old one. The symptom is an SSH timeout
  # against a server that is up, at the first step that needs a shell.
  defp persistent_access_key(%{scope: scope} = context) do
    private_path = Path.join(drill_state_dir(), "id_ed25519")

    unless File.exists?(private_path) do
      {_out, 0} =
        System.cmd(
          "ssh-keygen",
          ["-t", "ed25519", "-N", "", "-C", "cms-drill", "-f", private_path],
          stderr_to_stdout: true
        )
    end

    {:ok, _} =
      AccountSecrets.put_value(scope, "server_ssh_public_key", File.read!(private_path <> ".pub"))

    {:ok, _} =
      AccountSecrets.put_value(scope, "server_ssh_private_key", File.read!(private_path))

    context
  end

  # The registry password, which is baked into a running container.
  #
  # `Registry.credential/1` mints one when the project has none, and the
  # registry's htpasswd is written when the container starts — so a rolled-back
  # database meant a new password every walk against a registry still holding
  # the first one. The builder then failed its `docker login` with
  # `401 Unauthorized` against a registry that was up and healthy, three
  # minutes into a deploy.
  #
  # Fourth member of the same family here, after the SSH key, the age keys and
  # the deploy key: a credential the provider keeps and the database does not.
  defp persistent_registry_password(%{scope: scope} = context) do
    put_persistent_secret(scope, "registry_password")

    # The database password, baked into the postgres container's PGPASSWORD the
    # moment it was created. Rotating it left `DATABASE_URL` naming a password
    # the running database had never heard of, and the migration failed with
    # `FATAL 28P01 password authentication failed for user "app"` — after
    # decrypting its environment perfectly.
    for environment <- environments(),
        do: put_persistent_secret(scope, "database_password_#{environment}")

    context
  end

  # A secret the provider bakes into something long-lived, kept where the
  # sandbox cannot roll it back. The app mints these on first use and stores
  # them in `ProjectSecrets`; the drill supplies them so that "first use" is
  # once, not once per walk.
  defp put_persistent_secret(scope, name) do
    path = Path.join(drill_state_dir(), name)

    unless File.exists?(path) do
      File.write!(path, 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
    end

    {:ok, _} = ProjectSecrets.put_value(scope, name, String.trim(File.read!(path)))

    :ok
  end

  # The age keys, for the same reason as the SSH key and with a worse failure.
  #
  # The encrypted env lives in the checkout, which this drill keeps; the key
  # that opens it lives in the database, which the sandbox rolls back. So every
  # walk generated a fresh key, found `envs/uat.enc.env` unopenable and
  # discarded it — taking `DATABASE_URL` with it, which nothing then rewrote
  # because the server that serves the database was adopted rather than run.
  #
  # **Both halves, or this does not converge.** Seeding only the private key
  # leaves `.sops.yaml` in the checkout naming whatever recipient the app minted
  # last time, and `key_for/3` checks that they agree *before* it will use a
  # stored key — so it mints another, rewrites `.sops.yaml`, and the database
  # rolls back to mine again. Two persistent stores disagreeing forever, one
  # rotation per walk. Writing the config here makes them agree on the first
  # check.
  #
  # After `drill_working_directory`, because `.sops.yaml` is written through the
  # project's environment and that is the setup which points it at the checkout.
  defp persistent_age_keys(%{scope: scope} = context) do
    recipients =
      Map.new(environments(), fn environment ->
        path = Path.join(drill_state_dir(), "age_#{environment}.key")

        # `-o`, and emphatically not `stderr_to_stdout: true`. age-keygen prints
        # the key to stdout and "Public key: …" to *stderr*, so merging the two
        # put a line sops cannot parse at the top of the file — "unknown
        # identity type". The app then could not read the stored key at all.
        unless File.exists?(path), do: {_out, 0} = System.cmd("age-keygen", ["-o", path])

        # The bare key, not the file. `age-keygen -o` writes two comment lines
        # above it, and `Sops.parse_key/1` stores only the key itself — so a
        # multi-line value here is a shape the app never produces. It travels to
        # the container as `SOPS_AGE_KEY`, an environment variable, where the
        # extra lines do not survive: the deploy shipped a key the container
        # could not use and kamal reported `docker exit status: 128` with sops
        # saying "no identity matched any of the recipients" about a file whose
        # recipient was correct.
        private = File.read!(path) |> then(&Regex.run(~r/AGE-SECRET-KEY-[A-Z0-9]+/, &1)) |> hd()
        {:ok, _} = ProjectSecrets.put_value(scope, "age_private_key_#{environment}", private)
        {:ok, public} = Sops.public_key(private)

        discard_env_encrypted_to_another_key(scope.environment, environment, public)

        {environment, public}
      end)

    :ok = Sops.write_config(scope.environment, recipients)

    context
  end

  # The encrypted env is what decides, not `.sops.yaml`.
  #
  # `key_for/3` will only use a stored key when it opens its own file, and
  # `Sops.recipients/2` reads that from `envs/<env>.enc.env` — so a file left
  # over from a walk whose minted key has since been rolled out of the database
  # makes the check fail, mints another key, and rewrites the file to it. The
  # database rolls back to the persistent key and the next walk does it again:
  # two stores disagreeing forever, one rotation per walk, and a deploy whose
  # container cannot decrypt what it was shipped.
  #
  # Removing it once ends that. `Sops.missing_secrets/4` treats an absent file
  # as "everything is missing", which is the ordinary fresh-project path, so the
  # secrets step mints nothing and `put_secret/4` recreates the file against the
  # key that is actually here. `DATABASE_URL` goes with it and the server step
  # writes it back — which `verify(:server, …)` now insists on.
  defp discard_env_encrypted_to_another_key(env, environment, public) do
    case Sops.recipients(env, environment) do
      {:ok, recipients} -> unless public in recipients, do: remove_env_file(env, environment)
      _ -> :ok
    end
  end

  defp remove_env_file(env, environment) do
    CodeMySpec.Environments.delete_file(env, "envs/#{environment}.enc.env")
  end

  # The domain, the environments and the devops level — the three facts the plan
  # is derived from. Set after the working directory, because that swaps the
  # project row and the scope has to carry the one holding the domain.
  defp the_project_under_drill(%{scope: scope, project: project} = context) do
    project =
      project
      |> own_domain(domain())
      |> already_ours()
      |> then(&Fixtures.set_project_deploy_key(scope, &1, persistent_deploy_key()))

    Fixtures.set_devops(scope, devops_level())

    # Dropped and recreated, not reused. `set_environments/2` puts with empty
    # attrs, so a row that already exists keeps whatever it was last given —
    # and what it was last given is the previous walk's server IP and the
    # previous walk's hostname.
    #
    # Both are actively wrong after a teardown or a domain change. Pointed at a
    # new domain, the rows still said `uat.spex-drill.legwork.ca`; after the
    # teardown they still held `178.156.185.52`, an address Hetzner had already
    # taken back. The server step created two fresh boxes and then SSHed to the
    # released one, because `environment_ip/3` prefers the recorded IP over
    # asking the provider — and reported `database_password_not_set`, which
    # names the step that failed rather than the address it dialled.
    #
    # Recreating empty makes that fallback the only path: no recorded IP means
    # `Hetzner.find_server/2` answers, and the answer is about the box that
    # exists now.
    only_environments(scope, [])
    only_environments(scope, environments())

    scope = %{scope | active_project: project}

    context |> Map.put(:project, project) |> Map.put(:scope, scope)
  end

  # The remote this project already has, the way a project that has run setup
  # once already has one.
  #
  # `run(:repository, …)` adopts a repository at the name setup would use only
  # when the project already points at it — otherwise the repository predates
  # setup, might be somebody's unrelated work, and Sam chooses (criterion 8185).
  # That is the right rule and it reads the project row, which the sandbox rolls
  # back between walks. So the second walk met its own repository as a stranger
  # and paused: "A repository named spex-drill already exists on this account."
  #
  # Set here rather than passing `adopt: true` in the step options, which would
  # have got the same walk moving while switching off the distinction 8185 is
  # about. The drill wants the production situation — a project that owns its
  # remote — not the check disabled.
  defp already_ours(project) do
    Fixtures.set_project_code_repo(project, "https://github.com/#{spex_owner()}/spex-drill")
  end

  # The deploy key the running app is already authenticating with.
  #
  # `seed_deploy_key/2` mints one only when the project has none, which is
  # stable in production and rotates here every walk — so the content step
  # presented this walk's key to an app deployed with the last one and got
  # `401 Invalid deployment key`. The value has to outlive the database for the
  # same reason the age key does.
  defp persistent_deploy_key do
    path = Path.join(drill_state_dir(), "deploy_key")

    unless File.exists?(path) do
      File.write!(path, "dk_drill_" <> (24 |> :crypto.strong_rand_bytes() |> Base.url_encode64()))
    end

    File.read!(path) |> String.trim()
  end

  ## Configuration

  defp steps_to_run(project) do
    planned = project |> Provisioning.setup_options() |> Sequence.for_options() |> Enum.map(& &1.key)

    case env_list("CMS_DRILL_STEPS") do
      [] -> planned
      chosen -> Enum.filter(planned, &(to_string(&1) in chosen))
    end
  end

  defp environments do
    case env_list("CMS_DRILL_ENVIRONMENTS") do
      [] -> ["uat"]
      names -> names
    end
  end

  # `prod` means the apex, and the apex is only in the plan at the `:prod` level.
  defp devops_level, do: if("prod" in environments(), do: :prod, else: :uat)

  defp domain, do: System.get_env("CMS_DRILL_DOMAIN", @default_domain)

  # The apex guard's answer, which otherwise only the web UI can give.
  #
  # `dns` refuses to repoint an apex that already resolves, because doing so
  # takes down whatever is serving it today, and it waits for a person to say
  # go ahead — a `confirm_apex_repoint` event in `ProvisioningLive`. The drill
  # had no way to say it, so a walk that met the guard could never get past it,
  # and every step downstream of DNS stayed stuck with it. Which is the state a
  # torn-down environment leaves behind: teardown skips the apex record as
  # adopted, the address gets recycled, and the next run finds the name already
  # resolving — to a box that is not serving it.
  defp confirm_apex_opts do
    if System.get_env("CMS_DRILL_CONFIRM_APEX") in ~w(1 true yes),
      do: [confirm_apex_repoint: true],
      else: []
  end

  defp step_opts do
    Application.get_env(:code_my_spec, :provisioning_step_opts, []) ++ confirm_apex_opts()
  end

  defp drill_state_dir do
    dir =
      System.get_env("CMS_DRILL_STATE") ||
        Path.join(System.get_env("CMS_DRILL_APP") || System.tmp_dir!(), ".cms-drill")

    File.mkdir_p!(dir)
    dir
  end

  defp env_list(name) do
    name
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  ## Reporting

  defp banner(scope, steps) do
    ordered = if tearing_down?(), do: Enum.reverse(steps), else: steps

    IO.puts("""

    #{String.duplicate("═", 68)}
      #{if tearing_down?(), do: "TEARING DOWN", else: "building"}
      project      #{scope.active_project.name}
      domain       #{scope.active_project.domain}
      environments #{Enum.join(environments(), ", ")}
      checkout     #{scope.active_project.local_path}
      steps        #{Enum.map_join(ordered, " → ", &to_string/1)}
    #{String.duplicate("═", 68)}
    """)
  end

  # The other half of the drill, and the half the story's promise actually
  # rests on: infrastructure setup can rebuild is infrastructure setup can be
  # trusted to own. Build and tear down are one instrument on purpose — they
  # share the project, the domain and the recorded resources, and a teardown
  # driven from somewhere else would be tearing down something else.
  defp tearing_down?, do: System.get_env("CMS_DRILL_TEARDOWN") in ~w(1 true yes)

  defp resource_line(resource) do
    kind = Map.get(resource, :kind) || Map.get(resource, "kind")
    location = Map.get(resource, :location) || Map.get(resource, "location")
    origin = Map.get(resource, :origin) || Map.get(resource, "origin")

    "#{kind} #{location}" <> if(origin, do: " (#{origin})", else: "")
  end

  defp seconds(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp pad(value, width \\ 22), do: value |> to_string() |> String.pad_trailing(width)
end
