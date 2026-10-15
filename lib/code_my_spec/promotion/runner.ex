defmodule CodeMySpec.Promotion.Runner do
  @moduledoc """
  Where a promotion's disk operations actually run.

  Disk operation APIs take an `Environment.t() | nil` directly. The copy ID is
  a separate transport address: it selects which harness receives a remote
  request and is never inferred from `Environment.ref`.

  Every disk operation splits on the environment:

    * a non-harness environment — the checkout is on this machine, so `Steps`
      is called directly (the suite, and a server on the same box as the disk);

    * `:harness` — each operation is sent down that copy's harness channel
      (`Analysis.harness_fs_request/4`) and answered there by `Steps`.

  The gate reads the database and `git` needs the disk, so the gate stays on
  the server and the steps travel.

  `restart/3` and `reload/3` do not split: they call
  `WorkingCopies.AppTransport.restart_app/2` / `reload_app/2` by working copy
  id, the same app lifecycle every copy uses. Project-specific follow-up (this
  repo refreshing its harness) is the far side's optional `after-promote`
  recipe, run by `CmsHarness.AppInstance`.
  """

  alias CodeMySpec.Analysis
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Promotion.Steps
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils
  alias CodeMySpec.WorkingCopies.AppTransport

  # A restart fetches deps, migrates and waits for health on the far side:
  # analyzer-scale work, so the analyzer-scale ceiling.
  @restart_timeout 600_000
  @git_timeout 60_000
  # Each drop boots `mix` in the test env, which compiles a candidate the gate
  # has not built yet; its analyzers reuse that build.
  @reset_timeout 600_000

  @doc """
  What is on this checkout, and is it safe to move. `main` is main's HEAD,
  which the checkout must contain (`Steps.precheck/3`).
  """
  @spec precheck(Environment.t() | nil, String.t(), Ecto.UUID.t() | nil, String.t() | nil) ::
          Steps.result()
  def precheck(environment, root, copy_id, main \\ nil) do
    payload = %{"root" => root, "main" => main}

    run(environment, copy_id, "promotion_precheck", payload, @git_timeout, fn env ->
      Steps.precheck(env, root, main)
    end)
  end

  @doc "Build a promotion batch in the gate checkout at `root` (`Steps.build_batch/4`)."
  @spec build_batch(
          Environment.t() | nil,
          String.t(),
          String.t(),
          [String.t()],
          Ecto.UUID.t() | nil
        ) :: Steps.result()
  def build_batch(environment, root, base, commits, copy_id),
    do:
      run(
        environment,
        copy_id,
        "promotion_build_batch",
        %{"root" => root, "base" => base, "commits" => commits},
        @git_timeout,
        fn env -> Steps.build_batch(env, root, base, commits) end
      )

  @doc """
  Drop the gate copy's test databases (`Steps.reset_test_databases/3`). The
  harness holding the copy names them; a local environment has none of the
  harness's partitions and drops nothing.
  """
  @spec reset_test_databases(Environment.t() | nil, String.t(), Ecto.UUID.t() | nil) ::
          Steps.result()
  def reset_test_databases(environment, root, copy_id),
    do:
      run(
        environment,
        copy_id,
        "promotion_reset_test_databases",
        %{"root" => root},
        @reset_timeout,
        fn env -> Steps.reset_test_databases(env, root, []) end
      )

  @doc "Build the project's static assets in the gate checkout (`Steps.build_assets/2`)."
  @spec build_assets(Environment.t() | nil, String.t(), Ecto.UUID.t() | nil) :: Steps.result()
  def build_assets(environment, root, copy_id),
    do:
      run(
        environment,
        copy_id,
        "promotion_build_assets",
        %{"root" => root},
        @reset_timeout,
        fn env -> Steps.build_assets(env, root) end
      )

  @doc "Which of `commits` `base` already contains (`Steps.contained/4`)."
  @spec contained(
          Environment.t() | nil,
          String.t(),
          String.t(),
          [String.t()],
          Ecto.UUID.t() | nil
        ) :: Steps.result()
  def contained(environment, root, base, commits, copy_id),
    do:
      run(
        environment,
        copy_id,
        "promotion_contained",
        %{"root" => root, "base" => base, "commits" => commits},
        @git_timeout,
        fn env -> Steps.contained(env, root, base, commits) end
      )

  @doc "Merge `branch` into the checkout at `root`."
  @spec merge(Environment.t() | nil, String.t(), String.t(), Ecto.UUID.t() | nil) ::
          Steps.result()
  def merge(environment, root, branch, copy_id),
    do:
      run(
        environment,
        copy_id,
        "promotion_merge",
        %{"root" => root, "branch" => branch},
        @git_timeout,
        fn env -> Steps.merge(env, root, branch) end
      )

  @doc "The paths that differ between `from` and `to` at `root` (`Steps.changed/4`)."
  @spec changed(Environment.t() | nil, String.t(), String.t(), String.t(), Ecto.UUID.t() | nil) ::
          Steps.result()
  def changed(environment, root, from, to, copy_id),
    do:
      run(
        environment,
        copy_id,
        "promotion_changed",
        %{"root" => root, "from" => from, "to" => to},
        @git_timeout,
        fn env -> Steps.changed(env, root, from, to) end
      )

  @doc "The checkout at `root`'s HEAD and current version, moving nothing."
  @spec current(Environment.t() | nil, String.t(), Ecto.UUID.t() | nil) :: Steps.result()
  def current(environment, root, copy_id),
    do:
      run(environment, copy_id, "promotion_current", %{"root" => root}, @git_timeout, fn env ->
        Steps.current(env, root)
      end)

  @doc "Check out in `root`'s `.code_my_spec` the commit a merge pinned, fetched from `source`."
  @spec sync_submodule(
          Environment.t() | nil,
          String.t(),
          String.t(),
          map(),
          Ecto.UUID.t() | nil
        ) :: Steps.result()
  def sync_submodule(environment, root, source, merge, copy_id) do
    moved = %{
      before: Map.get(merge, :before),
      after: Map.get(merge, :after),
      version: Map.get(merge, :version)
    }

    payload = %{
      "root" => root,
      "source" => source,
      "before" => moved.before,
      "after" => moved.after,
      "version" => moved.version
    }

    run(environment, copy_id, "promotion_submodule", payload, @git_timeout, fn env ->
      Steps.sync_submodule(env, root, source, moved)
    end)
  end

  @doc """
  Bring the application at `root` back up — through the same start/restart
  every working copy's own app already uses, harness included.

  No working copy id to address means nothing to restart: refused rather
  than guessed at, the same as `precheck/3` and `merge/4` refuse when a
  harness environment is given none.
  """
  @spec restart(Scope.t(), String.t(), Ecto.UUID.t() | nil) :: Steps.result()
  def restart(_scope, root, nil) do
    {:error,
     %{reason: "cannot restart #{root}: no working copy id was given to address its app with."}}
  end

  def restart(_scope, _root, copy_id) do
    copy_id
    |> AppTransport.restart_app(@restart_timeout)
    |> decode_app_result()
  end

  @doc """
  Reload the application at `root` in place — migrate, let its code reloader
  compile, health-check — through the same per-copy channel `restart/3` uses.

  `{:ok, %{revision:, action:, action_reason:}}`: `action` is `"reloaded"`, or
  `"restarted"` when the far side restarted instead (app not running, no
  `reload` recipe). Any error means the app was not reloaded, and the caller
  restarts it.
  """
  @spec reload(Scope.t(), String.t(), Ecto.UUID.t() | nil) :: Steps.result()
  def reload(_scope, root, nil) do
    {:error,
     %{reason: "cannot reload #{root}: no working copy id was given to address its app with."}}
  end

  def reload(_scope, _root, copy_id) do
    copy_id
    |> AppTransport.reload_app(@restart_timeout)
    |> decode_app_result()
  end

  # `AppTransport`'s shapes translated to `%{revision:}` / `%{reason:}`. The
  # wording is load-bearing: `Promotion.restart_acknowledgement_lost?/1` reads
  # it. `:harness_not_connected` is a real failure ("could not reach…");
  # `{:harness_gone, _}` is a restart that took its own channel down, worded
  # with "draining" so it reads as unconfirmed success. The revision is what
  # the app serves (after a reload, not the launch commit).
  defp decode_app_result({:ok, %{status: "serving"} = info}) do
    {:ok,
     %{
       revision: Map.get(info, :serving_commit) || Map.get(info, :commit),
       action: Map.get(info, :action),
       action_reason: Map.get(info, :action_reason)
     }}
  end

  defp decode_app_result({:ok, %{status: status} = info}) do
    {:error,
     %{
       reason:
         "the app answered #{status} after #{Map.get(info, :action) || "restarting"}" <>
           commit_suffix(Map.get(info, :serving_commit) || Map.get(info, :commit))
     }}
  end

  defp decode_app_result({:error, :reload_not_supported}) do
    {:error, %{reason: "the harness serving this checkout predates reload_app"}}
  end

  defp decode_app_result({:error, :reload_timed_out}) do
    {:error, %{reason: "the harness accepted the reload and did not answer within the timeout"}}
  end

  defp decode_app_result({:error, :harness_not_connected}) do
    {:error,
     %{reason: "could not reach the machine holding this checkout: its harness is not connected"}}
  end

  defp decode_app_result({:error, :restart_timed_out}) do
    {:error, %{reason: "the harness accepted the restart and did not answer within the timeout"}}
  end

  defp decode_app_result({:error, {:harness_gone, down}}) do
    {:error,
     %{
       reason:
         "the channel went down (#{inspect(down)}) before answering — if this restart just " <>
           "took its own connection down, draining as it went, that is what success looks " <>
           "like from here, not a failure"
     }}
  end

  defp decode_app_result({:error, reason}), do: {:error, %{reason: inspect(reason)}}

  defp commit_suffix(nil), do: ""
  defp commit_suffix(commit), do: ", now on #{commit}"

  # The harness is addressed by working copy id, never by root: two checkouts
  # of one project are two copies.
  defp run(%Environment{type: :harness}, nil, op, _payload, _timeout, _local) do
    {:error,
     %{
       reason:
         "cannot run #{op}: this project's checkout is on a machine reached over " <>
           "its harness, and no working copy id was given to address it."
     }}
  end

  defp run(
         %Environment{type: :harness},
         copy_id,
         op,
         payload,
         timeout,
         _local
       ) do
    copy_id
    |> Analysis.harness_fs_request(op, payload, timeout)
    |> decode()
  end

  defp run(nil, _copy_id, op, _payload, _timeout, _local),
    do: {:error, %{reason: "cannot run #{op}: there is no environment."}}

  defp run(%Environment{} = env, _copy_id, _op, _payload, _timeout, local), do: local.(env)

  # The far side answers in JSON, so keys come back as strings. Atomized here,
  # nested too, so no caller has to know which side answered.
  defp decode({:ok, %{} = result}), do: {:ok, atomize(result)}
  defp decode({:error, %{} = reason}), do: {:error, atomize(reason)}

  # Unreachable is marked, not only worded: a harness restarting after a
  # landing is a passing state a caller can wait out, not a fault of the work.
  defp decode({:error, {:harness_not_registered, _} = reason}),
    do:
      {:error,
       %{
         reason: "could not reach the machine holding this checkout: #{inspect(reason)}",
         unreachable: true
       }}

  defp decode({:error, reason}),
    do:
      {:error, %{reason: "could not reach the machine holding this checkout: #{inspect(reason)}"}}

  defp decode(other),
    do: {:error, %{reason: "unexpected reply from the harness: #{inspect(other)}"}}

  defp atomize(%{} = map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {Utils.safe_to_existing_atom(k, k), atomize(v)}
      {k, v} -> {k, atomize(v)}
    end)
  end

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value
end
