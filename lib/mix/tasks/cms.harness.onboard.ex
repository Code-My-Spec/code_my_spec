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

    with {:ok, id} <- identity(root),
         :ok <- copy_plugin(root, dest),
         {:ok, count} <- address_hooks(dest, id),
         :ok <- address_mcp(dest, id) do
      report(id, dest, count, args)
    else
      {:error, message} -> Mix.raise(message)
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
  defp address_hooks(dest, id) do
    file = Path.join([dest, "hooks", "hooks.json"])

    case File.read(file) do
      {:ok, contents} ->
        File.write!(file, String.replace(contents, "/api/hooks/", "/api/harnesses/#{id}/hooks/"))

        {:ok, contents |> String.split("/api/hooks/") |> length() |> Kernel.-(1)}

      {:error, reason} ->
        {:error, "Could not read #{file}: #{inspect(reason)}"}
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
