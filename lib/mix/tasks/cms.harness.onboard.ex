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

  Reads the id the server issued this working copy and writes it to
  `.cms_harness.json` and `.claude/settings.local.json`. **Neither `--plugin-dir`
  nor the generated `.claude/plugin-dev` copy is required for this to work.**
  The tracked, installed plugin (`codemyspec@codemyspec`, already enabled by
  default) resolves the working copy on its own:

    * Hooks are a plain `curl` that posts the payload and nothing else. Every
      Claude Code hook payload carries `cwd`, and the harness walks up from it
      to `.cms_harness.json` — see `CmsHarness.Web.ResolveWorkingCopy`. No id in
      the command, no interpolated variable, no per-platform shell: `bin/hook`,
      `hook.cmd` and `hook.ps1` were three implementations of one walk and are
      gone.

    * MCP is declared as `{"type": "http", "url": "http://localhost:4004/mcp",
      "headers": {"X-Harness-Id": "${CMS_HARNESS_ID}"}}` in the tracked
      `plugin.json`. An `mcpServers` entry interpolates environment variables
      and cannot read a file, so this is the one surface that needs the
      variable — and the `env` block this task writes is what sets it. The
      cloud mount takes the same header and nothing else: a harness belongs to
      exactly one project, so it answers both questions and cannot contradict
      itself.

  Verified live on 2026-08-20: a bare `curl` posting only `{"cwd": …}` resolved
  this working copy, and an un-onboarded directory came back named — "… has not
  been onboarded, run `mix cms.harness.onboard <dir>`" — rather than silently
  adopting a parent checkout's identity.

  This task writes no plugin directory at all — there is nothing left for it to
  address that the installed plugin does not already resolve on its own. The
  one exception, and the reason `plugins/claude` still exists as source in this
  repo, is developing the plugin itself: editing `plugins/claude/agents`,
  `skills`, or `hooks.json` and needing an agent to run *this checkout's* copy
  before it ships. That is a manual `--plugin-dir` pointed at `plugins/claude`
  directly — this task has no part in it, because it is not about addressing.

  ## What gets minted

  A harness config at the working copy's root — `CmsHarness.HarnessConfig` —
  holding the id the server issued, the project it serves, and where it is. The
  server records the same root on the harness object.

  That file is why nothing has to be discovered afterwards. A working copy
  knows where it is; writing that down when its identity is minted removes
  every mechanism that previously guessed — the walk up to the nearest
  `mix.exs`, the list of directories in the environment, the lookup against the
  server.

  Asking the server for the id rather than waiting for a channel join is what
  lets a brand-new worktree be onboarded before anything has ever run in it.
  """

  use Mix.Task
  # Classified to CmsHarness rather than CodeMySpec, unlike every other task in
  # here. This one is a harness task — it reads the harness config and the
  # harness's own server settings — and `CodeMySpec` may not reference
  # `CmsHarness`; the dependency runs the other way. Classified to CodeMySpec it
  # compiled with a forbidden-reference warning, and the analyzer treats any
  # compiler problem as a reason to skip exunit, credo and spex entirely, so one
  # misclassified line holds back every other check.
  use Boundary, classify_to: CmsHarness

  alias ClientUtils.Harness.Onboarding
  alias CmsHarness.Config
  alias CmsHarness.HarnessConfig
  alias CmsHarness.ProjectIdentity
  alias CmsHarness.Token
  alias CodeMySpec.Environments
  alias CodeMySpec.Projects
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces.PreviewAddress
  alias CodeMySpec.Workspaces.PreviewTunnel
  alias Ecto.Adapters.SQL

  @settings_file ".claude/settings.local.json"
  @harness_config_file ".cms_harness.json"

  @impl Mix.Task
  def run(args) do
    # `:req` and nothing else. Minting an id is one HTTP call, and this runs in
    # checkouts that have never been started — `app.start` would boot Phoenix
    # and Ecto to make it, and fail on a database the new copy does not need.
    # Without this the call reaches Finch before its pool registry exists and
    # dies as `unknown registry: Req.Finch`, which reads like a dependency
    # problem rather than a task that forgot to start one.
    {:ok, _} = Application.ensure_all_started(:req)

    root = target_root(args)
    env = environment(root, args)
    relay_model_turns? = Enum.member?(args, "--relay-model-turns")
    put_device_flag(args)
    put_server_url_flag(args, root)

    case Enum.member?(args, "--check") do
      true ->
        check(env, root)

      false ->
        onboard(env, root, relay_model_turns?, project_flag(args))
    end
  end

  # Every file this writes goes through `Environments`, and the environment is
  # resolved once here. `--project` names one already registered, which is how a
  # spec drives this: it registers the in-memory environment and the task writes
  # into it, so onboarding is observable on the filesystem surface rather than
  # through a directory a spec had to build.
  #
  # That mattered more than it looks. Written against `File.write!/2` this task
  # could only be exercised by constructing a working copy on disk — a temp
  # directory, a git repo, a plugin tree, a hand-written harness config — and
  # every one of those is a fixture standing in for a surface. The boundary said
  # so first: `CodeMySpecSpex` may not reference `CmsHarness`, and the way past
  # that is not to write the bytes yourself.
  # Where the disk is, which is a different question from which project this
  # checkout belongs to.
  #
  # A registered environment wins when there is one: that is the remote-checkout
  # case, and writing locally there would put the config on the wrong machine.
  # Otherwise the disk is here.
  #
  # `--project` used to *require* a registered environment and raise without
  # one, which blocked the case the flag now exists for — onboarding a local
  # checkout for a project this session is not scoped to.
  defp environment(root, args) do
    registered =
      case project_flag(args) do
        nil -> nil
        project_id -> Environments.lookup_registered(project_id)
      end

    case registered do
      nil ->
        {:ok, env} = Environments.create(:local, working_dir: root)
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

  # Absence has to report itself. Every incident behind story 1013 was a missing
  # thing that produced no error where it was missing and surfaced somewhere far
  # away wearing another failure's costume — a stale analyzer database arriving as
  # `undefined_column` from inside a `given_`, a submodule losing writes in
  # silence, `0/0 satisfied` meaning three different things. An agent that can ask
  # a working copy whether it is onboarded never has to infer it from the wreckage.
  #
  # It prints as well as returns, and the print is not decoration. The first
  # version only returned, which is what the spex assert — correctly, since a
  # structured return is what makes this callable. But a mix task's return value
  # goes to whoever called it, and at a terminal that is nobody: `--check` gave
  # identical empty output for opposite states, which is worse than unhelpful. QA
  # caught it where the spex structurally could not (d053bac5), and it was this
  # story's own defect wearing the costume of its own fix.
  #
  # It answered from `file_exists?` alone for the same reason, and got the one
  # state anybody runs it to diagnose wrong: a run that refuses partway leaves
  # the file behind, written by an earlier attempt. The measured copy printed
  # `onboarded:` and `hooks: skipped` two lines apart while `CMS_HARNESS_ID` was
  # absent and `ANTHROPIC_BASE_URL` was the prefix with no id on it — so the
  # plugin's MCP mount sent the literal `${CMS_HARNESS_ID}` and every hook
  # resolved to the *parent* checkout's harness for three days (`c79ee092`).
  #
  # So this asks `client_utils`, which is the only implementation now.
  #
  # There were two. This side had its own `check/2`, its own `@required_env`,
  # its own `blank_or_invalid?/2` — and its own comment saying so: "two
  # implementations … kept in step by naming the same three keys rather than by
  # one calling the other: this side reads through `Environments` so specs can
  # drive an in-memory copy." The reason was real and the conclusion was not.
  # `Onboarding`'s port takes `{module, handle}` and its callbacks are
  # `Environments`' own functions, so driving it through `Environments` is the
  # argument below and nothing else.
  defp check(env, root) do
    report = Onboarding.check(root, io: io(env), remedy: "mix cms.harness.onboard")
    announce_check(report.onboarded, report.missing, report.remedy, root)
    report
  end

  # No adapter, on purpose. `Onboarding.Port` calls `read_file/2`,
  # `write_file/3`, `file_exists?/2` and `cmd/4` on whatever module it is given,
  # with the handle it is paired with — which is `CodeMySpec.Environments`'
  # contract exactly. A translation module here would have contained four
  # renames and nothing else, and a layer whose whole content is a rename is a
  # layer that will eventually disagree with the thing it renames.
  defp io(env), do: {Environments, env}

  defp announce_check(true, _missing, _remedy, root) do
    Mix.shell().info("onboarded: #{root}")
  end

  # Names them, because "not onboarded" alone sends the reader back to the file
  # to work out which half failed — and the half-onboarded copy, file present
  # and some keys right, is where that costs most.
  #
  # The remedy is the one `check/2` returned, not a constant repeated here. The
  # shared default names `--id`, because a generated application cannot mint a
  # harness id — nothing in it talks to the server, so a bare re-run leaves the
  # same keys missing and the advice is a loop. This task *does* mint, which is
  # why it passes `remedy: "mix cms.harness.onboard"`: here the bare command is
  # the whole fix, and printing `--id` would send the reader hunting a value
  # they never need.
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

  # Into the checkout's own config, which is where the harness will read it and
  # report it from. Written here because onboarding is the one moment something
  # knows both that this machine exists and that it is the one serving this
  # project — and written down rather than held, so a restart does not lose it.
  #
  # Provisioned here rather than passed in on a flag. It was a flag for a day,
  # which made the address something an operator had to already know — the exact
  # errand story 968 exists to remove.
  #
  # Called directly rather than over `/api/harnesses/:id/preview`, because this
  # task *is* the server: it runs inside CodeMySpec, which is where the
  # Cloudflare credential lives. `client_utils` has the same job and no
  # credential, so it asks over HTTP; both end at `PreviewTunnel.ensure/1`.
  #
  # Every refusal is `:ok`. A worktree gets one, a machine with no Cloudflare
  # account configured gets one, and neither is a reason to fail an onboarding
  # that has already established this copy's identity and databases.
  #
  # ## It has to start the database itself
  #
  # `run/1` starts `:req` and nothing else, on purpose — this task runs in
  # checkouts that have never been started, where `app.start` would boot Phoenix
  # and Ecto against a database the new copy does not need. `WorkingCopies.fetch/1`
  # is a `Repo.get`, so reaching it without saying so raised
  # "could not lookup Ecto repo CodeMySpec.Repo" on *every* invocation — after
  # the id had been minted, the row created and the config written, so half the
  # onboarding stood and the operator saw only a stack trace. Running it again
  # then minted a second working copy for the same root.
  #
  # `start_local_repo/0` already exists for this, and brings up only `Vault` and
  # `Repo` rather than the endpoint a `mix phx.server` may already have bound.
  # A machine with no database reachable is a refusal like the others, not a
  # failure: the preview is an address, and the identity this task exists to
  # write is already on disk.
  defp provision_preview(env, root, id) do
    with :ok <- reachable_repo(),
         {:ok, copy} <- WorkingCopies.fetch(id),
         {:ok, credentials} <- PreviewTunnel.ensure(copy) do
      record_preview(env, root, id, %{
        "preview_url" => PreviewAddress.url(copy.id),
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

  # Started *and* answering. `Repo.start_link/1` succeeds against a database
  # nobody is running — Postgrex pools connect lazily — so a started repo is not
  # yet evidence that a query will not raise. One `SELECT 1`, which returns a
  # tuple rather than raising, is.
  defp reachable_repo do
    with :ok <- start_local_repo(),
         {:ok, _result} <- SQL.query(CodeMySpec.Repo, "SELECT 1", []) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @doc false
  def record_preview(_env, _root, _id, preview) when preview == %{}, do: :ok

  # Merged over what the file already says, never written from scratch. By the
  # time this runs `identity/3` has recorded `project_id` there, and possibly a
  # `deploy_key` beside it, and a fresh map would take both with it — leaving a
  # copy that can no longer say which project it serves and has lost its
  # credential. `HarnessConfig.write/2` merges for exactly this reason; this
  # path cannot call it because the copy may be on another machine, so it does
  # the same thing through `Environments`.
  #
  # Public only so it can be tested directly, for the same reason
  # `address_model_turns/4` is: it writes over a file that already holds this
  # copy's identity, and "keeps what was already there" has to be checkable
  # rather than asserted in a comment.
  @doc false
  def record_preview(env, root, id, preview) do
    body =
      env
      |> recorded_config()
      |> Map.merge(%{"working_copy_id" => id, "harness_id" => id, "root" => root})
      |> Map.merge(preview)
      |> Jason.encode!(pretty: true)

    Environments.write_file(env, @harness_config_file, body)

    Mix.shell().info("      preview:    #{preview["preview_url"]}")
    :ok
  end

  # An unreadable or malformed config answers empty rather than raising. The
  # caller is about to write the id back either way, and refusing to record an
  # address because the file needs repairing helps nobody.
  defp recorded_config(env) do
    with {:ok, contents} <- Environments.read_file(env, @harness_config_file),
         {:ok, map} when is_map(map) <- Jason.decode(contents) do
      map
    else
      _ -> %{}
    end
  end

  # `address_model_turns/4` is opt-in, not the default: its proxy only
  # understands `/v1/messages`, so routing an interactive session's model
  # turns through it silently breaks any other Anthropic surface the Claude
  # Code client needs (`/remote-control` measured, 2026-08-19) with no error
  # anywhere naming why. `address_mcp/3` covers what every session needs
  # regardless — `CMS_HARNESS_ID` for MCP, the partition — without that.
  defp address(env, root, id, true), do: address_model_turns(env, root, id)
  defp address(env, root, id, false), do: address_mcp(env, root, id)

  @doc false
  def address_mcp(env, root, id), do: write_settings(env, root, id, false, nil)

  # A brand-new worktree has neither of the dev-only surfaces this repo keeps
  # outside git: `envs/.env` (other secrets this build reads, and the fixture
  # data devops spex want) and the sibling `code_my_spec_test_repos` checkout
  # the devops spex read. Both live once and get symlinked into every
  # worktree — `.gitignore` says as much ("Symlinked into worktrees alongside
  # /envs") — but nothing actually did the symlinking for a worktree made
  # outside `just`, so `MIX_ENV=test` compiles refuse on `GITHUB_CLIENT_ID not
  # set`, unreadable as "you're missing a symlink".
  #
  # Best-effort and silent by design: a generated application has none of
  # this, and a checkout that is not a linked worktree of a repo carrying
  # these directories just isn't this case — `main_checkout_root/1` returns
  # `nil` or `root` itself and everything below no-ops.
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

  # The deploy key minting exchanges is the project's own — `Projects.Project`
  # schema, `deploy_key` field — not a copy of it hand-pasted into a file.
  # This machine's own database already has that row: a local dev server and
  # this task read the same `code_my_spec_dev`, so there is nothing to keep in
  # sync. Best-effort and silent — no local database, a project this database
  # does not know, or a blank key all leave `CmsHarness.Token` to answer
  # exactly as it did before this existed, and a copy served by a daemon holding
  # that project's key already works.
  defp ensure_local_credential(project_id) do
    cond do
      not blank?(System.get_env("CMS_DEPLOY_KEY")) ->
        :ok

      not local_server?(Config.server_url()) ->
        # The database this reads is on this machine, and it backs a server on
        # this machine. Asked about a project id that belongs to a remote
        # CodeMySpec it can only answer "never heard of it", which is true of the
        # database and says nothing about the credential.
        #
        # Silence there cost a diagnosis: onboarding against production with a
        # production project id failed `:no_credential`, and that was read as
        # "production's project has no key" — true, and not the reason. Nothing
        # in this path asks production for anything.
        Mix.shell().info([
          :yellow,
          "Not reading a deploy key from the local database: this is onboarding " <>
            "against #{Config.server_url()}, whose projects are not in it. Export " <>
            "CMS_DEPLOY_KEY with a key from that server if the mint is refused.",
          :reset
        ])

        :ok

      true ->
        case local_project_deploy_key(project_id) do
          key when is_binary(key) and key != "" -> System.put_env("CMS_DEPLOY_KEY", key)
          _ -> :ok
        end
    end
  end

  # Does this machine's database back the server being posted to?
  #
  # Host, not the whole URL: the port distinguishes the dev app from the
  # packaged one and both read `code_my_spec_dev` on this machine, so a port
  # comparison would skip a lookup that is fine.
  defp local_server?(url) do
    case URI.parse(url) do
      %URI{host: host} when host in ["localhost", "127.0.0.1", "::1"] -> true
      _ -> false
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp local_project_deploy_key(project_id) do
    with :ok <- start_local_repo(),
         %{deploy_key: key} <- Projects.get_project_by_id(project_id) do
      key
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Only the two children a `deploy_key` read needs — `Vault` to decrypt the
  # column, `Repo` to fetch the row — never the full application. This runs
  # inside a one-shot mix task that a `mix phx.server` may already have bound
  # to :4000; starting `CodeMySpecWeb.Endpoint` alongside it would crash this
  # task on `:eaddrinuse` to save one database read.
  defp start_local_repo do
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:cloak)

    with {:ok, _} <- ensure_started(CodeMySpec.Vault),
         {:ok, _} <- ensure_started(CodeMySpec.Repo) do
      :ok
    end
  end

  defp ensure_started(mod) do
    case mod.start_link([]) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  # Reported, not raised — the same shape as the hooks above and for the same
  # reason. A working copy that is not a git repository still wants its identity,
  # its partition and its address; aborting all of that because one `git config`
  # could not run would report the absence of a repository as a failure to
  # onboard, which is this story's whole complaint.
  defp configure_git(env) do
    Enum.reduce_while(Onboarding.git_config(), true, fn {key, value}, true ->
      case Environments.cmd(env, "git", ["config", key, value]) do
        {_out, 0} ->
          {:cont, true}

        {out, _} ->
          Mix.shell().info("\nGit not configured (#{key}): #{inspect(out)}")
          {:halt, false}
      end
    end)
  end

  # Named, and made by the run that wants them.
  #
  # Onboarding still creates nothing, and that rule is not stylistic: the version
  # of this that did shelled out to `mix` with an environment that had `MIX_ENV`
  # scrubbed out of it, so it resolved to **dev** — the database every agent
  # shares — and a sibling truncate emptied it three times on 2026-08-13,
  # reporting the rows it destroyed as escaped test data while it did so.
  #
  # What changed is who is asked to act. This printed six commands and left an
  # agent to run them, which is telling an LLM to do what a program can do — and
  # six commands is six chances to do five, with the `s` and `a` partitions the
  # easy ones to skip because nothing wants them until a spex or analyzer run.
  # `Mix.Tasks.Cms.CheckTestMigrations` now creates and migrates the partition
  # in-VM on the first `mix test` or `mix spex` that needs it, so there is
  # nothing outstanding here to hand over.
  #
  # They are still *named*. The report is what tells a reader which databases
  # this working copy owns, and that question survives having nobody to answer
  # it — it is what you read when you are looking at a list of databases
  # wondering which to drop.
  # The app the *target* is, not the app this task is running in.
  #
  # `Mix.Project.config()[:app]` answers for the project the VM booted, which is
  # this repo. Onboarding another directory then named its databases after this
  # one: a generated application called `verifyapp` was told it needed
  # `code_my_spec_testhf3e24487`, while running `mix harness.onboard` inside it
  # correctly said `verifyapp_testhf3e24487`. The partition agrees in both —
  # it is derived from the path — so only the prefix was wrong, and wrong in the
  # direction of naming a database belonging to a different application.
  #
  # `client_utils` warned about exactly this in `onboard_opts/1`: "The app name
  # is required, never defaulted. Defaulting it is what produced
  # `code_my_spec_test_*` inside an application called something else — a
  # printed command that creates a different database than the one it names."
  # It stopped being defaulted and started being taken from the wrong project,
  # which produces the identical symptom.
  #
  # Read from the target's own `mix.exs` rather than evaluated: evaluating
  # another project's build file to print a database name is far more than the
  # question deserves, and `app:` is a literal atom in every generated app.
  @doc false
  # Onboarding a checkout that is not under the one this build came from.
  #
  # The id is minted against `Config.server_url()`, which resolves from *this*
  # build's env and app config — `@default_server_url` is a `compile_env`, so a
  # dev build says localhost and the packaged release says production. Nothing
  # about the target root is consulted, and a checkout has no way to name the
  # server it belongs to.
  #
  # So a sibling repo can be onboarded against the wrong server and every
  # artifact looks right: a plausible `.cms_harness.json`, a real harness id, a
  # successful-looking run. It only surfaces later as "No harness with id …"
  # from the daemon that actually serves that checkout, which reads like a
  # deleted row rather than two servers that never shared data.
  #
  # The remedy is `--server-url`, which is the only thing that can be right: no
  # tier under `Config.server_url/0` knows anything about the target, and the
  # target has no key that names its server. The warning stays because the
  # default is still the calling build's and a caller who did not think about it
  # gets the same wrong answer — it just now says what to type.
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

  # A target whose `mix.exs` cannot be read or does not name an app keeps the
  # running project's answer, and that is a compromise rather than a fix: it is
  # the old behaviour, and it is wrong in the same way. It is chosen over
  # refusing because the databases are named for information now — nothing runs
  # the printed commands since the first `mix test` creates what it needs — so a
  # wrong prefix misinforms where a refusal would block an onboarding that has
  # nothing else wrong with it.
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

    # Everything the report knows, the terminal says. The report is the callable
    # answer and the print is the readable one, and they carry the same facts —
    # anything present in one and absent from the other is the `--check` defect
    # waiting to happen again.
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

  # Informational only — the installed marketplace plugin already calls
  # `cms-mcp-relay hook /api/hooks/<name>` with no id in the command, and the
  # relay itself resolves this working copy by walking up from the hook
  # payload's `cwd` to `.cms_harness.json` (`relay/hook.go`, `harnessID/1`).
  # Nothing here writes to, or depends on, that binary — onboarding has no
  # plugin config left to gate. This only exists so a stale relay is named
  # instead of discovered as eight silently dead hooks.

  # `cms-mcp-relay` is no longer checked here.
  #
  # It was, and the reasoning was sound: hooks shelled out to
  # `cms-mcp-relay hook /api/hooks/<name>`, and a relay from before that
  # subcommand existed did not reject the argument — `hook` was not a flag it
  # knew, so it fell through to the MCP path, posted the hook payload to
  # /mcp?dir=, took the JSON-RPC parse error and exited 0. Claude Code reads 0
  # as a hook that ran. All eight went silently dead with no error on either
  # side, which is why the `capabilities` marker existed and why this reported
  # its absence.
  #
  # Hooks are a plain `curl` now and the relay is not in that path, so the
  # class is gone rather than mitigated: there is no version of curl that can
  # be stale, and no argv a wrong binary can misread. The relay still ships
  # for Codex's MCP mount, which is a different question from whether this
  # checkout's hooks will fire.
  # Takes a path so one checkout can onboard another. A worktree on an older
  # branch does not have this task, and asking somebody to merge a branch
  # before they can be onboarded is a worse first experience than a positional
  # argument.
  #
  # Flags are skipped rather than treated as the path. `--check` alone used to
  # become the root: `target_root(["--check"])` expanded it against the cwd, and
  # the task then reported
  #
  #     not onboarded: /…/phx-new-generator/--check
  #       missing: CMS_HARNESS_ID, MIX_TEST_PARTITION, ANTHROPIC_BASE_URL
  #
  # for a directory that does not exist, while all three values were present the
  # whole time. That is the worst way for a check to fail — not an error, but a
  # confident report that the thing you asked about is broken. Anyone acting on
  # it re-onboards a working copy that was already fine.
  #
  # `--project <id>` has to lose its *value* too, not just the flag: the id is a
  # bare word, so dropping only tokens starting with `-` would leave the id
  # standing where the path goes and expand it against the cwd. Same bug, one
  # argument along.
  # `--device <id>`, read once and left where `device_id/0` can find it.
  #
  # Into application env rather than threaded, because the value is needed five
  # calls down — `onboard/4` → `identity/3` → `mint/2` → `post/3` — and none of
  # the four in between has any business knowing about it. The same seam
  # `:device_config_path` uses, in a task that runs once and exits.
  # Which server mints the id, when the caller knows better than the build does.
  #
  # The id is minted against whatever `Config.server_url/0` resolves, and every
  # tier of that answers with the *calling* build: a dev checkout says
  # localhost:4000, a packaged release says codemyspec.com. Onboarding a sibling
  # repo from here therefore mints into a database the daemon that actually
  # serves it has never seen, and the failure surfaces much later as "No harness
  # with id …", which reads like a deleted row rather than two servers that
  # never shared one. Issue a6d07cf3.
  #
  # A flag rather than something read off the target: a checkout has no key that
  # names its server. `.code_my_spec/config.yml` carries `client_api_url`, which
  # is where the *deployed app* talks — this repo's says codemyspec.com while
  # its harness is localhost — so reading it would be confidently wrong.
  # Four tiers, most specific first: what the caller typed, what this copy
  # recorded when its id was minted, what the project says in its committed
  # config, and failing all of those the build's own default.
  #
  # The copy above the project because a project served by dev.codemyspec.com on
  # one machine and codemyspec.com on another cannot have one right answer in a
  # tracked file — the committed value is the project's default and the copy's
  # record is what actually happened. And the project above the build's default
  # because it is the only tier that can answer *before* a copy exists, which is
  # the first onboard of a foreign root: the case the flag exists for, now with
  # something to fall back on when nobody typed it.
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

  defp put_device_flag(args) do
    case device_flag(args) do
      nil -> Application.delete_env(:code_my_spec, :onboard_device_id)
      id -> Application.put_env(:code_my_spec, :onboard_device_id, id)
    end
  end

  defp device_flag(["--device", id | _rest]) when is_binary(id), do: id
  defp device_flag([_arg | rest]), do: device_flag(rest)
  defp device_flag([]), do: nil

  # A checkout's own `.code_my_spec/` is where its specs live, not a checkout.
  #
  # Onboarding it registers a second working copy on the same project, and that
  # copy then takes analysis runs the real root should have had — every one of
  # which dies with no `mix.exs` a level down, while the real root's staleness
  # never clears. It reconnected for days before anybody traced it (49e8340e).
  #
  # Caught here as well as server-side because `cd .code_my_spec && mix
  # cms.harness.onboard` is how somebody gets there, and a refusal at the point
  # of the mistake can name the directory to use instead. `Path.expand/1` first
  # so `.code_my_spec/.` and a trailing slash are the same answer.
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
    case Environments.read_file(env, @harness_config_file) do
      {:ok, contents} -> existing_id(contents, env, root)
      _ -> mint(root, project_id)
    end
  end

  # Both key names, new one first — the compatibility window `HarnessConfig`
  # already implements, which this had been left out of.
  #
  # It read only `harness_id` while `mint_and_record/2` below wrote only
  # `working_copy_id`, so a copy onboarded twice found nothing the second time
  # and was minted a *fresh* identity — orphaning every file, problem and
  # session recorded against the first. Criterion 2356 is "onboarding twice is
  # the same as onboarding once"; this was the opposite.
  defp existing_id(contents, env, root) do
    case Jason.decode(contents) do
      {:ok, map} -> recorded_id(map, env, root)
      _ -> mint_and_record(env, root)
    end
  end

  defp recorded_id(%{"working_copy_id" => id}, _env, _root) when is_binary(id) and id != "",
    do: {:ok, id}

  defp recorded_id(%{"harness_id" => id}, _env, _root) when is_binary(id) and id != "",
    do: {:ok, id}

  defp recorded_id(_map, env, root), do: mint_and_record(env, root)

  defp mint_and_record(env, root) do
    with {:ok, id} <- mint(root, nil) do
      # Both names, matching `HarnessConfig.write/2`. This writes through
      # `Environments` rather than that function because the copy may be on
      # another machine — which is exactly how it drifted out of step with it.
      body = Jason.encode!(%{working_copy_id: id, harness_id: id, root: root}, pretty: true)
      Environments.write_file(env, @harness_config_file, body)
      {:ok, id}
    end
  end

  # A checkout with no id asks the server for one. Waiting for a channel join
  # to mint it cannot work for a copy nobody serves yet: the harness learns
  # which copies to serve by looking ids up, so a copy with no id would never
  # be served and would never acquire one.
  defp mint(root, project_id) do
    with {:ok, project} <- project_for(root, project_id),
         _ = ensure_local_credential(project.id),
         {:ok, token} <- Token.access_token(),
         {:ok, %{status: 200, body: %{"harness_id" => id}}} <- post(project, root, token),
         :ok <-
           HarnessConfig.write(root, %{
             working_copy_id: id,
             project_id: project.id,
             # Written down because the id is only meaningful to the server that
             # issued it, and nothing else can say which that was: every tier of
             # `Config.server_url/0` answers with the build doing the *reading*.
             # A later run on this copy reads it back rather than defaulting to
             # its own server and 404ing against a row it never had (a6d07cf3).
             server_url: Config.server_url(),
             root: root
           }) do
      Mix.shell().info("Issued a new harness id for #{root}")
      {:ok, id}
    else
      {:error, :no_project_id} ->
        {:error,
         """
         #{root} does not say which project it is.

         Put a `project_id` in .code_my_spec/config.yml. In a fresh worktree the
         submodule is usually just not checked out: `git submodule update --init
         .code_my_spec`.
         """}

      # Named, because the generic version sent a reader to the wrong place.
      # `:no_credential` reads as "you have no credential"; when onboarding
      # against a server this machine's database does not back, the truth is
      # "your credential is for another server, and nothing here can find it".
      # The devops agent read it the first way and was about to send an operator
      # to generate a key that would not have helped.
      {:error, :no_credential} ->
        {:error,
         """
         No credential to mint a harness id for #{root} against #{Config.server_url()}.

         A deploy key reaches exactly one project on exactly one server. This task
         reads one from this machine's database, which only holds projects for a
         CodeMySpec running here — so onboarding against anything else needs the
         key passed in:

             CMS_DEPLOY_KEY=<a key from that server> \\
               mix cms.harness.onboard #{root} --project <that server's project id>

         Generate one on that server's project page if it has none.
         """}

      other ->
        {:error, "Could not get a harness id for #{root} from the server: #{inspect(other)}"}
    end
  end

  # Which project this checkout belongs to.
  #
  # `--project` wins. Without it the answer comes from the directory —
  # `.code_my_spec/config.yml`, then an existing `.cms_harness.json` — which is
  # right when a checkout knows what it is and useless when it does not. A
  # checkout being onboarded for the first time often does not: the submodule
  # carrying that config may not even be checked out yet.
  #
  # Silently adopting whatever the directory named is the failure this fixes. It
  # attached a scratch directory to an unrelated project and minted a working
  # copy there, with nothing in the output saying so.
  defp project_for(root, nil), do: ProjectIdentity.resolve(root)

  defp project_for(root, project_id) do
    case ProjectIdentity.resolve(root) do
      {:ok, %{id: ^project_id}} = resolved ->
        resolved

      {:ok, %{id: other}} ->
        # Said out loud rather than resolved quietly either way. One of the two
        # is wrong and only the person running this knows which.
        Mix.shell().info([
          :yellow,
          "warning: #{root} says it belongs to project #{other}, and you asked for " <>
            "#{project_id}. Using #{project_id}. If that is wrong, fix " <>
            "`.code_my_spec/config.yml` in that checkout rather than passing the flag.",
          :reset
        ])

        {:ok, %{id: project_id, root: root, working_copy_id: nil}}

      {:error, _reason} ->
        {:ok, %{id: project_id, root: root, working_copy_id: nil}}
    end
  end

  defp post(project, root, token) do
    Req.post(
      url:
        Config.server_url()
        |> String.trim_trailing("/")
        |> Kernel.<>("/api/harnesses"),
      json: %{
        project_id: project.id,
        root: root,
        label: Config.label(root),
        device_id: device_id()
      },
      headers: [{"authorization", "Bearer " <> token}],
      retry: false,
      receive_timeout: to_timeout(second: 15)
    )
  end

  # Which machine this checkout is on. Two cases, and they want opposite
  # answers.
  #
  # Installing on somebody's own machine, the answer is the machine we are
  # standing in, and it already has an identity: `Device.announce/0` writes one
  # to `~/.codemyspec/device.json` the first time a harness comes up here, and
  # `recorded_id/0` reads it. Minting a second identity for a machine that
  # already has one is the duplicate this is trying to stop, one level up.
  #
  # Installing on our dev box, we are onboarding a checkout for a machine we
  # are not: several people share it, and the box's own identity is not the
  # answer for any of them. So it is passed explicitly, and nothing tries to
  # infer it.
  #
  # A machine that has never run a harness has no identity yet, and this is
  # usually the first thing that runs on it — so it announces, the same way the
  # harness does at boot, rather than leaving the copy machine-less. The
  # credential is already in hand: `mint/2` exchanged the deploy key a few lines
  # up, which is what `announce/0` asks `Token.access_token/0` for.
  #
  # Announcing is idempotent by design. It presents the id we hold, and that is
  # how the server recognises the machine instead of minting another, so this is
  # safe on a box that has onboarded a dozen checkouts.
  defp device_id do
    case Application.get_env(:code_my_spec, :onboard_device_id) do
      id when is_binary(id) and id != "" -> id
      _ -> CmsHarness.Device.recorded_id() || announced_id()
    end
  end

  # `nil` when the announce could not reach the server. It logs its own warning
  # and the mint below will fail on the same unreachable server a moment later,
  # so there is nothing useful to add here.
  defp announced_id do
    case CmsHarness.Device.announce() do
      {:ok, %{device_id: id}} -> id
      {:error, _reason} -> nil
    end
  end

  # The model turns, same question again.
  #
  # This one cannot be addressed by the plugin: a Claude Code plugin has no way
  # to set an environment variable for the session, and `ANTHROPIC_BASE_URL` is
  # read by the agent process itself, posted to directly, never through the
  # relay. Claude Code's settings are where a checkout says what its sessions
  # run with, so that is where the address goes — the one thing left that
  # genuinely has to carry this working copy's id, because nothing reads it
  # back off a file or a header the way hooks and MCP do.
  #
  # `settings.local.json`, not `settings.json`. The URL carries this working
  # copy's harness id, and `settings.json` is tracked — writing it there would
  # commit one machine's identity into every checkout that clones the repo. The
  # `.local` file is gitignored by convention and Claude Code merges it over
  # the tracked one.
  #
  # Merged, never replaced, because it is still a file the operator may have
  # written in: it keeps every key already there and rewrites exactly one.
  #
  # Without it the turn arrives unaddressed, and an unaddressed turn is only
  # recordable when the harness serves exactly one working copy. A sprite is
  # that shape; a developer's machine never is, which is why local Claude Code
  # has never appeared in the conversations UI.
  #
  # ## `CMS_HARNESS_ID` rides along, and has to
  #
  # The plugin's MCP mount sends `X-Harness-Id: ${CMS_HARNESS_ID}` — the only
  # way it *can* name a working copy, because a `mcpServers` entry interpolates
  # environment variables and cannot read a file. The hook shims walk up for
  # `.cms_harness.json` themselves; an MCP mount has no such move.
  #
  # Nothing set that variable, which is precisely the failure `hooks_controller`
  # already documents: the header arrived as the literal `${CMS_HARNESS_ID}` on
  # every hook, and the server has a clause for it. Now that identity is the
  # only routing key, an unexpanded one is a refusal rather than a fallback, so
  # shipping the header without this line would have taken MCP down for every
  # checkout.
  #
  # Written here rather than exported by a shell, because a session inherits
  # this file and not anyone's `.zshrc`, and because it lands next to the URL
  # that already carries the same id — one place, one value.
  #
  # Public only so it can be tested directly. It is the one thing here that
  # writes a file the operator owns, so "keeps what was already there" has to be
  # checkable rather than asserted in a comment.
  @doc false
  def address_model_turns(env, root, id, base_url \\ nil) do
    # Rendered by the shared function, not here. This string existed twice and the
    # two disagreed — `/api/harnesses/<id>` against `/harnesses/<id>/anthropic`,
    # only one of which is a real route (3498d841). Two derivations of one value is
    # the defect this story removes, and the refactor meant to fix it reintroduced
    # it in the split.
    write_settings(env, root, id, true, base_url || default_hook_base_url())
  end

  # Both shapes are one call into `Onboarding.onboard/2`.
  #
  # This was `write_address/4` plus a private `read_settings/1`, and both were
  # reimplementations. The merge that keeps every key the operator already had,
  # and the refusal to rewrite a settings file that is not valid JSON — "a
  # half-edited settings file is exactly the state someone is in when they run
  # this to fix it" — were written here and, in the same words, in
  # `client_utils`. Two copies of a rule about not destroying somebody's file is
  # one copy too many.
  #
  # `onboard/2` also writes `.cms_harness.json` and sets `submodule.recurse`,
  # which this path did not. Both are idempotent, and both are things every
  # onboarded copy should have — a copy that was addressed but never given a
  # harness config is exactly the half-state `check/2` now reports as
  # `HARNESS_CONFIG` missing.
  defp write_settings(env, root, id, relay_model_turns?, base_url) do
    # `working_copy_id:`, not `working_copy_id:`. This crosses into `ClientUtils`,
    # which is a separate repository on its own release cadence — generated apps
    # take it from hex — so its option names are as external as the wire and
    # cannot be renamed from here. It moves when client_utils moves.
    # `harness_id:`, not `working_copy_id:`. This crosses into `ClientUtils`,
    # which is a separate repository on its own release cadence — generated apps
    # take it from hex — so its option names are as external as the wire and
    # cannot be renamed from here. It moves when client_utils moves.
    opts = [
      io: io(env),
      app: target_app(root),
      harness_id: id,
      relay_model_turns: relay_model_turns?,
      deploy_key: deploy_key_for(root),
      # Passed as well as written by `mint/2`, so the two writers of this file
      # agree. `mint/2` only runs when a copy has no id yet; every re-onboard
      # goes straight here, and a run that recorded nothing would leave a copy
      # minted before this existed without an answer forever.
      server_url: Config.server_url()
    ]

    opts = if base_url, do: Keyword.put(opts, :base_url, base_url), else: opts

    case Onboarding.onboard(root, opts) do
      %{settings: {:ok, _path}} -> :ok
      %{settings: {:error, reason}} -> {:error, describe_settings_error(reason)}
    end
  end

  # This project's own key, read out of the database this machine already has —
  # a local dev server and this task read the same `code_my_spec_dev`, so there
  # is nothing to keep in sync. `onboard/2` records it in `.cms_harness.json`,
  # so the daemon that serves this copy afterwards can authenticate *as this
  # project*: a deploy key reaches exactly one, and one daemon serves several
  # working copies.
  #
  # Read even when `CMS_DEPLOY_KEY` is already exported, which is the case that
  # matters — onboarding a second project's checkout from a shell carrying the
  # first project's key. The exported one is wrong for this copy by
  # construction; the row in the database is right.
  #
  # `nil` is ordinary and not an error: no local database, a project it does not
  # know, or a project with no key generated yet. `onboard/2` then leaves any key
  # already recorded alone, and the copy is served by whatever the daemon holds
  # — which is correct whenever that is this project's key.
  defp deploy_key_for(root) do
    with {:ok, project} <- ProjectIdentity.resolve(root),
         key when is_binary(key) and key != "" <- local_project_deploy_key(project.id) do
      key
    else
      _ -> nil
    end
  end

  # `client_utils` returns its own refusal sentence for malformed JSON and a raw
  # posix reason for anything else. The sentence is passed through rather than
  # rewritten: it is the useful one, and inventing a second wording for it here
  # is how the two implementations drifted to begin with.
  defp describe_settings_error(reason) when is_binary(reason), do: reason

  defp describe_settings_error(reason),
    do: "Could not write #{@settings_file}: #{inspect(reason)}"

  # `put_new`, unlike the URL beside it. The address has to be corrected when the
  # harness id changes; the partition must not move once anything has been built
  # against it, and a second onboarding re-deriving it from the path would rename
  # a database that already has migrations in it.
  #
  # Recorded here, in the file the agent's session reads as environment, because
  # that is what makes it *the* name rather than one of several. Two mechanisms
  # derive this today — `config/test.exs` from the worktree path and
  # `TestDatabase` from a digest of the cwd — and `analyzer_env.ex` says what
  # follows in its own words: "different databases, by accident of two mechanisms
  # rather than by design". An agent hit exactly that on 2026-08-13, was told to
  # run a migrate against a database the command did not touch, and stayed blocked
  # for three days across 50 rejected runs.

  # Git settings a working copy needs, applied to the copy itself.
  #
  # `submodule.recurse` because a submodule sits in detached HEAD by design and so
  # accepts writes with no branch to carry them. Four QA briefs — including the
  # evidence behind a story shipped with QA recorded complete — existed in exactly
  # one working copy for a day because of it, and nothing reported a problem: the
  # superproject's dirty-pointer line is suppressed project-wide, for unrelated
  # and well-reasoned purposes.

  # The harness a model turn is posted to. Hooks and MCP resolve this working
  # copy on their own now (`.cms_harness.json`, `${CMS_HARNESS_ID}`); this is
  # the one address that still has to be told, because Claude Code's own
  # Anthropic client posts here directly and reads nothing back off a file.
  #
  # This used to default to `Config.server_url()` — the CodeMySpec server. That
  # is the wrong host entirely: `/api/harnesses/:working_copy_id/v1/messages` exists
  # only in `CmsHarness.Web.Router`, never in `CodeMySpecWeb.Router`, so an
  # agent pointed there posts every turn to a route that does not exist. The
  # feature could not have worked as written.
  #
  # The tests did not catch it because every one of them passes an explicit
  # `@base "http://localhost:4003"`. The parameter that exists "only so it can
  # be tested directly" is exactly what kept the default off the tested path —
  # so the default now has a test of its own below.
  #
  # Matches the shipped plugin's hooks, which is `--port 4004` unconditionally
  # — there is no generated file left to read a port out of. `CMS_HARNESS_PORT`
  # wins, because a sprite sets it and its harness is the thing serving hooks.
  defp default_hook_base_url do
    "http://localhost:#{System.get_env("CMS_HARNESS_PORT") || "4004"}"
  end
end
