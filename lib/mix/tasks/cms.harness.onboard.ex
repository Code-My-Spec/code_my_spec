defmodule Mix.Tasks.Cms.Harness.Onboard do
  @shortdoc "Point this working copy's agent hooks at its own harness id"

  @moduledoc """
  Address this checkout's hooks to the harness that serves it.

      mix cms.harness.onboard

  Reads the id the server issued this working copy and writes a plugin
  directory whose hooks post to `/api/harnesses/<id>/hooks/*` instead of the
  shared `/api/hooks/*`. Start the agent against that directory and every hook
  it fires says which checkout it came from.

  ## Why a generated directory

  The tracked plugin under `plugins/claude` has to stay generic: it is what the
  release packager ships, and a harness id baked into a published plugin would
  be one machine's identity handed to everyone who installs it. The tracked
  copy also cannot simply be edited in place — it is tracked, so an id written
  into it is an id committed, and a committed id is cloned into every checkout.
  That is the corruption the id exists to prevent.

  So this writes somewhere gitignored, per working copy, and leaves the shipped
  plugin alone.

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

  @settings_file ".claude/settings.local.json"
  @harness_config_file ".cms_harness.json"
  @plugin_source "plugins/claude"
  @plugin_dest ".claude/plugin-dev"

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
    dest = Path.join(root, @plugin_dest)
    env = environment(root, args)

    case Enum.member?(args, "--check") do
      true -> check(env, root)
      false -> onboard(env, root, dest, args)
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

  @required_env ["CMS_HARNESS_ID", "MIX_TEST_PARTITION", "ANTHROPIC_BASE_URL"]

  defp missing_settings(env) do
    settings =
      case Environments.read_file(env, @settings_file) do
        {:ok, contents} -> decode_env(contents)
        _ -> %{}
      end

    Enum.filter(@required_env, &blank_or_invalid?(&1, Map.get(settings, &1)))
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

  defp onboard(env, root, dest, args) do
    with {:ok, id} <- identity(env, root),
         :ok <- address_model_turns(env, root, id, hook_base_url(dest)) do
      git = configure_git(env)
      hooks = install_hooks(env, root, dest, id, args)
      outstanding(env, root, id, git, hooks)
    else
      {:error, message} -> Mix.raise(message)
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

  # The relay gates the hooks, not the command.
  #
  # It used to gate everything: no usable relay and nothing was written at all.
  # The reasoning was sound for what it guarded — the hooks it installs are run
  # by that binary, and installing hooks that cannot run is worse than installing
  # none. It does not extend to the rest. A working copy's identity, its
  # partition, its git config and its Anthropic address have nothing to do with
  # the relay, and refusing them because one of six steps is unavailable leaves
  # the copy unonboarded for a reason that explains none of its symptoms.
  #
  # That is this story's own anti-pattern arriving from inside: a missing thing
  # reported as something else. Now the copy is onboarded, the hooks are reported
  # as skipped, and the reason is on screen.
  defp install_hooks(%{type: :memory}, _root, _dest, _id, _args),
    do: {:skipped, "no directory to install into"}

  defp install_hooks(_env, root, dest, id, args) do
    with {:ok, relay} <- check_relay(),
         :ok <- copy_plugin(root, dest),
         {:ok, count} <- address_hooks(dest, id, relay),
         :ok <- address_mcp(dest, id) do
      report(id, dest, count, args)
      {:ok, count}
    else
      {:error, message} ->
        Mix.shell().info("\nHooks not addressed:\n#{message}")
        {:skipped, message}
    end
  end

  # Named, never run. Onboarding does not create, migrate or drop a database, and
  # the rule is not stylistic: the version of this that did shelled out to `mix`
  # with an environment that had `MIX_ENV` scrubbed out of it, so it resolved to
  # **dev** — the database every agent shares — and a sibling truncate emptied it
  # three times on 2026-08-13, reporting the rows it destroyed as escaped test
  # data while it did so.
  #
  # Each command carries its own partition, because a command that does not say
  # which database it acts on is the defect this replaces: the migration guard
  # printed `MIX_ENV=test mix ecto.migrate` while checking a partition that
  # command never touches.
  defp outstanding(_env, root, id, git, hooks) do
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
      hooks:      #{describe_hooks(hooks)}
    """)

    Mix.shell().info("Databases this working copy needs (create and migrate them yourself):")

    Enum.each(databases, fn database ->
      Mix.shell().info("  #{database.name}\n    #{database.create}\n    #{database.migrate}")
    end)

    %{
      harness_id: id,
      partition: partition,
      databases: databases,
      git: %{submodule_recurse: git},
      hooks: hooks,
      issued_ddl: false
    }
  end

  defp describe_hooks({:ok, count}), do: "addressed (#{count})"
  defp describe_hooks({:skipped, reason}), do: "skipped — #{first_line(reason)}"

  defp first_line(text) do
    text |> String.split("\n", parts: 2) |> hd() |> String.trim()
  end

  @relay "cms-mcp-relay"
  @capability "hooks=1"

  # Named in the refusal so the operator knows what to wait for, not used to
  # decide anything. The check is the capability, because "which version" is
  # never the question — a checkout build carries the subcommand with no
  # release number at all, and pinning a number would reject it.
  @min_release "codemyspec 2.0"

  # Refuse before writing anything, because the thing being written depends on
  # a binary this does not ship.
  #
  # The hooks it installs are `cms-mcp-relay hook --port … /api/hooks/<name>`.
  # A relay from before that subcommand existed does not reject the argument —
  # `hook` is not a flag it knows, so it falls through to the MCP path, posts
  # the hook payload to /mcp?dir=, takes the JSON-RPC parse error it gets back
  # and exits 0. Claude Code reads 0 as a hook that ran. All eight go silently
  # dead, and the only symptom is that everything the harness was supposed to
  # decide quietly stops happening — no error anywhere, on either side.
  #
  # So the marker is the gate. An old binary cannot print it: it has no
  # `capabilities` branch either and relays stdin instead, which with stdin
  # closed is an immediate EOF and an empty stdout. Absence is the answer.
  defp check_relay do
    case System.find_executable(@relay) do
      nil ->
        {:error,
         """
         No #{@relay} on PATH.

         The hooks this installs are run by it. Without it every hook is a
         command that does not exist, which Claude Code reports per turn.
         """}

      path ->
        if capable?(path) do
          {:ok, path}
        else
          {:error,
           """
           #{path} is too old for the hooks this would install.

           It has no `hook` subcommand, and it does not fail when given one:
           it treats the payload as MCP traffic, and exits 0. Claude Code
           reads that as a hook that ran, so onboarding this working copy
           would leave every hook silently dead rather than visibly broken.

           The hook subcommand ships in #{@min_release}. Upgrade, then run
           this again:

               brew upgrade codemyspec

           Working from a checkout instead — which is how to get it before
           that release exists:

               (cd relay && go build -o cms-mcp-relay .)
               mkdir -p ~/.codemyspec/bin
               cp relay/cms-mcp-relay ~/.codemyspec/bin/
               export PATH="$HOME/.codemyspec/bin:$PATH"

           Nothing has been written — this refused before touching the plugin
           config or .claude/settings.local.json.
           """}
        end
    end
  end

  # Stdin closed on purpose: a relay that does not know the argument reads
  # stdin, and a probe that inherits a terminal would sit there. The timeout is
  # the backstop for anything that manages to block anyway — a probe that hangs
  # must not become an onboarding that hangs.
  @doc false
  def capable?(path) do
    task =
      Task.async(fn ->
        case System.cmd(path, ["capabilities"], stderr_to_stdout: true) do
          {out, 0} -> String.contains?(out, @capability)
          _ -> false
        end
      end)

    case Task.yield(task, to_timeout(second: 10)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> false
    end
  end

  # Takes a path so one checkout can onboard another. A worktree on an older
  # branch does not have this task, and asking somebody to merge a branch
  # before they can be onboarded is a worse first experience than a positional
  # argument.
  defp target_root([path | _]) when is_binary(path), do: Path.expand(path)
  defp target_root(_), do: File.cwd!()

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

  defp copy_plugin(root, dest) do
    source = Path.join(root, @plugin_source)

    if File.dir?(source) do
      File.rm_rf!(dest)
      File.mkdir_p!(Path.dirname(dest))
      File.cp_r!(source, dest)
      :ok
    else
      {:error, "No #{@plugin_source} at #{source} — run this from a checkout root."}
    end
  end

  # Only the hook paths move. The port, the headers and the payload are the
  # shipped plugin's and stay as they are, so the generated copy differs from
  # what users run in exactly one respect.
  # The relay is pinned by absolute path, not left as a bare command.
  #
  # `check_relay/0` resolves it on *this* PATH; Claude Code resolves the hook
  # command on *its* PATH, minutes or days later, from a login shell this never
  # saw. Those are only the same binary by luck, and the way to have the hook
  # subcommand before 2.0 ships is a checkout build on a prepended PATH — which
  # is precisely the case where they differ. Onboarding would then verify a
  # capable relay, write a bare command, and every session would run the old
  # one: hooks silently dead, with the check having passed.
  #
  # Writing the path the check actually verified makes run time and check time
  # the same binary by construction. Safe here for the same reason the harness
  # id is: this directory is generated per working copy and gitignored, so a
  # machine-specific path in it is never shared and never committed.
  @doc false
  def address_hooks(dest, id, relay) do
    file = Path.join([dest, "hooks", "hooks.json"])

    case File.read(file) do
      {:ok, contents} ->
        addressed =
          contents
          |> String.replace("/api/hooks/", "/api/harnesses/#{id}/hooks/")
          |> String.replace(~s|"command": "#{@relay}"|, ~s|"command": #{Jason.encode!(relay)}|)

        File.write!(file, addressed)

        {:ok, contents |> String.split("/api/hooks/") |> length() |> Kernel.-(1)}

      {:error, reason} ->
        {:error, "Could not read #{file}: #{inspect(reason)}"}
    end
  end

  # The model turns, same question again.
  #
  # This one cannot be addressed in the plugin: a Claude Code plugin has no way
  # to set an environment variable for the session, and `ANTHROPIC_BASE_URL` is
  # read by the agent process itself. Claude Code's settings are where a
  # checkout says what its sessions run with, so that is where the address goes.
  #
  # `settings.local.json`, not `settings.json`. The URL carries this working
  # copy's harness id, and `settings.json` is tracked — writing it there would
  # commit one machine's identity into every checkout that clones the repo,
  # which is the corruption the id exists to prevent and the same reason the
  # plugin is generated rather than edited in place. The `.local` file is
  # gitignored by convention and Claude Code merges it over the tracked one.
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
    # it in the split. CodeMySpec still decides the *base*, because only it knows
    # the port the generated plugin was addressed to.
    url = Onboarding.anthropic_url(base_url || default_hook_base_url(), id)

    with {:ok, settings} <- read_settings(env) do
      env_block =
        settings
        |> Map.get("env", %{})
        |> Map.put("ANTHROPIC_BASE_URL", url)
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

  # The harness the hooks were just addressed to, so a model turn goes to the
  # same place they do.
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
  # Read out of the generated `hooks.json` rather than from config: that file is
  # what the hooks will actually post to, and deriving both from one source is
  # what stops them addressing different harnesses. Config would be a second
  # opinion that can disagree — `config.exs` says 4005 and the shipped plugin
  # says 4004, and they are both right about different deployments.
  defp hook_base_url(dest) do
    dest
    |> Path.join("hooks/hooks.json")
    |> File.read()
    |> case do
      {:ok, contents} -> contents |> hook_port() |> local_url()
      {:error, _reason} -> default_hook_base_url()
    end
  end

  # The value after `--port` in the first hook that names one. Deliberately not
  # a JSON walk: the shape is an array of args and the position of the flag is
  # the contract, so matching on the flag is both simpler and harder to break.
  defp hook_port(contents) do
    case Regex.run(~r/"--port"\s*,\s*"(\d+)"/, contents) do
      [_match, port] -> port
      nil -> nil
    end
  end

  defp local_url(nil), do: default_hook_base_url()
  defp local_url(port), do: "http://localhost:#{port}"

  # Matches the shipped plugin's hooks. `CMS_HARNESS_PORT` wins, because a
  # sprite sets it and its harness is the thing serving hooks.
  defp default_hook_base_url do
    local_url(System.get_env("CMS_HARNESS_PORT") || "4004")
  end

  # A missing file is an empty one. A malformed file is not — overwriting it
  # would throw away settings the operator wrote, so it stops and says so.

  # The MCP surface has the same question to answer as the hooks — which
  # working copy is this? — so it gets the same answer, written into the url
  # because this copy has the id in hand and nothing needs to be set for a url
  # to survive.
  #
  # The published plugin cannot do that: it is installed once and serves every
  # checkout, so it has no id at build time and interpolates
  # `${CMS_HARNESS_ID}` into a header instead. `HarnessScope` reads both — it
  # did not, which is why this rewrite spent its life producing a parameter the
  # server ignored.
  #
  # Matched on the header rather than the old `?dir=${CLAUDE_PROJECT_DIR}`,
  # which is gone from the source plugin. A `String.replace` against a string
  # that is no longer there does not fail; it writes the file back unchanged and
  # reports `:ok`.
  defp address_mcp(dest, id) do
    file = Path.join([dest, ".claude-plugin", "plugin.json"])

    with {:ok, contents} <- File.read(file),
         {:ok, addressed} <- swap_mcp_address(contents, id) do
      File.write!(file, addressed)
      :ok
    else
      {:error, :no_mcp_address} ->
        {:error,
         "#{file} has no local MCP mount to address. The source plugin's " <>
           "`mcpServers.local` entry is what this rewrites; if it moved, this moved too."}

      {:error, reason} ->
        {:error, "Could not read #{file}: #{inspect(reason)}"}
    end
  end

  @mcp_header ~s|"X-Harness-Id": "${CMS_HARNESS_ID}"|

  defp swap_mcp_address(contents, id) do
    case String.contains?(contents, @mcp_header) do
      true -> {:ok, String.replace(contents, @mcp_header, ~s|"X-Harness-Id": "#{id}"|)}
      false -> {:error, :no_mcp_address}
    end
  end

  defp report(id, dest, count, _args) do
    Mix.shell().info("""

    Harness id:  #{id}
    Plugin dir:  #{dest}
    Addressed:   #{count} hook endpoint(s)

    Start the agent against it:

        claude --plugin-dir #{dest}

    Every hook now names this working copy. A hook naming an id the harness
    does not serve is refused rather than resolved to a neighbouring checkout.
    """)
  end
end
