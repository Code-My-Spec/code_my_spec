defmodule Mix.Tasks.Cms.Harness.Onboard do
  @shortdoc "Point this working copy's agent hooks at its own harness id"

  @moduledoc """
  Address this checkout's hooks to the harness that serves it.

      mix cms.harness.onboard
      mix cms.harness.onboard <root> --server-url https://codemyspec.com

  `--server-url` names the CodeMySpec that will serve the target. Needed when
  onboarding a checkout this build does not belong to: the id is minted against
  the *calling* build's server otherwise, and a sibling repo served by a
  packaged release ends up with an id its own daemon has never heard of.
  With no credential, the command prints a device verification URL and code
  and waits for approval before minting; no deploy key is required.

  Reads the id the server issued this working copy and writes it to
  `.cms_harness.json` and `.claude/settings.local.json`. No `--plugin-dir` is
  needed: the installed plugin (`codemyspec@codemyspec`) resolves the working
  copy on its own.

    * Hooks are a plain `curl` that posts the payload. Every Claude Code hook
      payload carries `cwd`, and the harness walks up from it to
      `.cms_harness.json` — see `CmsHarness.Web.ResolveWorkingCopy`. An
      un-onboarded directory is refused by name rather than adopting a parent
      checkout's identity.

    * MCP is declared in the tracked `plugin.json` with the header
      `X-Harness-Id: ${CMS_HARNESS_ID}`. An `mcpServers` entry interpolates
      environment variables and cannot read a file, so this is the one surface
      that needs the variable — and the `env` block this task writes sets it.

  Developing the plugin itself (`plugins/claude`) is a manual `--plugin-dir`;
  this task has no part in it.

  ## What gets minted

  A harness config at the working copy's root — `CmsHarness.HarnessConfig` —
  holding the id the server issued, the project it serves, and where it is.
  The server records the same root on the harness object, so nothing has to be
  discovered afterwards.

  Asking the server for the id rather than waiting for a channel join is what
  lets a brand-new worktree be onboarded before anything has ever run in it.
  """

  use Mix.Task
  # Classified to CmsHarness, unlike the other tasks: it reads the harness
  # config and settings, and `CodeMySpec` may not reference `CmsHarness`.
  use Boundary, classify_to: CmsHarness

  alias ClientUtils.Harness.Onboarding
  alias CmsHarness.Config
  alias CmsHarness.HarnessConfig
  alias CmsHarness.ProjectIdentity
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces.PreviewTunnel
  alias Ecto.Adapters.SQL

  @settings_file ".claude/settings.local.json"
  @harness_config_file ".cms_harness.json"

  @impl Mix.Task
  def run(args) do
    CmsHarness.Proxy.install!()
    # `:req` and nothing else: minting is one HTTP call, and `app.start` would
    # boot Phoenix and Ecto in a checkout that has never been started.
    {:ok, _} = Application.ensure_all_started(:req)

    root = target_root(args)
    env = environment(root, args)
    relay_model_turns? = Enum.member?(args, "--relay-model-turns")
    put_device_flag(args)
    put_server_url_flag(args, root)

    if Enum.member?(args, "--check") do
      check(env, root)
    else
      onboard(env, root, relay_model_turns?, project_flag(args))
    end
  end

  # Where the disk is (a different question from which project this checkout
  # belongs to). A registered environment for `--project` wins — the
  # remote-checkout case, and how a spec drives this through an in-memory
  # environment; otherwise the disk is here. Every write goes through
  # `ExecutionContexts`.
  defp environment(root, args) do
    registered =
      case project_flag(args) do
        nil -> nil
        project_id -> ExecutionContexts.lookup_registered(project_id)
      end

    case registered do
      nil ->
        {:ok, env} = ExecutionContexts.create(:local, working_dir: root)
        env

      env ->
        env
    end
  end

  defp project_flag(args), do: flag(args, "--project")

  defp flag(args, name) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [^name, value] -> value
      _ -> nil
    end)
  end

  # Absence has to report itself. Asks `ClientUtils.Harness.Onboarding.check/2`,
  # the one implementation, through `ExecutionContexts` so specs can drive it. It
  # prints as well as returns: at a terminal the return value goes nowhere.
  defp check(env, root) do
    report = Onboarding.check(root, io: io(env), remedy: "mix cms.harness.onboard")
    announce_check(report.onboarded, report.missing, report.remedy, root)
    report
  end

  # No adapter: `Onboarding.Port` calls `read_file/2`, `write_file/3`,
  # `file_exists?/2` and `cmd/4` on the module it is given — `ExecutionContexts`'
  # contract exactly.
  defp io(env), do: {ExecutionContexts, env}

  defp announce_check(true, _missing, _remedy, root) do
    Mix.shell().info("onboarded: #{root}")
  end

  # Names the missing keys, and prints the remedy `check/2` returned. The shared
  # default names `--id` (a generated app cannot mint); this task mints, so its
  # remedy is the bare command.
  defp announce_check(false, [_ | _] = missing, remedy, root) do
    Mix.shell().info(
      "not onboarded: #{root}\n  missing: #{Enum.join(missing, ", ")}\nrun: #{remedy}"
    )
  end

  defp announce_check(false, _missing, remedy, root) do
    Mix.shell().info("not onboarded: #{root}\nrun: #{remedy}")
  end

  defp onboard(env, root, relay_model_turns?, project_id) do
    bootstrap_local_dev_env(root)

    with {:ok, id} <- identity(env, root, project_id),
         :ok <- provision_preview(env, root, id),
         :ok <- address(env, root, id, relay_model_turns?) do
      git = configure_git(env)
      outstanding(root, id, git)
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  # Into the checkout's own config, which is where the harness reads it. Called
  # directly rather than over `/api/harnesses/:id/preview`, because this task
  # runs inside CodeMySpec, where the Cloudflare credential lives; both end at
  # `PreviewTunnel.ensure/1`.
  #
  # Every refusal is `:ok` — a worktree, no Cloudflare account, no reachable
  # database — because the identity is already written. `reachable_repo/0`
  # starts only `Vault` and `Repo` (via `start_local_repo/0`): `run/1` starts
  # just `:req`, and `WorkingCopies.fetch/1` is a `Repo.get`.
  defp provision_preview(env, root, id) do
    with :ok <- reachable_repo(),
         {:ok, copy} <- WorkingCopies.fetch(id),
         {:ok, credentials} <- PreviewTunnel.ensure(copy) do
      record_preview(env, root, id, %{
        "preview_url" => credentials.preview_url,
        "preview_tunnel_id" => credentials.tunnel_id,
        "preview_tunnel_secret" => credentials.tunnel_secret
      })
    else
      {:error, :not_the_main_copy} ->
        :ok

      {:error, reason} ->
        Mix.shell().info("      preview:    none (#{inspect(reason)})")
        :ok
    end
  end

  # Started *and* answering: Postgrex pools connect lazily, so a started repo is
  # not evidence a query will work. One `SELECT 1`, which returns a tuple.
  defp reachable_repo do
    with :ok <- CmsHarness.Onboarding.start_local_repo(),
         {:ok, _result} <- SQL.query(CodeMySpec.Repo, "SELECT 1", []) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @doc """
  Public only so it can be tested directly, for the same reason
  `address_model_turns/4` is: it writes over a file that already holds this
  copy's identity, and "keeps what was already there" has to be checkable
  rather than asserted in a comment.
  """
  def record_preview(_env, _root, _id, preview) when preview == %{}, do: :ok

  # Merged over what the file already says, never written from scratch:
  # `identity/3` has recorded `project_id` and possibly a `deploy_key` there.
  # Same rule as `HarnessConfig.write/2`, through `ExecutionContexts` because the
  # copy may be on another machine.
  def record_preview(env, root, id, preview) do
    body =
      env
      |> recorded_config()
      |> Map.merge(%{"working_copy_id" => id, "harness_id" => id, "root" => root})
      |> Map.merge(preview)
      |> Jason.encode!(pretty: true)

    ExecutionContexts.write_file(env, @harness_config_file, body)

    Mix.shell().info("      preview:    #{preview["preview_url"]}")
    :ok
  end

  # An unreadable or malformed config answers empty rather than raising. The
  # caller is about to write the id back either way, and refusing to record an
  # address because the file needs repairing helps nobody.
  defp recorded_config(env) do
    with {:ok, contents} <- ExecutionContexts.read_file(env, @harness_config_file),
         {:ok, map} when is_map(map) <- Jason.decode(contents) do
      map
    else
      _ -> %{}
    end
  end

  # `address_model_turns/4` is opt-in: its proxy only understands
  # `/v1/messages`, so routing an interactive session's turns through it breaks
  # other Anthropic surfaces silently. `address_mcp/3` covers what every
  # session needs — `CMS_HARNESS_ID` for MCP, the partition.
  defp address(env, root, id, true), do: address_model_turns(env, root, id)
  defp address(env, root, id, false), do: address_mcp(env, root, id)

  defp address_mcp(env, root, id), do: write_settings(env, root, id, false, nil)

  # A new worktree lacks the dev-only surfaces kept outside git — `envs/.env`
  # and the sibling `code_my_spec_test_repos` checkout — which live once and are
  # symlinked into every worktree. Best-effort and silent: anything that is not
  # a linked worktree of such a repo no-ops (`main_checkout_root/1`).
  defp bootstrap_local_dev_env(root) do
    case main_checkout_root(root) do
      nil ->
        :ok

      ^root ->
        :ok

      main_root ->
        link_if_missing(root, main_root, "envs")
        link_if_missing(root, Path.dirname(main_root), "code_my_spec_test_repos")
    end

    :ok
  end

  defp main_checkout_root(root) do
    case System.cmd("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {out, 0} -> out |> String.trim() |> Path.dirname()
      _ -> nil
    end
  end

  defp link_if_missing(root, source_parent, name) do
    dest = Path.join(root, name)
    source = Path.join(source_parent, name)

    if not match?({:ok, _}, File.lstat(dest)) and File.exists?(source) do
      File.ln_s!(source, dest)
    end
  end

  # Reported, not raised: a working copy that is not a git repository still
  # wants its identity, partition and address. `submodule.recurse` matters
  # because a submodule sits in detached HEAD and accepts writes with no
  # branch to carry them.
  defp configure_git(env) do
    Enum.reduce_while(Onboarding.git_config(), true, fn {key, value}, true ->
      case ExecutionContexts.cmd(env, "git", ["config", key, value]) do
        {_out, 0} ->
          {:cont, true}

        {out, _} ->
          Mix.shell().info("\nGit not configured (#{key}): #{inspect(out)}")
          {:halt, false}
      end
    end)
  end

  # `target_app/1` (below) is the app the *target* is, read from its own
  # `mix.exs` — `Mix.Project.config()[:app]` names this repo, and would name
  # another directory's databases after it. Read, not evaluated: `app:` is a
  # literal atom in every generated app.
  @doc false
  # The id is minted against `Config.server_url/0`, which knows only *this*
  # build. A sibling repo onboarded against the wrong server looks fine until
  # its daemon answers "No harness with id …". The remedy is `--server-url`.
  defp warn_if_foreign_root(root) do
    here = File.cwd!() |> Path.expand()
    root = Path.expand(root)

    unless String.starts_with?(root, here <> "/") or root == here do
      Mix.shell().info([
        :yellow,
        """
        warning: #{root} is not inside #{here}.

        The harness id above was minted against #{Config.server_url()}, which
        comes from *this* build rather than from that checkout — a checkout
        cannot name its own server. If #{Path.basename(root)} is served by a
        different CodeMySpec (a packaged release on another port, or the hosted
        one), the id is unknown there and its hooks will fail with
        "No harness with id ...".

        Check by asking the daemon that actually serves it. If they disagree,
        re-run with the server that one belongs to:

            mix cms.harness.onboard #{root} --server-url <url>
        """,
        :reset
      ])
    end
  end

  def target_app(root) do
    case Mix.Project.config()[:app] do
      app when is_atom(app) and not is_nil(app) ->
        if Path.expand(root) == Path.expand(File.cwd!()),
          do: app,
          else: app_from_mix_exs(root, app)

      _ ->
        app_from_mix_exs(root, nil)
    end
  end

  # A target whose `mix.exs` cannot be read or names no app keeps the running
  # project's answer. Wrong, but the databases are named for information only,
  # and a refusal would block an otherwise sound onboarding.
  defp app_from_mix_exs(root, fallback) do
    with {:ok, contents} <- File.read(Path.join(Path.expand(root), "mix.exs")),
         [_, app] <- Regex.run(~r/^\s*app:\s*:([a-z][a-z0-9_]*)/m, contents) do
      String.to_atom(app)
    else
      _ -> fallback
    end
  end

  defp outstanding(root, id, git) do
    partition = Onboarding.partition_name(root)
    databases = Onboarding.databases(partition, target_app(root))

    # The report and the print carry the same facts. Databases are named, not
    # created: `Mix.Tasks.Cms.CheckTestMigrations` creates and migrates each in
    # its own VM on first use.
    Mix.shell().info("""

    onboarded: #{root}
      harness id: #{id}
      server:     #{Config.server_url()}
      partition:  #{partition}
      submodules: #{if git, do: "recursing", else: "not configured"}
      databases:  #{Enum.map_join(databases, ", ", & &1.name)}
                  made on the first `mix test` / `mix spex` that needs them
    """)

    warn_if_foreign_root(root)

    %{
      working_copy_id: id,
      partition: partition,
      databases: databases,
      git: %{submodule_recurse: git},
      issued_ddl: false
    }
  end

  # Which server mints the id. Four tiers, most specific first: `--server-url`,
  # what this copy recorded when its id was minted, the project's committed
  # config (`ProjectIdentity.server_url/1`), then the build's default. The copy
  # beats the project because one project can be served by different servers
  # on different machines. Into application env because the value is needed
  # several calls down.
  defp put_server_url_flag(args, root) do
    case flag(args, "--server-url") || recorded_server_url(root) ||
           ProjectIdentity.server_url(root) do
      nil -> Application.delete_env(:code_my_spec, :harness_server_url_override)
      url -> Application.put_env(:code_my_spec, :harness_server_url_override, url)
    end
  end

  defp recorded_server_url(root) do
    case HarnessConfig.read_file(root) do
      {:ok, %{server_url: url}} when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  # `--device <id>`, into application env for `device_id/0` several calls down.
  defp put_device_flag(args) do
    case device_flag(args) do
      nil -> Application.delete_env(:code_my_spec, :onboard_device_id)
      id -> Application.put_env(:code_my_spec, :onboard_device_id, id)
    end
  end

  defp device_flag(["--device", id | _rest]) when is_binary(id), do: id
  defp device_flag([_arg | rest]), do: device_flag(rest)
  defp device_flag([]), do: nil

  # A checkout's own `.code_my_spec/` is not a checkout: onboarded, it becomes a
  # second working copy whose analysis runs fail with no `mix.exs`. Flags and
  # their values are dropped before the path is taken (`drop_flags/1`), or
  # `--check` or a project id would be expanded as the root.
  defp target_root(args) do
    root = args |> drop_flags() |> first_path()

    case Path.basename(root) do
      ".code_my_spec" ->
        Mix.raise("""
        #{root} is a checkout's own .code_my_spec directory, not a checkout.

        Onboarded, it becomes a second working copy on this project and takes
        analysis runs meant for the real root — which then fail, because there is
        no mix.exs here.

        Onboard the checkout instead:

            mix cms.harness.onboard #{Path.dirname(root)}
        """)

      _ ->
        root
    end
  end

  defp drop_flags(["--project", _id | rest]), do: drop_flags(rest)
  # Same shape as `--project`: the value is not a path, and without this clause
  # `mix cms.harness.onboard --device <id>` onboards a directory named after
  # the id.
  defp drop_flags(["--device", _id | rest]), do: drop_flags(rest)
  defp drop_flags(["--server-url", _url | rest]), do: drop_flags(rest)
  defp drop_flags(["--" <> _ | rest]), do: drop_flags(rest)
  defp drop_flags([arg | rest]), do: [arg | drop_flags(rest)]
  defp drop_flags([]), do: []

  defp first_path([path | _]) when is_binary(path), do: Path.expand(path)
  defp first_path(_), do: File.cwd!()

  # Read through the environment, so a working copy that already has an id is a
  # file the spec wrote through the same surface — not a fixture reaching past it.
  defp identity(env, root, project_id) do
    case ExecutionContexts.read_file(env, @harness_config_file) do
      {:ok, contents} -> existing_id(contents, env, root, project_id)
      _ -> CmsHarness.Onboarding.mint(root, project_id, authorize: true)
    end
  end

  # Both key names, new one first — the compatibility window `HarnessConfig`
  # implements. Reading only one name re-minted a fresh identity on a second
  # onboard and orphaned everything recorded against the first.
  defp existing_id(contents, env, root, project_id) do
    case Jason.decode(contents) do
      {:ok, map} -> recorded_id(map, env, root, project_id)
      _ -> mint_and_record(env, root, project_id)
    end
  end

  defp recorded_id(%{"working_copy_id" => id}, env, root, project_id)
       when is_binary(id) and id != "",
       do: confirm_or_remint(id, env, root, project_id)

  defp recorded_id(%{"harness_id" => id}, env, root, project_id) when is_binary(id) and id != "",
    do: confirm_or_remint(id, env, root, project_id)

  defp recorded_id(_map, env, root, project_id), do: mint_and_record(env, root, project_id)

  # A recorded id is confirmed against the server rather than trusted on
  # faith: `Staffing.offboard/2` deletes the server's row but never touches
  # the checkout's own files (its own moduledoc says so), so the original
  # unconditional trust here left a checkout re-onboarded after an explicit
  # offboard invisible to the server forever, with nothing anywhere saying
  # so (45cb6b07). Confirmed gone, this follows the rule story 1014's
  # criterion 965 already establishes for a checkout that vanished and came
  # back: never repaired into the old identity, onboarded as a new one --
  # the same path `mint_and_record/2` already takes for a checkout with no
  # recorded id at all.
  #
  # A check that itself fails (network, credential) is read as "could not
  # tell", not "gone": that would trade a silent loss of registration for a
  # forced re-mint on every transient network hiccup, which is worse.
  #
  # `project_for(root, project_id)`, not `project_for(root, nil)`: an
  # explicit `--project` must confirm against THAT project, not whatever
  # `ProjectIdentity.resolve(root)` finds on real disk at `root` -- with no
  # `--root` given, `root` is `File.cwd!()`, which for a spec driving this
  # through an in-memory `ExecutionContexts` fixture is this very checkout's own
  # real directory, unrelated to the fixture's project. Resolving the wrong
  # project meant confirming a fixture-minted id against a real server using
  # a real, unrelated project's credentials -- a mismatched 404 that
  # re-minted a fresh id for a copy that was never actually gone (c1b2d03a's
  # sibling: story 1030's onboarding criteria failed this way whenever a
  # full-suite run reached this spec after any other real-root onboard call).
  defp confirm_or_remint(id, env, root, project_id) do
    case CmsHarness.Onboarding.project_for(root, project_id) do
      {:ok, project} -> confirm_with_project(id, env, root, project, project_id)
      _ -> {:ok, id}
    end
  end

  # The raw deploy key, not an exchanged access token: `GET /api/harnesses/:id`
  # sits behind `DeployKeyOrOAuth`, which accepts a project's deploy key
  # directly, same as the exchange endpoint would have taken it to trade for
  # a token. Confirming a recorded id has no business trading a key for a
  # token it then uses once -- that trip went through `CmsHarness.Token`'s
  # own exchange, which is deliberately exempt from the suite's stub
  # convention (it dials whatever `Config.server_url()` names, by design) and
  # always logs at `:error` on anything but a clean 200, win or lose. Every
  # confirmation this code performs reached that log, real server or not.
  defp confirm_with_project(id, env, root, project, project_id) do
    case CmsHarness.Onboarding.ensure_local_credential(project.id) do
      {:ok, key} -> handle_confirmation(confirm(id, key), id, env, root, project_id)
      _ -> {:ok, id}
    end
  end

  @doc """
  What a recorded id's confirmation answer decides, given the response
  `confirm/2` would have returned.

  Public so the decision is testable without the network call `confirm/2`
  makes -- only the 200 and fallback branches, which touch nothing else, are
  covered directly; the 404 branch's re-mint is covered by `recorded_id/4`'s
  own moduledoc note and by manual verification, same as `mint/2` itself.
  """
  def handle_confirmation({:ok, %{status: 200}}, id, _env, _root, _project_id), do: {:ok, id}

  def handle_confirmation({:ok, %{status: 404}}, _id, env, root, project_id),
    do: mint_and_record(env, root, project_id)

  def handle_confirmation(_other, id, _env, _root, _project_id), do: {:ok, id}

  # Pinned like every other Req client in this app (`CodeMySpec.HttpClientsAreStubbableTest`):
  # `config :code_my_spec, __MODULE__, plug: {Req.Test, __MODULE__}` in test,
  # stubbed per test with `Req.Test.stub/2`. With no stub installed -- true
  # for every existing onboarding spec, which never deliberately exercises
  # this confirmation -- `Req.Test`'s own plug raises rather than reaching the
  # internet; rescued here into the same "could not tell" outcome a real
  # network failure already gets, so an ordinary spec's onboard call is
  # unaffected by a confirmation it never asked to exercise (c1b2d03a).
  defp confirm(id, key) do
    Req.get(
      url:
        Config.server_url()
        |> String.trim_trailing("/")
        |> Kernel.<>("/api/harnesses/#{id}"),
      headers: [{"authorization", "Bearer " <> key}],
      retry: false,
      receive_timeout: to_timeout(second: 15),
      plug: Application.get_env(:code_my_spec, __MODULE__, [])[:plug]
    )
  rescue
    exception -> {:error, exception}
  end

  defp mint_and_record(env, root, project_id) do
    with {:ok, id} <- CmsHarness.Onboarding.mint(root, project_id, authorize: true) do
      # Both names, matching `HarnessConfig.write/2`. This writes through
      # `ExecutionContexts` rather than that function because the copy may be on
      # another machine — which is exactly how it drifted out of step with it.
      body =
        env
        |> recorded_config()
        |> Map.merge(%{"working_copy_id" => id, "harness_id" => id, "root" => root})
        |> Jason.encode!(pretty: true)

      ExecutionContexts.write_file(env, @harness_config_file, body)
      {:ok, id}
    end
  end

  # The model turns. A plugin cannot set an environment variable for the
  # session, and `ANTHROPIC_BASE_URL` is read by the agent process itself, so
  # the address goes in Claude Code's settings.
  #
  # `settings.local.json`, not the tracked `settings.json`: the URL carries this
  # working copy's id. Merged, never replaced — it keeps every key already there.
  #
  # `CMS_HARNESS_ID` rides along: the plugin's MCP mount sends
  # `X-Harness-Id: ${CMS_HARNESS_ID}`, and an unexpanded one is a refusal.
  # Written here because a session inherits this file, not anyone's shell rc.
  @doc """
  Public only so it can be tested directly. It is the one thing here that
  writes a file the operator owns, so "keeps what was already there" has to be
  checkable rather than asserted in a comment.
  """
  def address_model_turns(env, root, id, base_url \\ nil) do
    # Rendered by `Onboarding` (one derivation of the URL), not here.
    write_settings(env, root, id, true, base_url || default_hook_base_url())
  end

  # One call into `ClientUtils.Harness.Onboarding.onboard/2`, which owns the
  # merge that keeps the operator's keys, the refusal to rewrite invalid JSON,
  # `.cms_harness.json` and `submodule.recurse` — all idempotent.
  defp write_settings(env, root, id, relay_model_turns?, base_url) do
    # `harness_id:`, not `working_copy_id:`: `ClientUtils` is a separate
    # repository released to hex, so its option names are as external as the
    # wire.
    opts = [
      io: io(env),
      app: target_app(root),
      harness_id: id,
      relay_model_turns: relay_model_turns?,
      deploy_key: deploy_key_for(root),
      # Passed as well as written by `mint/2`, which runs only for a copy with
      # no id; every re-onboard records it here.
      server_url: Config.server_url()
    ]

    opts = if base_url, do: Keyword.put(opts, :base_url, base_url), else: opts

    case Onboarding.onboard(root, opts) do
      %{settings: {:ok, _path}} -> :ok
      %{settings: {:error, reason}} -> {:error, describe_settings_error(reason)}
    end
  end

  # This project's own key, from this machine's database. `onboard/2` records it
  # in `.cms_harness.json` so the daemon authenticates *as this project* — a
  # deploy key reaches exactly one. Read even when `CMS_DEPLOY_KEY` is exported:
  # that may be another project's. `nil` is ordinary; `onboard/2` then leaves
  # any recorded key alone.
  defp deploy_key_for(root) do
    if CmsHarness.Onboarding.local_server?(Config.server_url()) do
      with {:ok, project} <- ProjectIdentity.resolve(root),
           key when is_binary(key) and key != "" <-
             CmsHarness.Onboarding.local_project_deploy_key(project.id) do
        key
      else
        _ -> nil
      end
    else
      remote_exported_key()
    end
  end

  defp remote_exported_key do
    key = System.get_env("CMS_DEPLOY_KEY")

    if not CmsHarness.Onboarding.local_server?(Config.server_url()) and
         not CmsHarness.Onboarding.blank?(key),
       do: key
  end

  # `client_utils`' own refusal sentence for malformed JSON is passed through;
  # anything else is a raw posix reason.
  defp describe_settings_error(reason) when is_binary(reason), do: reason

  defp describe_settings_error(reason),
    do: "Could not write #{@settings_file}: #{inspect(reason)}"

  # The harness a model turn is posted to: Claude Code's Anthropic client posts
  # here directly. The local harness, never `Config.server_url()` — the
  # `/v1/messages` route exists only in `CmsHarness.Web.Router`. Port 4004 to
  # match the shipped plugin; `CMS_HARNESS_PORT` wins (a sprite sets it).
  defp default_hook_base_url do
    "http://localhost:#{System.get_env("CMS_HARNESS_PORT") || "4004"}"
  end
end
