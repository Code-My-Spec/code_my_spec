defmodule Mix.Tasks.Cms.Harness.Onboard do
  @shortdoc "Point this working copy's agent hooks at its own harness id"

  @moduledoc """
  Address this checkout's hooks to the harness that serves it.

      mix cms.harness.onboard

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

    case Enum.member?(args, "--check") do
      true -> check(env, root)
      false -> onboard(env, root, relay_model_turns?)
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
  defp environment(root, args) do
    case project_flag(args) do
      nil ->
        {:ok, env} = Environments.create(:local, working_dir: root)
        env

      project_id ->
        case Environments.lookup_registered(project_id) do
          nil -> Mix.raise("no environment is registered for project #{project_id}")
          env -> env
        end
    end
  end

  defp project_flag(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      ["--project", id] -> id
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
  # So this asserts the keys `address_model_turns/4` writes. `client_utils`
  # carries the same fix in `Onboarding.check/2` — two implementations, which is
  # this story's own complaint about onboarding, and they are kept in step by
  # naming the same three keys rather than by one calling the other: this side
  # reads through `Environments` so specs can drive an in-memory copy.
  defp check(env, root) do
    missing = missing_settings(env)
    onboarded = missing == []
    announce_check(onboarded, missing, root)

    %{onboarded: onboarded, missing: missing, remedy: "mix cms.harness.onboard"}
  end

  # `ANTHROPIC_BASE_URL` is not required: it is opt-in (`--relay-model-turns`)
  # precisely because most working copies should not carry it — see
  # `address/4`'s comment — so a copy that never asked for it is not
  # half-onboarded for lacking it. If it *is* present, `missing_settings/1`
  # below still checks it is not the dangling-prefix shape a refused mint
  # leaves; presence with a broken value is still reported.
  @required_env ["CMS_HARNESS_ID", "MIX_TEST_PARTITION"]

  defp missing_settings(env) do
    settings =
      case Environments.read_file(env, @settings_file) do
        {:ok, contents} -> decode_env(contents)
        _ -> %{}
      end

    Enum.filter(@required_env, &blank_or_invalid?(&1, Map.get(settings, &1))) ++
      invalid_if_present(settings, "ANTHROPIC_BASE_URL")
  end

  defp invalid_if_present(settings, key) do
    case Map.get(settings, key) do
      nil -> []
      value -> if blank_or_invalid?(key, value), do: [key], else: []
    end
  end

  defp decode_env(contents) do
    case Jason.decode(contents) do
      {:ok, %{"env" => env}} when is_map(env) -> env
      _ -> %{}
    end
  end

  # Checked for an id rather than for presence: the measured failure had
  # `http://localhost:4004/api/harnesses/` — the prefix with nothing after it,
  # which is not a route to anything and is what a run that refused before
  # learning its harness id leaves behind.
  defp blank_or_invalid?("ANTHROPIC_BASE_URL", value) when is_binary(value) do
    case String.split(value, "/api/harnesses/") do
      [_prefix, id] -> String.trim(id) == ""
      _ -> true
    end
  end

  defp blank_or_invalid?(_key, value) when is_binary(value), do: String.trim(value) == ""
  defp blank_or_invalid?(_key, _value), do: true

  defp announce_check(true, _missing, root) do
    Mix.shell().info("onboarded: #{root}")
  end

  # Names them, because "not onboarded" alone sends the reader back to the file
  # to work out which half failed — and the half-onboarded copy, file present
  # and some keys right, is where that costs most.
  defp announce_check(false, [_ | _] = missing, root) do
    Mix.shell().info(
      "not onboarded: #{root}\n  missing: #{Enum.join(missing, ", ")}\n" <>
        "run: mix cms.harness.onboard"
    )
  end

  defp announce_check(false, _missing, root) do
    Mix.shell().info("not onboarded: #{root}\nrun: mix cms.harness.onboard")
  end

  defp onboard(env, root, relay_model_turns?) do
    bootstrap_local_dev_env(root)

    with {:ok, id} <- identity(env, root),
         :ok <- address(env, root, id, relay_model_turns?) do
      git = configure_git(env)
      outstanding(root, id, git)
    else
      {:error, message} -> Mix.raise(message)
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
  def address_mcp(env, root, id), do: write_address(env, root, id, %{})

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
  # exactly as it did before this existed (a real `CMS_DEPLOY_KEY`/`CMS_TOKEN`
  # already in the environment still wins, and is never overwritten).
  defp ensure_local_credential(project_id) do
    if blank?(System.get_env("CMS_DEPLOY_KEY")) do
      case local_project_deploy_key(project_id) do
        key when is_binary(key) and key != "" -> System.put_env("CMS_DEPLOY_KEY", key)
        _ -> :ok
      end
    end

    :ok
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
  defp outstanding(root, id, git) do
    partition = Onboarding.partition_name(root)
    databases = Onboarding.databases(partition, Mix.Project.config()[:app])

    # Everything the report knows, the terminal says. The report is the callable
    # answer and the print is the readable one, and they carry the same facts —
    # anything present in one and absent from the other is the `--check` defect
    # waiting to happen again.
    Mix.shell().info("""

    onboarded: #{root}
      harness id: #{id}
      partition:  #{partition}
      submodules: #{if git, do: "recursing", else: "not configured"}
      databases:  #{Enum.map_join(databases, ", ", & &1.name)}
                  made on the first `mix test` / `mix spex` that needs them
    """)

    %{
      harness_id: id,
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
  defp target_root(args), do: args |> drop_flags() |> first_path()

  defp drop_flags(["--project", _id | rest]), do: drop_flags(rest)
  defp drop_flags(["--" <> _ | rest]), do: drop_flags(rest)
  defp drop_flags([arg | rest]), do: [arg | drop_flags(rest)]
  defp drop_flags([]), do: []

  defp first_path([path | _]) when is_binary(path), do: Path.expand(path)
  defp first_path(_), do: File.cwd!()

  # Read through the environment, so a working copy that already has an id is a
  # file the spec wrote through the same surface — not a fixture reaching past it.
  defp identity(env, root) do
    case Environments.read_file(env, @harness_config_file) do
      {:ok, contents} -> existing_id(contents, env, root)
      _ -> mint(root)
    end
  end

  defp existing_id(contents, env, root) do
    case Jason.decode(contents) do
      {:ok, %{"harness_id" => id}} when is_binary(id) and id != "" -> {:ok, id}
      _ -> mint_and_record(env, root)
    end
  end

  defp mint_and_record(env, root) do
    with {:ok, id} <- mint(root) do
      body = Jason.encode!(%{harness_id: id, root: root}, pretty: true)
      Environments.write_file(env, @harness_config_file, body)
      {:ok, id}
    end
  end

  # A checkout with no id asks the server for one. Waiting for a channel join
  # to mint it cannot work for a copy nobody serves yet: the harness learns
  # which copies to serve by looking ids up, so a copy with no id would never
  # be served and would never acquire one.
  defp mint(root) do
    with {:ok, project} <- ProjectIdentity.resolve(root),
         _ = ensure_local_credential(project.id),
         {:ok, token} <- Token.access_token(),
         {:ok, %{status: 200, body: %{"harness_id" => id}}} <- post(project, root, token),
         :ok <- HarnessConfig.write(root, %{harness_id: id, project_id: project.id, root: root}) do
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

      other ->
        {:error, "Could not get a harness id for #{root} from the server: #{inspect(other)}"}
    end
  end

  defp post(project, root, token) do
    Req.post(
      url:
        Config.server_url()
        |> String.trim_trailing("/")
        |> Kernel.<>("/api/harnesses"),
      json: %{project_id: project.id, root: root, label: Config.label(root)},
      headers: [{"authorization", "Bearer " <> token}],
      retry: false,
      receive_timeout: to_timeout(second: 15)
    )
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
    url = Onboarding.anthropic_url(base_url || default_hook_base_url(), id)

    write_address(env, root, id, %{"ANTHROPIC_BASE_URL" => url})
  end

  # Shared by `address_model_turns/4` and `address_mcp/3`: both keep every key
  # the operator already had (`Map.get("env", %{})` starts from what's there,
  # `extra` only adds), so a bare re-run never blanks out an address a prior,
  # opted-in run already wrote — it just isn't asked to write one itself.
  defp write_address(env, root, id, extra) do
    with {:ok, settings} <- read_settings(env) do
      env_block =
        settings
        |> Map.get("env", %{})
        |> Map.merge(extra)
        |> Map.put("CMS_HARNESS_ID", id)
        |> Map.put_new("MIX_TEST_PARTITION", Onboarding.partition_name(root))

      merged = Map.put(settings, "env", env_block)

      case Environments.write_file(env, @settings_file, Jason.encode!(merged, pretty: true)) do
        :ok -> :ok
        {:error, reason} -> {:error, "Could not write #{@settings_file}: #{inspect(reason)}"}
      end
    end
  end

  # Absent is an empty object; empty is an empty object; unparseable is a refusal.
  #
  # The distinction is the operator's file. Treating malformed JSON as "no
  # settings" would rewrite it from scratch and destroy whatever they were
  # halfway through editing — and a half-edited settings file is exactly the
  # state someone is in when they run this to fix it.
  defp read_settings(env) do
    case Environments.read_file(env, @settings_file) do
      {:ok, ""} ->
        {:ok, %{}}

      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = settings} ->
            {:ok, settings}

          _ ->
            {:error,
             "#{@settings_file} is not valid JSON. Refusing to overwrite it — fix or " <>
               "move it and run this again."}
        end

      _ ->
        {:ok, %{}}
    end
  end

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
  # is the wrong host entirely: `/api/harnesses/:harness_id/v1/messages` exists
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
