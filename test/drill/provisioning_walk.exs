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

  Options, all through the environment:

    * `CMS_DRILL_STEPS` — comma-separated step keys to run, in sequence order.
      Defaults to the project's whole plan.
    * `CMS_DRILL_ENVIRONMENTS` — `uat` (the default: one box, one deploy) or
      `uat,prod` for the full default plan.
    * `CMS_DRILL_DOMAIN` — defaults to `spex-drill.legwork.ca`. It carries the
      `spex-` marker on purpose, so `mix cms.provisioning_leaks` can still find
      everything this leaves behind.

  Not a spex and not a test: the filename has no `_test` suffix, so nothing
  picks it up by accident. It asserts nothing — it reports.
  """

  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.AccountSecrets
  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.Sequence
  alias CodeMySpec.Provisioning.Sops
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpecSpex.Fixtures

  # Long enough for the full plan against cold infrastructure. The walk does not
  # halt at the first failure, so its worst case is every step's own timeout in
  # a row rather than the first one's.
  @moduletag timeout: :timer.hours(3)
  @moduletag ownership_timeout: :timer.hours(3)

  @default_domain "spex-drill.legwork.ca"

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

    results = Enum.map(steps, &run_and_report(scope, &1))

    summarise(results)
  end

  ## The walk

  defp run_and_report(scope, key) do
    IO.puts("\n─── #{key} " <> String.duplicate("─", max(0, 60 - String.length(to_string(key)))))
    started = System.monotonic_time(:millisecond)

    outcome = Provisioning.run_step(scope, key, step_opts())

    elapsed = System.monotonic_time(:millisecond) - started
    report(key, outcome, elapsed)
  end

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
    IO.puts("  #{step.state} in #{seconds(elapsed)}")
    if step.attempted, do: IO.puts("  attempted: #{step.attempted}")
    IO.puts("  said: #{step.provider_error || step.paused_instructions || reason}")
    for resource <- step.resources || [], do: IO.puts("    · #{resource_line(resource)}")

    %{
      key: key,
      state: step.state,
      elapsed: elapsed,
      reason: step.provider_error || step.paused_instructions || reason
    }
  end

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

    case failed do
      [] -> IO.puts("  the whole plan ran")
      _ -> IO.puts("  stuck: " <> Enum.map_join(failed, ", ", &to_string(&1.key)))
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

  defp step_opts, do: Application.get_env(:code_my_spec, :provisioning_step_opts, [])

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
    IO.puts("""

    #{String.duplicate("═", 68)}
      project      #{scope.active_project.name}
      domain       #{scope.active_project.domain}
      environments #{Enum.join(environments(), ", ")}
      checkout     #{scope.active_project.local_path}
      steps        #{Enum.map_join(steps, " → ", &to_string/1)}
    #{String.duplicate("═", 68)}
    """)
  end

  defp resource_line(resource) do
    kind = Map.get(resource, :kind) || Map.get(resource, "kind")
    location = Map.get(resource, :location) || Map.get(resource, "location")
    origin = Map.get(resource, :origin) || Map.get(resource, "origin")

    "#{kind} #{location}" <> if(origin, do: " (#{origin})", else: "")
  end

  defp seconds(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp pad(value, width \\ 22), do: value |> to_string() |> String.pad_trailing(width)
end
