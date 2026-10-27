defmodule CodeMySpec.Promotion.Runner do
  @moduledoc """
  Where a promotion's disk operations actually run.

  Disk operation APIs take an `ExecutionContext.t() | nil` directly. The copy ID is
  a separate transport address: it selects which harness receives a remote
  request and is never inferred from `ExecutionContext.ref`.

  Every disk operation splits on the environment:

    * a non-harness environment — the checkout is on this machine, so `Steps`
      is called directly (the suite, and a server on the same box as the disk);

    * `:harness` — each operation is sent down that copy's harness channel
      (`Analysis.harness_fs_request/4`) and answered there by `Steps`.

  The gate reads the database and `git` needs the disk, so the gate stays on
  the server and the steps travel.

  `restart/3` and `reload/3` do not split: they call
  `AppInstances.restart/3` / `reload/3` by working copy
  id, the same app lifecycle every copy uses. Project-specific follow-up (this
  repo refreshing its harness) is the far side's optional `after-promote`
  recipe, run by `CmsHarness.AppInstance`.
  """

  alias CodeMySpec.Analysis
  alias CodeMySpec.AppInstances
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Promotion.RemoteSteps
  alias CodeMySpec.Promotion.Steps
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils

  # A restart fetches deps, migrates and waits for health on the far side:
  # analyzer-scale work, so the analyzer-scale ceiling.
  @restart_timeout 600_000
  @git_timeout 60_000
  # Each drop boots `mix` in the test env, which compiles a candidate the gate
  # has not built yet; its analyzers reuse that build.
  @reset_timeout 600_000

  @doc "Remove a legacy gate worktree through its source device's harness."
  def retire_gate_worktree(environment, source_root, gate_root, source_copy_id) do
    run(
      environment,
      source_copy_id,
      "promotion_retire_gate",
      %{"root" => source_root, "gate_root" => gate_root},
      @git_timeout,
      fn env -> Steps.retire_gate_worktree(env, source_root, gate_root) end
    )
  end

  @doc "Fetch the authoritative origin branch on the addressed machine."
  def remote_head(environment, root, branch, copy_id),
    do:
      run(
        environment,
        copy_id,
        "promotion_remote_head",
        %{"root" => root, "branch" => branch},
        @git_timeout,
        fn env -> RemoteSteps.remote_head(env, root, branch) end
      )

  @doc "Reconcile a publication receipt without attempting a push."
  def publication_status(environment, root, branch, base, head, promotion_id, copy_id),
    do:
      publication_request(
        environment,
        copy_id,
        "promotion_publication_status",
        %{
          "root" => root,
          "branch" => branch,
          "base" => base,
          "head" => head,
          "promotion_id" => promotion_id
        },
        @git_timeout,
        fn env -> RemoteSteps.publication_status(env, root, branch, base, head, promotion_id) end
      )

  @doc "Atomically publish the certified candidate with an immutable promotion receipt."
  def publish(environment, root, branch, base, head, promotion_id, copy_id),
    do:
      publication_request(
        environment,
        copy_id,
        "promotion_publish",
        %{
          "root" => root,
          "branch" => branch,
          "base" => base,
          "head" => head,
          "promotion_id" => promotion_id
        },
        @git_timeout,
        fn env -> RemoteSteps.publish(env, root, branch, base, head, promotion_id) end
      )

  def remote_sync(environment, root, copy_id, branch, head),
    do: sync_remote(environment, root, branch, head, copy_id)

  @doc "Safely synchronize a clean destination checkout from origin."
  def sync_remote(environment, root, branch, head, copy_id),
    do:
      run(
        environment,
        copy_id,
        "promotion_sync_remote",
        %{"root" => root, "branch" => branch, "head" => head},
        @git_timeout,
        fn env -> RemoteSteps.sync_remote(env, root, branch, head) end
      )

  @doc """
  What is on this checkout, and is it safe to move. `main` is main's HEAD,
  which the checkout must contain (`Steps.precheck/3`).
  """
  @spec precheck(ExecutionContext.t() | nil, String.t(), Ecto.UUID.t() | nil, String.t() | nil) ::
          Steps.result()
  def precheck(environment, root, copy_id, main \\ nil) do
    payload = %{"root" => root, "main" => main}

    run(environment, copy_id, "promotion_precheck", payload, @git_timeout, fn env ->
      Steps.precheck(env, root, main)
    end)
  end

  @doc "Build a promotion batch in the gate checkout at `root` (`Steps.build_batch/4`)."
  @spec build_batch(
          ExecutionContext.t() | nil,
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
  @spec reset_test_databases(ExecutionContext.t() | nil, String.t(), Ecto.UUID.t() | nil) ::
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
  @spec build_assets(ExecutionContext.t() | nil, String.t(), Ecto.UUID.t() | nil) ::
          Steps.result()
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

  @doc """
  Format the checkout at `root` and commit the result, or with `check: true`
  only name the unformatted files (`Steps.format/3`).
  """
  @spec format(ExecutionContext.t() | nil, String.t(), Ecto.UUID.t() | nil, keyword()) ::
          Steps.result()
  def format(environment, root, copy_id, opts \\ []) do
    check = Keyword.get(opts, :check, false)

    run(
      environment,
      copy_id,
      "promotion_format",
      %{"root" => root, "check" => check},
      @reset_timeout,
      fn env -> Steps.format(env, root, check: check) end
    )
  end

  @doc "Which of `commits` `base` already contains (`Steps.contained/4`)."
  @spec contained(
          ExecutionContext.t() | nil,
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
  @spec merge(ExecutionContext.t() | nil, String.t(), String.t(), Ecto.UUID.t() | nil) ::
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
  @spec changed(
          ExecutionContext.t() | nil,
          String.t(),
          String.t(),
          String.t(),
          Ecto.UUID.t() | nil
        ) ::
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
  @spec current(ExecutionContext.t() | nil, String.t(), Ecto.UUID.t() | nil) :: Steps.result()
  def current(environment, root, copy_id),
    do:
      run(environment, copy_id, "promotion_current", %{"root" => root}, @git_timeout, fn env ->
        Steps.current(env, root)
      end)

  @doc "Check out in `root`'s `.code_my_spec` the commit a merge pinned, fetched from `source`."
  @spec sync_submodule(
          ExecutionContext.t() | nil,
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

  def restart(scope, _root, instance_id) do
    instance_id
    |> then(&AppInstances.restart(scope, &1, @restart_timeout))
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

  def reload(scope, _root, instance_id) do
    instance_id
    |> then(&AppInstances.reload(scope, &1, @restart_timeout))
    |> decode_app_result()
  end

  # `AppInstances`'s shapes translated to `%{revision:}` / `%{reason:}`. The
  # wording is load-bearing: `Promotion.restart_acknowledgement_lost?/1` reads
  # it. `:harness_not_connected` is a real failure ("could not reach…");
  # `{:harness_gone, _}` is a restart that took its own channel down, worded
  # with "draining" so it reads as unconfirmed success. The revision is what
  # the app serves (after a reload, not the launch commit).
  defp decode_app_result({:ok, info}) when is_map(info) do
    status = value(info, :status)
    revision = value(info, :serving_commit) || value(info, :commit)

    if status in ["serving", :serving] do
      {:ok,
       %{
         revision: revision,
         action: value(info, :action),
         action_reason: value(info, :action_reason)
       }}
    else
      {:error,
       %{
         reason:
           "the app answered #{status} after #{value(info, :action) || "restarting"}" <>
             commit_suffix(revision)
       }}
    end
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

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp commit_suffix(nil), do: ""
  defp commit_suffix(commit), do: ", now on #{commit}"

  # A lost publication response is not a rejected publication. Keep the
  # certified batch until its immutable origin receipt can be inspected.
  defp publication_request(environment, copy_id, op, payload, timeout, local) do
    case run(environment, copy_id, op, payload, timeout, local) do
      {:error, %{status: _}} = refusal -> refusal
      {:error, reason} -> {:error, Map.merge(reason, %{retryable: true, uncertain: true})}
      result -> result
    end
  end

  # The harness is addressed by working copy id, never by root: two checkouts
  # of one project are two copies.
  defp run(%ExecutionContext{type: :harness}, nil, op, _payload, _timeout, _local) do
    {:error,
     %{
       reason:
         "cannot run #{op}: this project's checkout is on a machine reached over " <>
           "its harness, and no working copy id was given to address it."
     }}
  end

  defp run(
         %ExecutionContext{type: :harness},
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

  defp run(%ExecutionContext{} = env, _copy_id, _op, _payload, _timeout, local), do: local.(env)

  # The far side answers in JSON, so keys come back as strings. Atomized here,
  # nested too, so no caller has to know which side answered.
  @doc false
  def decode({:ok, %{} = result}), do: {:ok, atomize(result)}
  def decode({:error, %{} = reason}), do: {:error, atomize(reason)}

  # Unreachable is marked, not only worded: a harness restarting after a
  # landing, or its channel down for a code reload, is a passing state a caller
  # can wait out, not a fault of the work.
  def decode({:error, {gone, _} = reason})
      when gone in [:harness_not_registered, :harness_gone, :harness_registry_down],
      do:
        {:error,
         %{
           reason: "could not reach the machine holding this checkout: #{inspect(reason)}",
           unreachable: true
         }}

  def decode({:error, reason}),
    do:
      {:error, %{reason: "could not reach the machine holding this checkout: #{inspect(reason)}"}}

  def decode(other),
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
