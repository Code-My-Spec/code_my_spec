defmodule CodeMySpec.Promotion.Runner do
  @moduledoc """
  Where a promotion's three disk operations actually run.

  Two answers, chosen by the environment rather than configured:

    * `:local` — the checkout is on this machine, so `Steps` is called directly.
      That is the suite, and the case where the server and the disk are the same
      box.

    * `:harness` — the checkout is on someone else's machine. Each operation is
      sent down that harness's channel and answered there by the same `Steps`
      module against a local environment.

  The split exists because the gate cannot move and the commands cannot stay.
  `gate/1` and `gate_target/3` read the database; `git merge` and `just restart`
  need the disk. Sending the whole promotion to the harness would take the
  database away from the gate, and keeping it all on the server is what shipped
  and crashed — `Environments.Harness.cmd/4` answers
  `{:error, :not_supported_on_harness}`, deliberately.

  So the server orchestrates and the machine executes, which is the same shape
  analysis already has.
  """

  alias CodeMySpec.Analysis
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Promotion.Steps
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils

  # A restart compiles, migrates and waits for the app to answer. The analyzer
  # timeout is the closest precedent for "long work on the far machine" and this
  # is the same order of magnitude — `just restart` polls for 20s after a build
  # that can run minutes on a cold tree.
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

  @doc """
  Bring the application at `root` back up.

  `refresh_harness?` (default `true`) is passed straight through to
  `Steps.restart/3` — see its doc for why a caller would ever say `false`.
  """
  @spec restart(Scope.t(), String.t(), Ecto.UUID.t() | nil, boolean()) :: Steps.result()
  def restart(scope, root, copy_id, refresh_harness? \\ true),
    do:
      run(
        scope,
        copy_id,
        "promotion_restart",
        %{"root" => root, "refresh_harness" => refresh_harness?},
        @restart_timeout,
        fn env -> Steps.restart(env, root, refresh_harness?) end
      )

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
