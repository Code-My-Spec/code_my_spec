defmodule CodeMySpec.Devices.Tools.GetDevice do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.{Devices, Tools}

  @impl true
  def name, do: "get_device"

  @impl true
  def description do
    """
    Inspect a machine by its canonical device UUID on the active account.
    Returns the same safe metadata as list_devices, including this project's checkout IDs
    and live harness connections. Enrollment and last_seen_at do not imply availability.
    Provider numeric resource IDs and hostnames are not device UUIDs.
    """
  end

  @impl true
  def params do
    %{
      device_id:
        {:required, {:meta, :string, [description: "Canonical device UUID from list_devices."]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, result} <- script_result(params, context), do: {:ok, Jason.encode!(result)}
  end

  @impl true
  def script_result(%{device_id: id}, context) do
    with {:ok, scope} <- Tools.project_scope(context),
         {:ok, id} <- cast_id(id),
         device when not is_nil(device) <- Devices.get_device(scope, id) do
      {:ok, Devices.Tools.describe(device, Devices.Tools.copies_by_device(scope))}
    else
      :error -> {:error, :invalid_device_id}
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp cast_id(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp cast_id(_id), do: :error
end
