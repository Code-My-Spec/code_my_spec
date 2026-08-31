defmodule CodeMySpecWeb.ProvisioningController do
  @moduledoc """
  Waiting for a provisioning run to converge, off the MCP/code-mode surface.

  `run_provisioning_step`/`run_devops_setup` both return the moment a run
  starts, not when it finishes — a real run against real infrastructure
  (`:deploy` alone measured ~167s) is far longer than either the MCP
  transport's own request cap or the code-mode sandbox's 30s wall clock, and
  those are the only two ways a caller reaching this through a script could
  otherwise learn "still going" from "done". `AnalysisController.wait/2`
  solved the identical problem for background analysis the same way: move
  the wait to a plain HTTP handler Bandit does not time out, and let the
  caller hold it open in the background instead of hammering a call with its
  own short ceiling.

  Deliberately not scoped to the harness the way `/analysis/wait` is — a
  provisioning run lives and runs entirely in this cloud app's own process,
  never on the caller's machine, so there is no harness id to route through.
  Auth is the same `X-Project-ID`-scoped OAuth token every other `/api` route
  and every MCP tool call already carries.
  """
  use CodeMySpecWeb, :controller

  require Logger

  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Provisioning

  # Long enough that reaching it means something is broken rather than slow.
  # `:server` provisioning two environments over real ssh round-trips ran
  # past a minute the first time it hit real infrastructure; ten minutes is
  # room for that to happen twice with something left over.
  @wait_timeout :timer.minutes(10)

  @doc """
  Block until this project's provisioning `RunLock` is free, then report it.

  Nothing caps this beyond `@wait_timeout`. The caller fires it in the
  background (`curl ... &`) and is notified when it returns, so one call
  covers a wait of any length a real run actually takes.
  """
  def wait(conn, _params) do
    scope = conn.assigns.current_scope

    case Validators.devops_project(scope) do
      {:ok, _project} ->
        Logger.info("[ProvisioningAPI] waiting for the run to finish")
        text(conn, wait_body(Provisioning.await_run(scope, timeout: @wait_timeout)))

      {:error, reason} ->
        conn |> put_status(422) |> text(reason)
    end
  end

  defp wait_body(:ok), do: "Provisioning run finished. Call devops_status for the result."

  defp wait_body(:timeout) do
    "Still running after #{div(@wait_timeout, 60_000)} minutes — not finished. " <>
      "Call devops_status to check state, or wait again."
  end
end
