defmodule CodeMySpec.McpServers.Stories.Tools.EnsureAppRunning do
  @moduledoc """
  Bring up the caller's own copy of the app, starting it if it isn't already
  running.

  Story 1108's rule: an agent on a copy can start, restart and stop its own
  copy's app. Always the caller's own copy — resolved from the connection's
  scope, never a parameter a caller could point at a different one. That is
  what makes "an agent cannot reach another copy's app" structural rather
  than a check that could be bypassed: there is nothing on this schema to
  name another copy with.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.WorkingCopies.AppTransport

  @timeout to_timeout(minute: 3)

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} -> {:reply, ensure_running(scope), frame}
      {:error, reason} -> {:reply, Response.tool() |> Response.error(refusal(reason)), frame}
    end
  end

  defp ensure_running(%{active_working_copy_id: id}) when is_binary(id) do
    case AppTransport.ensure_app_running(id, @timeout) do
      {:ok, %{status: "serving", url: url, commit: commit}} ->
        Response.tool() |> Response.text("Serving #{commit || "unknown commit"} at #{url}.")

      {:ok, %{status: status, commit: commit}} ->
        Response.tool()
        |> Response.error("The app is #{status} (commit #{commit || "unknown"}). Not serving.")

      {:error, reason} ->
        Response.tool() |> Response.error("Could not start the app: #{inspect(reason)}")
    end
  end

  defp ensure_running(_scope) do
    Response.tool()
    |> Response.error(
      "This call has no working copy of its own, so there is nothing here to start."
    )
  end

  defp refusal(:no_working_dir) do
    "This call names no project, so there is no working copy to start an app for."
  end

  defp refusal(reason), do: "This call has no usable project scope (#{inspect(reason)})."
end
