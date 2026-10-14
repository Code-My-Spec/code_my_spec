defmodule CmsHarness.WorkingCopies.Create do
  @moduledoc """
  Making a checkout on this machine, because this is the machine with the disk.

  The server owns the record and cannot reach this filesystem, so the disk half
  happens here and the record half there. Separate from
  `CmsHarness.WorkingCopies`, which is a lookup; this is an act.

  A worktree, not a clone: it shares the object store (seconds, not minutes)
  and keeps copies on one filesystem, keyed on `(device_id, root)`. The id
  arrives with the request and is written into `.cms_harness.json` here, so the
  server's record and the disk hold the same value.
  See knowledge/harness, "Creating working copies".
  """

  require Logger

  alias ClientUtils.Harness.Onboarding
  alias CmsHarness.Config

  # The project's own recipe for making a copy of itself: what a fresh copy
  # needs is the project's business.
  @recipe "init-worktree"

  @doc """
  Make a working copy beside `root` and give it an identity.

  Answers `{:ok, %{root:, working_copy_id:, setup:}}` (`setup` is
  `:project_recipe` or `:bare_worktree`), or `{:error, reason}` with nothing
  left behind that claims to be a working copy.
  """
  @spec run(String.t(), map()) ::
          {:ok, %{root: String.t(), working_copy_id: String.t()}} | {:error, term()}
  def run(root, request) when is_binary(root) and root != "" do
    name = slug(request["label"])

    # Beside the checkout (not under disposable `.claude/worktrees`), prefixed
    # with its name so siblings from other repositories do not collide.
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

  # A copy that must build and test before use (the promotion gate) runs the
  # project's `gate-setup` recipe in the background and is not served until it
  # succeeds; its join tells the queue it is ready.
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

  # Onboarding records the test partition; without it the copy is servable but
  # every analyzer run fails. After `write_identity/2`, whose fields the merge
  # keeps. Never fails the creation: the remedy is one documented command.
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

  # The app name from the parent's `mix.exs`, else the directory name; it only
  # names databases in onboarding's report.
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

  # Answers `{:ok, setup}` so the caller can tell a fallback bare worktree
  # from a project-recipe copy; the fallback is logged. Errors are tuples, never
  # raises: an unwritable path is an ordinary answer.
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
  # `cms_new` generates the recipe.
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

  # With the daemon's `MIX_ENV` and `CMS_*` variables removed: a project's
  # recipes choose their own environment.
  defp run_recipe(args, root) do
    System.cmd("just", args,
      cd: root,
      stderr_to_stdout: true,
      env: Config.scrubbed_env()
    )
  end

  # A missing recipe falls back; a recipe that ran and failed is an error.
  defp missing_recipe?(out) do
    out = String.downcase(out)

    String.contains?(out, "justfile does not contain recipe") or
      String.contains?(out, "no justfile found") or
      String.contains?(out, "could not find justfile")
  end

  # The fallback: a worktree on its own branch (`-b`), its submodules (an
  # empty `.code_my_spec` reads as a project with no work done), and `seed/2`.
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

  # Never fails the creation (as for `onboard/4`), but logged loudly.
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

  # Linked, not copied, so secrets are not duplicated per copy.
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

  # A readable directory name from the label, else a unique one.
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
