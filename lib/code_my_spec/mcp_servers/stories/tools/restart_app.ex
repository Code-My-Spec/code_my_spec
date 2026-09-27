defmodule CodeMySpec.McpServers.Stories.Tools.RestartApp do
  @moduledoc """
  Restart the caller's own copy of the app, on its current commit.

  See `EnsureAppRunning` — same "always the caller's own copy, never a
  parameter" reasoning applies here.
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
      {:ok, scope} -> {:reply, restart(scope), frame}
      {:error, reason} -> {:reply, Response.tool() |> Response.error(refusal(reason)), frame}
    end
  end

  defp restart(%{active_working_copy_id: id}) when is_binary(id) do
    case AppTransport.restart_app(id, @timeout) do
      {:ok, %{status: "serving", url: url, commit: commit}} ->
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
