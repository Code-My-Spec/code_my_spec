defmodule CodeMySpec.WorkingCopies.AppTransport do
  @moduledoc """
  Asks a working copy's channel to start, restart or stop its own app.

  Story 1108: every working copy runs its own instance of the app, on its own
  port and database, so QA can test a story's branch before it is promoted.
  This is the seam that carries "start/restart/stop" from the server to the
  machine holding the checkout.

  Same mechanism as `CodeMySpec.Agents.Transport.Harness`: `Analysis` holds a
  live process per connected copy — the channel itself — and the request goes
  to that pid, because it is the same process that already proved the machine
  is reachable. See that module's own history before changing this one: a
  lookup through a registry module that does not exist raised on every call
  and a `rescue` silently turned every failure into "not connected," which no
  test caught because every spex swaps this for an in-process transport.
  """

  require Logger

  alias CodeMySpec.Analysis

  @doc """
  Ask the copy's machine to bring its app up, starting it if it is not
  already running and reporting its current state either way.
  """
  @spec ensure_app_running(String.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def ensure_app_running(working_copy_id, timeout) do
    dispatch(working_copy_id, :ensure_app_running, %{}, timeout, :start_timed_out)
  end

  @doc "Ask the copy's machine to restart its app — HEAD moved, or a promote."
  @spec restart_app(String.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def restart_app(working_copy_id, timeout) do
    dispatch(working_copy_id, :restart_app, %{}, timeout, :restart_timed_out)
  end

  @doc "Ask the copy's machine to stop its app — idle, or offboarding."
  @spec stop_app(String.t(), timeout()) :: :ok | {:error, term()}
  def stop_app(working_copy_id, timeout) do
    dispatch(working_copy_id, :stop_app, %{}, timeout, :stop_timed_out)
  end

  defp dispatch(working_copy_id, verb, request, timeout, timeout_reason) do
    case holder(working_copy_id) do
      {:ok, pid} -> call(pid, {verb, request}, timeout, timeout_reason)
      :none -> unreachable(working_copy_id, verb)
    end
  end

  defp holder(working_copy_id) do
    case Analysis.executor_holder(working_copy_id) do
      {:ok, pid, _instance} -> {:ok, pid}
      :error -> :none
    end
  end

  defp call(pid, message, timeout, timeout_reason) do
    GenServer.call(pid, message, timeout + call_grace_ms())
  catch
    :exit, {:timeout, _} -> {:error, timeout_reason}
  end

  # Same floor as `Agents.Transport.Harness.call/4` — "the machine is there
  # and did not finish" has to be distinguished from "no harness."
  defp call_grace_ms, do: Application.get_env(:code_my_spec, :call_grace_ms, 5_000)

  defp unreachable(working_copy_id, verb) do
    Logger.warning(
      "[WorkingCopies] cannot #{verb} the app on working copy #{working_copy_id}: " <>
        "nothing registered for it. That machine is not reachable from this " <>
        "server, so nothing was asked of it."
    )

    {:error, :harness_not_connected}
  end
end
