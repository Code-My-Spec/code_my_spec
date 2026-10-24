defmodule CodeMySpec.AppInstances.Transport do
  @moduledoc "Routes app lifecycle requests through the harness that owns an instance's source checkout."
  require Logger
  alias CodeMySpec.Analysis.HarnessRegistry

  def request(instance, verb, timeout) when is_map(instance) do
    copy_id = Map.get(instance, :working_copy_id) || Map.get(instance, "working_copy_id")
    root = Map.get(instance, :source_root) || Map.get(instance, "source_root")

    if is_binary(copy_id) and is_binary(root) and root != "" do
      with {:ok, pid, _} <- HarnessRegistry.executor_holder(copy_id) do
        payload = %{instance: CodeMySpec.AppInstances.descriptor(instance)}

        try do
          GenServer.call(pid, {verb, payload}, timeout + CodeMySpec.AppInstances.call_grace_ms())
        catch
          :exit, {:timeout, _} -> {:error, timeout_reason(verb)}
          :exit, reason -> {:error, {:harness_gone, down_reason(reason)}}
        end
      else
        _ ->
          Logger.warning(
            "[AppInstances] cannot #{verb} instance #{instance_id(instance)}: harness not connected"
          )

          {:error, :harness_not_connected}
      end
    else
      {:error, :invalid_source}
    end
  end

  defp timeout_reason(:ensure_app_running), do: :start_timed_out
  defp timeout_reason(:restart_app), do: :restart_timed_out
  defp timeout_reason(:reload_app), do: :reload_timed_out
  defp timeout_reason(:discard_app), do: :discard_timed_out
  defp timeout_reason(:stop_app), do: :stop_timed_out
  defp down_reason(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp down_reason(reason), do: reason
  defp instance_id(instance), do: Map.get(instance, :id) || Map.get(instance, "id")
end
