defmodule CodeMySpec.McpServers.Stories.Tools.StopApp do
  @moduledoc """
  Stop the caller's own copy of the app.

  See `EnsureAppRunning` — same "always the caller's own copy, never a
  parameter" reasoning applies here. A copy with nothing running answers
  success too, same as `AppTransport.stop_app/2` itself.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.WorkingCopies.AppTransport

  @timeout to_timeout(second: 30)

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} -> {:reply, stop(scope), frame}
      {:error, reason} -> {:reply, Response.tool() |> Response.error(refusal(reason)), frame}
    end
  end

  defp stop(%{active_working_copy_id: id}) when is_binary(id) do
    case AppTransport.stop_app(id, @timeout) do
      :ok -> Response.tool() |> Response.text("Stopped.")
      {:error, reason} -> Response.tool() |> Response.error("Could not stop the app: #{inspect(reason)}")
    end
  end

  defp stop(_scope) do
    Response.tool()
    |> Response.error(
      "This call has no working copy of its own, so there is nothing here to stop."
    )
  end

  defp refusal(:no_working_dir) do
    "This call names no project, so there is no working copy to stop an app for."
  end

  defp refusal(reason), do: "This call has no usable project scope (#{inspect(reason)})."
end
