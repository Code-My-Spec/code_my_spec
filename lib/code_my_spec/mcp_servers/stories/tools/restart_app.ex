defmodule CodeMySpec.McpServers.Stories.Tools.RestartApp do
  @moduledoc """
  Restart the caller's own copy of the app, on its current commit.

  See `EnsureAppRunning` — same "always the caller's own copy, never a
  parameter" reasoning applies here.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.CodeMode.Sandbox
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.WorkingCopies.AppTransport

  # A restart waits for a compile and a boot, which is why this was once three
  # minutes. But a script calling this tool runs under `Sandbox`'s wall clock
  # and is handed that budget less `@machine_call_margin_ms` — so a three-minute
  # wait outlasted its caller six times over, the sandbox killed the script, and
  # `AppTransport`'s `{:error, :restart_timed_out}` never reached the caller
  # (0b1ae6fc: the restart had in fact completed, and no one could tell).
  #
  # Derived from the sandbox rather than declared, so the number the tool waits
  # on always fits inside the script that calls it. A restart that genuinely
  # needs longer than the sandbox still cannot complete in-script; this makes
  # the tool *report* that instead of vanishing. Returning on acceptance and
  # reporting the outcome separately, the way `promote` and `start_analysis`
  # do, is the follow-up.
  @machine_call_margin_ms 2_000

  @doc "How long this tool waits — never longer than the script that calls it."
  @spec declared_timeout() :: pos_integer()
  def declared_timeout do
    max(Sandbox.timeout([]) - @machine_call_margin_ms, 1_000)
  end

  defp timeout, do: declared_timeout()

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} -> {:reply, restart(scope), frame}
      {:error, reason} -> {:reply, Response.tool() |> Response.error(refusal(reason)), frame}
    end
  end

  defp restart(%{active_working_copy_id: id} = scope) when is_binary(id) do
    case AppTransport.restart_app(id, timeout()) do
      {:ok, %{status: "serving", url: url, commit: commit}} ->
        Agents.record_app_restart(scope, "Restarted via RestartApp")
        Response.tool() |> Response.text("Restarted — serving #{commit || "unknown commit"} at #{url}.")

      {:ok, %{status: status, commit: commit}} ->
        Response.tool()
        |> Response.error("The app is #{status} (commit #{commit || "unknown"}) after restart. Not serving.")

      {:error, reason} ->
        Response.tool() |> Response.error("Could not restart the app: #{inspect(reason)}")
    end
  end

  defp restart(_scope) do
    Response.tool()
    |> Response.error(
      "This call has no working copy of its own, so there is nothing here to restart."
    )
  end

  defp refusal(:no_working_dir) do
    "This call names no project, so there is no working copy to restart an app for."
  end

  defp refusal(reason), do: "This call has no usable project scope (#{inspect(reason)})."
end
