defmodule CmsHarness.WorkingCopies.Create do
  @moduledoc """
  Making a checkout on this machine, because this is the machine with the disk.

  The server owns the record and cannot run `git worktree add` — it is not on
  this filesystem, and `fs_request` is scoped to one project root so it could
  not make a *sibling* even if it were. So the file half happens here and the
  record half happens there, and the caller made one call (story 891, rule "The
  harness does the work on disk and the server does the work on the record").

  Beside `CmsHarness.WorkingCopies` rather than inside it: that module answers
  *which copy an id names*, from configs already on disk, and needs no network
  and no repository. This runs git and writes into a new directory. One is a
  lookup and the other is an act.

  ## A worktree, not a clone

  A worktree shares the repository's object store, so making one costs a
  checkout of the tree rather than a copy of the history. That is the difference
  between a second and a minute here, and the whole point of the copy is that an
  agent can have one whenever there is work for it.

  It also keeps the copies on one filesystem, which is what lets the server key
  them on `(device_id, root)`. Two machines share a path constantly — every
  container at `/workspace/app` — and a clone somewhere else would need its own
  device before it meant anything.

  ## Identity is written here

  `.cms_harness.json` is what makes the directory a working copy rather than a
  directory. The id travels *in* with the request rather than back out with the
  reply, so what the server records and what the disk says are the same value
  rather than two derivations of it — which is the failure story 891 exists to
  end, and its notes list four of them by name.
  """

  require Logger

  alias ClientUtils.Harness.Onboarding
  alias CmsHarness.Config

  # The recipe a project owns for making a copy of itself.
  #
  # Called rather than reimplemented, because what a fresh copy needs is the
  # project's business and not ours. `code_my_spec` needs its `.code_my_spec`
  # submodule populated; the next project will need something else. A harness
  # that serves every project cannot know, and every time it guessed it guessed
  # for one of them.
  @recipe "init-worktree"

  @doc """
  Make a working copy beside `root` and give it an identity.

  Answers `{:ok, %{root:, working_copy_id:}}`, or `{:error, reason}` with
  nothing left behind that claims to be a working copy.
  """
  @spec run(String.t(), map()) ::
          {:ok, %{root: String.t(), working_copy_id: String.t()}} | {:error, term()}
  def run(root, request) when is_binary(root) and root != "" do
    name = slug(request["label"])

    # Adjacent to the checkout, not under `.claude/worktrees`. A working copy is
    # a peer of the checkout it came from, and putting real work inside a folder
    # people reasonably treat as disposable editor state invites losing it.
    #
    # Prefixed with the checkout's own name, because "adjacent" alone collides.
    # A parent directory holds many repositories — `~/Documents/github` here —
    # so a copy called `refactor` from one project takes the name for every
    # other, and for any unrelated directory that already has it. Caught by
    # story 1013's spex the first time this ran: six criteria each asked for
    # "the war epic's copy" beside their own temp root, the second one got
    # `{:already_exists, …}`, and `refuse_existing/1` was right to refuse.
    target = request["root"] || Path.join(Path.dirname(root), "#{Path.basename(root)}-#{name}")

    with :ok <- refuse_existing(target),
         {:ok, setup} <- add_worktree(root, target, name),
         {:ok, id} <- write_identity(target, request) do
      onboard(root, target, id, request)
      prepare_later(target, request["prepare"] == true)
      Logger.info("[CmsHarness] made a working copy at #{target}")
      {:ok, %{root: target, working_copy_id: id, setup: setup}}
    end
  end

  def run(_root, _request), do: {:error, :no_repository}

  @prepare_recipe "gate-setup"
  @preparing ".cms_harness_preparing"

  @doc """
  Whether the copy at `root` is still being prepared, or failed to be: it is
  not served until it is ready (`Projects.ensure_started/1`).
  """
  @spec preparing?(String.t()) :: boolean()
  def preparing?(root), do: File.exists?(Path.join(root, @preparing))

  # A copy that has to build and test before anything uses it — the promotion
  # gate — gets the project's `gate-setup` recipe (deps, secrets, a test
  # database: whatever the project needs), and is not served until it
  # succeeds. Its harness joining is what tells the queue it is ready.
  # In the background: it can take minutes, and the reply the server waits on
  # cannot.
  defp prepare_later(_target, false), do: :ok

  defp prepare_later(target, true) do
    File.write!(Path.join(target, @preparing), "preparing\n")
    {:ok, _pid} = Task.start(fn -> prepare(target) end)
    :ok
  end

  @doc """
  Run the project's `gate-setup` recipe in `target`, then mark it ready. A
  project without one has nothing to run. A recipe that fails leaves the copy
  marked, with the recipe's output in the marker, and unserved.
  """
  @spec prepare(String.t(), (String.t(), String.t() -> {String.t(), non_neg_integer()})) ::
          :ok | {:error, term()}
  def prepare(target, run \\ &just/2) do
    case run.(@prepare_recipe, target) do
      {_out, 0} ->
        ready(target)

      {out, status} ->
        if missing_recipe?(out) do
          Logger.warning(
            "[CmsHarness] #{target} declares no `#{@prepare_recipe}` recipe; serving it as made"
          )

          ready(target)
        else
          File.write!(Path.join(target, @preparing), out)

          Logger.error(
            "[CmsHarness] `just #{@prepare_recipe}` failed in #{target} (#{status}); not serving " <>
              "it until it is fixed and #{@preparing} removed:\n#{String.slice(out, -1500, 1500)}"
          )

          {:error, {:prepare_failed, status}}
        end
    end
  end

  # `just` not on this machine answers as a project with no recipe would.
  defp just(recipe, dir) do
    run_recipe([recipe], dir)
  rescue
    ErlangError -> {"error: Justfile does not contain recipe `#{recipe}`", 1}
  end

  defp ready(target) do
    File.rm(Path.join(target, @preparing))
    Logger.info("[CmsHarness] #{target} is prepared")
    :ok
  end

  # The other half of making a working copy.
  #
  # Without this the directory is servable and not buildable: a worktree with an
  # identity file, no `.claude/settings.local.json`, and therefore no recorded
  # test partition. `copy-11394` sat that way from 2026-09-05 until the coding
  # agent working in it needed to run spex and found it could not.
  #
  # What makes it worth doing here rather than leaving to whoever notices: an
  # un-onboarded copy does not fail where it is broken. `Validation`'s own notes
  # record the precedent — credo crashed before it ran, 104 times across two
  # checkouts, and what the agent saw was the *previous* run's findings marked
  # stale, on a file it had already fixed. Nothing it edited was ever measured.
  #
  # After `write_identity/2`, not instead of it. `onboard/2` merges into
  # `.cms_harness.json` rather than replacing it, and the fields story 891 cares
  # about — `project_id` and `working_copy_id` — are ours to write and not in
  # its shape. Writing ours first and letting the merge land on top keeps both.
  #
  # Failure does not fail the creation. The worktree exists, the identity is
  # written, and the remedy is one documented command — whereas refusing here
  # would leave a directory behind that the caller was told does not exist.
  defp onboard(root, target, id, request) do
    result =
      Onboarding.onboard(target,
        harness_id: id,
        app: app_name(root),
        deploy_key: request["deploy_key"],
        server_url: request["server_url"]
      )

    Logger.info("[CmsHarness] onboarded #{target} on partition #{result.partition}")
  end

  # The app the new copy builds, for the database names onboarding reports.
  #
  # Read from the parent's `mix.exs` because a worktree is the same application
  # as the checkout it came from. Falls back to the directory name, which is
  # what it usually is anyway — this names databases in a report, so a wrong
  # guess misinforms and nothing more.
  defp app_name(root) do
    with {:ok, mix} <- File.read(Path.join(root, "mix.exs")),
         [_, app] <- Regex.run(~r/app:\s*:([a-z_][a-z0-9_]*)/, mix) do
      app
    else
      _ -> Path.basename(root)
    end
  end

  # A directory that is already there is not ours to take. It may hold somebody's
  # work, and adopting it would give two copies one path.
  defp refuse_existing(target) do
    if File.exists?(target), do: {:error, {:already_exists, target}}, else: :ok
  end

  # `-b` so the copy gets its own branch. Two worktrees cannot check out the same
  # branch, and an epic's copy sharing one with the main checkout would mean every
  # commit on either appears on both — the opposite of the boundary the copy
  # exists to draw.
  # An error tuple, never a raise. `File.mkdir_p!/1` threw `File.Error` on a
  # read-only path and it travelled all the way out as an exception — so the
  # caller got a crash where it had asked a question, and the reply the agent
  # was waiting for never came. Somewhere it cannot write is an ordinary answer
  # here, not an exceptional one.
  # Answers `{:ok, setup}` where `setup` says how the copy was made, because a
  # copy made by the fallback is a different thing from one the project set up
  # and the caller has to be able to tell.
  #
  # It used to answer a bare `:ok` for both. `:no_recipe` then fell through to
  # `plain_worktree/3` mutely, and the copy was handed to agents with a worktree
  # and submodules and nothing else. On 2026-09-24 that cost a night on
  # metric_flow: no deps, so the compiler leg said "cannot satisfy its own
  # mix.lock" and prescribed a `mix deps.get` that fails in a fresh worktree on
  # shallow git deps; no `_build`, so `mix format` died on `Phoenix.CodeReloader`,
  # a Mix listener in the project's own mix.exs; no dotenv files, so a clean test
  # file read as five broken tests when its own guard clauses flunked. Two agents
  # filed those as framework defects and both were dismissed as environment.
  #
  # `cms_new` generates the recipe, so this only ever bites a brownfield project
  # — which is exactly the project nobody thinks to check.
  defp add_worktree(root, target, name) do
    with :ok <- make_parent(target) do
      case recipe(root, name, target) do
        :ok ->
          {:ok, :project_recipe}

        :no_recipe ->
          Logger.warning(
            "[CmsHarness] #{root} declares no `#{@recipe}` recipe, so #{target} got a " <>
              "worktree, its submodules, the source's deps/ and links to its dotenv files — " <>
              "no _build. Add `#{@recipe} name target` to its justfile."
          )

          with :ok <- plain_worktree(root, target, name), do: {:ok, :bare_worktree}

        {:error, _} = error ->
          error
      end
    end
  end

  # `just init-worktree <name> <target>`, when the project has one.
  #
  # A project that wants anything on a fresh copy — submodules populated, a
  # fixture linked, a file written — says so there, and we do not have to know
  # what it is. `cms_new` generates the recipe, so a project made by it has one
  # from the start.
  defp recipe(root, name, target) do
    case run_recipe([@recipe, name, target], root) do
      {_out, 0} ->
        :ok

      {out, status} ->
        if missing_recipe?(out),
          do: :no_recipe,
          else: {:error, {:worktree_failed, status, String.trim(out)}}
    end
  rescue
    # `just` is not on this machine. Not a failure — most projects do not use it.
    ErlangError -> :no_recipe
  end

  # A project's recipes choose their own Mix environment. Inheriting the
  # daemon's MIX_ENV=harness made Metric Flow import config/harness.exs and
  # left its promotion gate half-created. Use the same boundary as agent
  # commands, including removal of the daemon's CMS_* identity variables.
  defp run_recipe(args, root) do
    System.cmd("just", args,
      cd: root,
      stderr_to_stdout: true,
      env: Config.scrubbed_env()
    )
  end

  # Told apart from a recipe that ran and failed, because they deserve opposite
  # answers: the first falls back silently, the second is this project saying
  # its own copy cannot be made and must not be papered over.
  defp missing_recipe?(out) do
    out = String.downcase(out)

    String.contains?(out, "justfile does not contain recipe") or
      String.contains?(out, "no justfile found") or
      String.contains?(out, "could not find justfile")
  end

  # What every project gets when it says nothing: a worktree, and its submodules.
  #
  # Submodules by default because the alternative is silent and expensive.
  # `git worktree add` does not populate them, and the harness then scans a copy
  # whose `.code_my_spec` is empty and computes a requirement graph from what it
  # finds — which does not read as a missing checkout, it reads as a project
  # with no personas, no architecture and no specs, and the agent is told to redo
  # work that already exists. Worktree `963-main-agent-nontechnical` sat that way
  # with all 26 stories routed to it blocked behind one absent file, while every
  # surface reported a healthy idle agent (`fde40b27`).
  defp plain_worktree(root, target, name) do
    case System.cmd("git", ["worktree", "add", "-b", name, target],
           cd: root,
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        init_submodules(target)
        seed(root, target)

      {out, status} ->
        {:error, {:worktree_failed, status, String.trim(out)}}
    end
  end

  # Failure does not fail the creation, for the reason `onboard/4` gives: the
  # worktree exists and refusing here would leave a directory behind that the
  # caller was told does not exist. Logged loudly instead, because the one thing
  # this must never be is silent — that silence is the whole defect.
  defp init_submodules(target) do
    if File.exists?(Path.join(target, ".gitmodules")) do
      case System.cmd("git", ["submodule", "update", "--init", "--recursive"],
             cd: target,
             stderr_to_stdout: true
           ) do
        {_out, 0} ->
          Logger.info("[CmsHarness] populated submodules in #{target}")

        {out, status} ->
          Logger.error(
            "[CmsHarness] #{target} has submodules and they are not populated " <>
              "(git exited #{status}): #{String.trim(out)}. The requirement graph " <>
              "is computed from what is on disk, so this copy will read as a " <>
              "project with work never done. Run `git submodule update --init` in it."
          )
      end
    end

    :ok
  end

  @doc """
  Give a bare copy what `git worktree add` leaves behind: `deps/` and the
  untracked dotenv files, both taken from the checkout it came from.
  """
  @spec seed(Path.t(), Path.t()) :: :ok
  def seed(source, target) do
    copy_deps(source, target)
    link_dotenvs(source, target)
    :ok
  end

  # Copied, not fetched: `mix.lock` is the same, and `mix deps.get` in a fresh
  # worktree fails on shallow git deps whose pinned sha is not in the clone.
  # `cp -R` because `File.cp_r/2` took 47s on 474 MB where `cp` took 3.
  defp copy_deps(source, target) do
    from = Path.join(source, "deps")
    to = Path.join(target, "deps")

    if File.dir?(from) and not File.exists?(to) do
      case copy_tree(from, to) do
        :ok ->
          Logger.info("[CmsHarness] copied deps/ into #{target}")

        error ->
          Logger.error("[CmsHarness] could not copy deps/ into #{target}: #{inspect(error)}")
      end
    end
  end

  defp copy_tree(from, to) do
    case System.find_executable("cp") do
      nil ->
        with {:ok, _} <- File.cp_r(from, to), do: :ok

      cp ->
        case System.cmd(cp, ["-R", from, to], stderr_to_stdout: true) do
          {_out, 0} -> :ok
          {out, status} -> {:cp_failed, status, String.trim(out)}
        end
    end
  end

  # Linked, not copied, so secrets are not duplicated per copy — the call
  # `just worktree-setup` makes for `envs/`. Committed ones are already there.
  defp link_dotenvs(source, target) do
    for from <- Path.wildcard(Path.join(source, ".env*"), match_dot: true),
        File.regular?(from),
        to = Path.join(target, Path.basename(from)),
        not File.exists?(to) do
      case File.ln_s(from, to) do
        :ok -> :ok
        {:error, reason} -> Logger.error("[CmsHarness] could not link #{to}: #{inspect(reason)}")
      end
    end
  end

  defp make_parent(target) do
    case File.mkdir_p(Path.dirname(target)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cannot_write_there, Path.dirname(target), reason}}
    end
  end

  defp write_identity(target, request) do
    id = request["working_copy_id"] || Ecto.UUID.generate()

    body =
      %{
        "working_copy_id" => id,
        "harness_id" => id,
        "project_id" => request["project_id"],
        "root" => target
      }
      |> maybe_put("deploy_key", request["deploy_key"])
      |> maybe_put("server_url", request["server_url"])
      |> Jason.encode!(pretty: true)

    case File.write(Path.join(target, ".cms_harness.json"), body <> "\n") do
      :ok -> {:ok, id}
      {:error, reason} -> {:error, {:identity_not_written, reason}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # A directory name a person can read, from the label they gave. Falls back to
  # something unique rather than refusing — a copy with an awkward name is worth
  # more than no copy.
  defp slug(label) when is_binary(label) and label != "" do
    label
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> unique_name()
      slug -> String.slice(slug, 0, 40)
    end
  end

  defp slug(_label), do: unique_name()

  defp unique_name, do: "copy-#{System.unique_integer([:positive])}"
end
