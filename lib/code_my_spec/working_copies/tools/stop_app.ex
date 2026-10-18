defmodule CodeMySpec.WorkingCopies.Tools.StopApp do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.WorkingCopies.AppTransport

  @timeout to_timeout(second: 30)

  @impl true
  def name, do: "stop_app"

  @impl true
  def description do
    """
    Stop the caller's own copy of the app.

    See `EnsureAppRunning` — same "always the caller's own copy, never a
    parameter" reasoning applies here. A copy with nothing running answers
    success too, same as `AppTransport.stop_app/2` itself.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} -> stop(scope)
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp stop(%{active_working_copy_id: id}) when is_binary(id) do
    case AppTransport.stop_app(id, @timeout) do
      :ok -> {:ok, "Stopped."}
      {:error, reason} -> {:error, "Could not stop the app: #{inspect(reason)}"}
    end
  end

  defp stop(_scope) do
    {:error, "This call has no working copy of its own, so there is nothing here to stop."}
  end

  defp refusal(:missing_active_project) do
    "This call names no project, so there is no working copy to stop an app for."
  end

  defp refusal(reason), do: "This call has no usable project scope (#{inspect(reason)})."
end
