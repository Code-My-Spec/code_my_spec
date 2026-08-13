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

  alias CmsHarness.Config
  alias CmsHarness.HarnessConfig
  alias CmsHarness.ProjectIdentity
  alias CmsHarness.Token

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

    with {:ok, relay} <- check_relay(),
         {:ok, id} <- identity(root),
         :ok <- copy_plugin(root, dest),
         {:ok, count} <- address_hooks(dest, id, relay),
         :ok <- address_mcp(dest, id),
         :ok <- address_model_turns(root, id, hook_base_url(dest)) do
      report(id, dest, count, args)
    else
      {:error, message} -> Mix.raise(message)
    end
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
           config or .claude/settings.json.
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

  defp identity(root) do
    case HarnessConfig.read(root) do
      {:ok, %{harness_id: id}} ->
        {:ok, id}

      :none ->
        mint(root)

      {:error, reason} ->
        {:error, "Could not read #{HarnessConfig.path(root)}: #{inspect(reason)}"}
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
  # read by the agent process itself. `.claude/settings.json` is where a
  # checkout says what its sessions run with, so that is where the address goes.
  #
  # Merged, never replaced. This is a file the operator owns and checks in —
  # unlike the generated plugin copy — so it keeps every key already there and
  # rewrites exactly one.
  #
  # Without it the turn arrives unaddressed, and an unaddressed turn is only
  # recordable when the harness serves exactly one working copy. A sprite is
  # that shape; a developer's machine never is, which is why local Claude Code
  # has never appeared in the conversations UI.
  # Public only so it can be tested directly. It is the one thing here that
  # writes a file the operator owns, so "keeps what was already there" has to be
  # checkable rather than asserted in a comment.
  @doc false
  def address_model_turns(root, id, base_url \\ nil) do
    file = Path.join([root, ".claude", "settings.json"])
    url = "#{String.trim_trailing(base_url || default_hook_base_url(), "/")}/api/harnesses/#{id}"

    with {:ok, settings} <- read_settings(file),
         env <- settings |> Map.get("env", %{}) |> Map.put("ANTHROPIC_BASE_URL", url),
         merged <- Map.put(settings, "env", env),
         :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, Jason.encode_to_iodata!(merged, pretty: true)) do
      :ok
    else
      {:error, reason} -> {:error, "Could not write #{file}: #{inspect(reason)}"}
    end
  end

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
  defp read_settings(file) do
    case File.read(file) do
      {:ok, ""} ->
        {:ok, %{}}

      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, settings} when is_map(settings) -> {:ok, settings}
          _ -> {:error, :not_valid_json}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The MCP surface has the same question to answer as the hooks — which
  # working copy is this? — so it gets the same answer. Left on `?dir=` it
  # would be the one place a directory still decided something, and two
  # checkouts of one project would share an MCP session.
  defp address_mcp(dest, id) do
    file = Path.join([dest, ".claude-plugin", "plugin.json"])

    case File.read(file) do
      {:ok, contents} ->
        addressed =
          String.replace(contents, "/mcp?dir=${CLAUDE_PROJECT_DIR}", "/mcp?harness=#{id}")

        File.write!(file, addressed)
        :ok

      {:error, reason} ->
        {:error, "Could not read #{file}: #{inspect(reason)}"}
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
