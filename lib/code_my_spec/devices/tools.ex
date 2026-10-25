defmodule CodeMySpec.Devices.Tools do
  @moduledoc "Agent discovery of account machines and their current-project checkouts."
  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Devices,
      CodeMySpec.WorkingCopies,
      CodeMySpec.Analysis.HarnessRegistry,
      CodeMySpec.Tools
    ]

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Devices.Device
  alias CodeMySpec.WorkingCopies

  def all, do: [__MODULE__.ListDevices, __MODULE__.GetDevice]

  @doc false
  def copies_by_device(scope) do
    scope
    |> WorkingCopies.list_harnesses()
    |> Enum.group_by(& &1.device_id, & &1.id)
  end

  @doc false
  def describe(device, copies_by_device) do
    copy_ids = Map.get(copies_by_device, device.id, [])

    connected_ids =
      Enum.filter(copy_ids, &match?({:ok, _, _}, HarnessRegistry.executor_holder(&1)))

    %{
      "id" => device.id,
      "display_name" => Device.display_name(device),
      "hostname" => device.hostname,
      "kind" => value(device.kind),
      "provider" => value(device.provider),
      "provider_name" => device.provider_name,
      "provider_resource_id" => device.provider_resource_id,
      "purpose" => device.purpose,
      "enrollment_status" => enrollment_status(device),
      "last_seen_at" => timestamp(device.last_seen_at),
      "working_copy_ids" => copy_ids,
      "connected_working_copy_ids" => connected_ids,
      "project_harness_connected" => connected_ids != []
    }
  end

  defp enrollment_status(%{token_revoked_at: revoked}) when not is_nil(revoked), do: "revoked"
  defp enrollment_status(%{token_hash: hash}) when is_binary(hash), do: "enrolled"
  defp enrollment_status(_device), do: "not_enrolled"
  defp value(nil), do: nil
  defp value(value), do: to_string(value)
  defp timestamp(nil), do: nil
  defp timestamp(value), do: DateTime.to_iso8601(value)
end
