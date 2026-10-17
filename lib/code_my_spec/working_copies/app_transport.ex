defmodule CodeMySpec.WorkingCopies.AppTransport do
  @moduledoc """
  Asks a working copy's channel to start, restart or stop its own app.

  Story 1108: every working copy runs its own instance of the app, on its own
  port and database, so QA can test a story's branch before it is promoted.
  This is the seam that carries "start/restart/stop" from the server to the
  machine holding the checkout.

  Same mechanism as `CodeMySpec.Agents.Transport.Harness`: `Analysis.
  HarnessRegistry` holds a live process per connected copy — the channel
  itself — and the request goes to that pid, because it is the same process
  that already proved the machine is reachable. See that module's own
  history before changing this one: a lookup through a registry module that
  does not exist raised on every call and a `rescue` silently turned every
  failure into "not connected," which no test caught because every spex
  swaps this for an in-process transport.
  """

  require Logger

  alias CodeMySpec.Analysis.HarnessRegistry

  @doc """
  Ask the copy's machine to bring its app up, starting it if it is not
  already running and reporting its current state either way.
  """
  @spec ensure_app_running(String.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def ensure_app_running(working_copy_id, timeout) do
    dispatch(working_copy_id, :ensure_app_running, %{}, timeout, :start_timed_out)
  end

  @doc "Require the app's served revision to match its checkout before QA uses it."
  @spec qa_revision_check(map()) :: :ok | {:error, String.t()}
  def qa_revision_check(info) do
    serving = Map.get(info, :serving_commit) || Map.get(info, :commit)
    head = Map.get(info, :head)

    if is_binary(serving) and serving != "" and serving == head do
      :ok
    else
      {:error,
       "Do not test against this app yet. Served revision: #{serving || "unknown"}; " <>
         "checkout HEAD: #{head || "unknown"}. QA requires matching revisions. " <>
         "Use restart_app for this copy, then call ensure_app_running to verify the revision " <>
         "before testing. Do not start another restart while one is running."}
    end
  end

  @doc "Ask the copy's machine to restart its app — HEAD moved, or a promote."
  @spec restart_app(String.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def restart_app(working_copy_id, timeout) do
    dispatch(working_copy_id, :restart_app, %{}, timeout, :restart_timed_out)
  end

  @doc """
  Ask the copy's machine to reload its running app in place — a promote's
  default. Migrates, lets the app's code reloader compile, health-checks, then
  runs the after-promote hook as a restart does. The far side restarts
  instead when the app is not running or the project has no `reload` recipe,
  and says so in `action`/`action_reason`.
  """
  @spec reload_app(String.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def reload_app(working_copy_id, timeout) do
    dispatch(working_copy_id, :reload_app, %{}, timeout, :reload_timed_out)
  end

  @doc "Whether the copy's connected harness answers `reload_app`."
  @spec reload_supported?(String.t()) :: boolean()
  def reload_supported?(working_copy_id),
    do: HarnessRegistry.supports?(working_copy_id, "reload_app")

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
    case HarnessRegistry.executor_holder(working_copy_id) do
      {:ok, pid, _instance} -> {:ok, pid}
      :error -> :none
    end
  end

  # A callee that dies is not a callee that hung, and the two want opposite
  # readings — `Analysis.harness_fs_request/4` already tells them apart for
  # the same reason (see `FsRequestChannelDeathTest`'s own moduledoc): a
  # `restart_app` call whose target is the very app about to go down for the
  # restart it was just asked to run exits with the app's own shutdown
  # reason, not `:timeout`, seconds before the timeout could ever fire.
  # Folding both into one atom would make `Promotion.restart_acknowledgement_lost?/1`
  # unable to tell "it hung" from "it worked and took the channel down with
  # it" — the one distinction that call exists to make.
  defp call(pid, message, timeout, timeout_reason) do
    GenServer.call(pid, message, timeout + call_grace_ms())
  catch
    :exit, {:timeout, _} -> {:error, timeout_reason}
    :exit, reason -> {:error, {:harness_gone, down_reason(reason)}}
  end

  defp down_reason(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp down_reason(reason), do: reason

  # Same floor as `Agents.Transport.Harness.call/4` — "the machine is there
  # and did not finish" has to be distinguished from "no harness."
  #
  # Public: a caller deriving its own timeout from a wall-clock budget (an
  # MCP tool run under `Sandbox`, say) must subtract this too, not just its
  # own margin — `call/4` adds it on top of whatever timeout it is given,
  # so a caller's margin smaller than this grace lets the actual
  # `GenServer.call` deadline land past the caller's own deadline.
  @spec call_grace_ms() :: pos_integer()
  def call_grace_ms, do: Application.get_env(:code_my_spec, :call_grace_ms, 5_000)

  @doc """
  How long a first start's inline window lasts before the harness gives up
  waiting and replies `"starting"` instead of blocking further.

  Mirrors `CmsHarness.AppInstance`'s own private calculation by reading the
  same two config keys directly, rather than calling that module -- Boundary
  forbids `CmsHarness` references from most of `CodeMySpec`, including every
  caller of `ensure_app_running/2` that wants to derive "just above this
  window" instead of guessing a constant (cf006764). The keys are the only
  coupling; as long as both sides read the same two, they cannot drift.
  """
  @spec first_start_inline_window_ms() :: pos_integer()
  def first_start_inline_window_ms do
    Application.get_env(:code_my_spec, :app_instance_first_start_probe_attempts, 30) *
      Application.get_env(:code_my_spec, :app_instance_health_wait_interval_ms, 1_000)
  end

  defp unreachable(working_copy_id, verb) do
    Logger.warning(
      "[WorkingCopies] cannot #{verb} the app on working copy #{working_copy_id}: " <>
        "nothing registered for it. That machine is not reachable from this " <>
        "server, so nothing was asked of it."
    )

    {:error, :harness_not_connected}
  end
end
