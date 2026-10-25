defmodule CodeMySpec.Environments.Tools.AssignEnvironmentDevice do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.{Devices, Environments, Tools}

  @impl true
  def name, do: "assign_environment_device"

  @impl true
  def description do
    """
    Bind a durable environment in the current project to a device in this account.
    Use list_environments and list_devices to discover UUIDs. Works for harness
    and provisioned destinations. This changes only the environment's device
    binding; it does not move, start, stop or deploy app instances, working copies
    or agents, and does not provision infrastructure.
    """
  end

  @impl true
  def params do
    %{
      environment_id:
        {:required, {:meta, :string, [description: "Environment UUID in the current project."]}},
      device_id:
        {:required, {:meta, :string, [description: "Device UUID in the current account."]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, result} <- script_result(params, context), do: {:ok, Jason.encode!(result)}
  end

  @impl true
  def script_result(%{environment_id: environment_id, device_id: device_id}, context) do
    with {:ok, scope} <- Tools.project_scope(context),
         {:ok, uuid} when is_binary(uuid) <- Ecto.UUID.cast(device_id),
         environment when not is_nil(environment) <- Environments.get_by_id(scope, environment_id),
         device when not is_nil(device) <- Devices.get_device(scope, uuid),
         {:ok, updated} <- Environments.put(scope, environment.name, %{device_id: device.id}) do
      {:ok, %{"environment_id" => updated.id, "device_id" => updated.device_id}}
    else
      nil ->
        {:error, :not_found}

      {:ok, nil} ->
        {:error, :invalid_device_id}

      :error ->
        {:error, :invalid_device_id}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, "Could not assign environment device: #{inspect(changeset.errors)}"}

      error ->
        error
    end
  end
end
