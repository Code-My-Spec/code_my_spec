defmodule CodeMySpec.Promotion.Runner do
  @moduledoc """
  Where a promotion's disk operations actually run.

  `precheck/3` and `merge/4` still split on the environment rather than being
  configured:

    * `:local` — the checkout is on this machine, so `Steps` is called directly.
      That is the suite, and the case where the server and the disk are the same
      box.

    * `:harness` — the checkout is on someone else's machine. Each operation is
      sent down that harness's channel and answered there by the same `Steps`
      module against a local environment.

  The split exists because the gate cannot move and the commands cannot stay.
  `gate/1` and `gate_target/3` read the database; `git merge` needs the disk.
  Sending the whole promotion to the harness would take the database away from
  the gate, and keeping it all on the server is what shipped and crashed —
  `Environments.Harness.cmd/4` answers `{:error, :not_supported_on_harness}`,
  deliberately.

  `restart/3` (story 1108, criterion 4663) no longer follows this split.
  Bringing an application back up is a per-working-copy concern every copy
  already has an answer for — `WorkingCopies.AppTransport.restart_app/2`,
  reached through `Analysis.HarnessRegistry` by working copy id rather than
  through `Environments` — so a promotion's restart is now the same call
  `ensure_app_running`/every other app-lifecycle caller already makes, not a
  second, promotion-only path to the same machine. What `just restart` used to
  also do on this repo's own checkout — refresh the harness afterward, since
  here server and harness are one codebase — is now `CmsHarness.AppInstance`'s
  own optional `after-promote` recipe, run on the far side once the app is
  confirmed serving, rather than a project-specific branch here that every
  other project's promotion would also have to answer for.
  """

  alias CodeMySpec.Analysis
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Promotion.Steps
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils
  alias CodeMySpec.WorkingCopies.AppTransport

  # `just restart` used to compile, migrate and wait for the app to answer in
  # one shelled-out call, and the analyzer timeout was the closest precedent
  # for "long work on the far machine". `AppTransport.restart_app/2` now
  # carries the same order of magnitude of work (the `serve` recipe it
  # triggers still fetches deps, migrates and waits for health) over the
  # channel instead of a shell, so the same ceiling applies.
  @restart_timeout 600_000
  @git_timeout 60_000

  @doc "What is on this checkout, and is it safe to move."
  @spec precheck(Scope.t(), String.t(), Ecto.UUID.t() | nil) :: Steps.result()
  def precheck(scope, root, copy_id),
    do:
      run(scope, copy_id, "promotion_precheck", %{"root" => root}, @git_timeout, fn env ->
        Steps.precheck(env, root)
      end)

  @doc "Merge `branch` into the checkout at `root`."
  @spec merge(Scope.t(), String.t(), String.t(), Ecto.UUID.t() | nil) :: Steps.result()
  def merge(scope, root, branch, copy_id),
    do:
      run(
        scope,
        copy_id,
        "promotion_merge",
        %{"root" => root, "branch" => branch},
        @git_timeout,
        fn env -> Steps.merge(env, root, branch) end
      )

  @doc "The checkout at `root`'s HEAD and current version, moving nothing."
  @spec current(Scope.t(), String.t(), Ecto.UUID.t() | nil) :: Steps.result()
  def current(scope, root, copy_id),
    do:
      run(scope, copy_id, "promotion_current", %{"root" => root}, @git_timeout, fn env ->
        Steps.current(env, root)
      end)

  @doc "Check out in `root`'s `.code_my_spec` the commit a merge pinned, fetched from `source`."
  @spec sync_submodule(Scope.t(), String.t(), String.t(), map(), Ecto.UUID.t() | nil) ::
          Steps.result()
  def sync_submodule(scope, root, source, merge, copy_id) do
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

    run(scope, copy_id, "promotion_submodule", payload, @git_timeout, fn env ->
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

  # `AppTransport.restart_app/2`'s own shape — `%{status:, url:, commit:}` on
  # success, one of a few atoms or `{:harness_gone, reason}` on failure —
  # translated into the `%{revision:}` / `%{reason:}` shape
  # `Promotion.classify_restart/1` (and `restart_acknowledgement_lost?/1`,
  # which that caller already consults) expect, so neither needs to know
  # this call stopped going through `Steps`.
  #
  # Worded per shape rather than a blanket `to_string/1`, on purpose:
  # `:harness_not_connected` — nothing was ever registered for this working
  # copy, so there was no channel to lose an acknowledgement from — is a
  # real failure and reads as one ("could not reach…", matching the wording
  # `Runner.decode/1` already uses for the same idea on `precheck`/`merge`).
  # `{:harness_gone, reason}` is the opposite: the channel died *answering*
  # this exact restart, which is what a restart that took its own connection
  # down while draining looks like from here — worded so
  # `restart_acknowledgement_lost?/1`'s "draining" check reads it as the
  # unconfirmed success it is, not a failure to retry.
  defp decode_app_result({:ok, %{status: "serving", commit: commit}}),
    do: {:ok, %{revision: commit}}

  defp decode_app_result({:ok, %{status: status, commit: commit}}) do
    {:error, %{reason: "the app answered #{status} after restarting" <> commit_suffix(commit)}}
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

  # The harness cannot be asked without knowing which working copy to ask, and
  # that is the id the channel is registered under — not the root, because two
  # checkouts of one project are two working copies and a path cannot tell them
  # apart.
  defp run(%Scope{environment: %Environment{type: :harness}}, nil, op, _payload, _timeout, _local) do
    {:error,
     %{
       reason:
         "cannot run #{op}: this project's checkout is on a machine reached over " <>
           "its harness, and no working copy id was given to address it."
     }}
  end

  defp run(
         %Scope{environment: %Environment{type: :harness}},
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

  defp run(%Scope{environment: nil}, _copy_id, op, _payload, _timeout, _local) do
    {:error, %{reason: "cannot run #{op}: there is no environment on this scope."}}
  end

  defp run(%Scope{environment: env}, _copy_id, _op, _payload, _timeout, local), do: local.(env)

  # The far side answers in JSON, so a map that left as atoms comes back with
  # string keys. Converted here rather than at each call site, because a caller
  # that has to remember which side answered is a caller that will forget.
  defp decode({:ok, %{} = result}), do: {:ok, atomize(result)}
  defp decode({:error, %{} = reason}), do: {:error, atomize(reason)}

  defp decode({:error, reason}),
    do:
      {:error, %{reason: "could not reach the machine holding this checkout: #{inspect(reason)}"}}

  defp decode(other),
    do: {:error, %{reason: "unexpected reply from the harness: #{inspect(other)}"}}

  defp atomize(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {Utils.safe_to_existing_atom(k, k), v}
      {k, v} -> {k, v}
    end)
  end
end
