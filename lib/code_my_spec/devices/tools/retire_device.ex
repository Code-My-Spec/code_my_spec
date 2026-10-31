defmodule CodeMySpec.Devices.Tools.RetireDevice do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.{Agents, Devices, Tools}
  alias CodeMySpec.Accounts.MembersRepository
  alias CodeMySpec.Devices.Device

  @impl true
  def name, do: "retire_device"

  @impl true
  def description do
    """
    Retire a device in the active account by its exact display name from list_devices.
    Only the project's main agent or an account owner may retire a device.
    A device assigned to any environment cannot be retired; reassign that
    environment first. Retiring a device also removes its working copy records.
    """
  end

  @impl true
  def params do
    %{
      device_name:
        {:required, {:meta, :string, [description: "Exact display_name from list_devices."]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, result} <- script_result(params, context), do: {:ok, Jason.encode!(result)}
  end

  @impl true
  def script_result(%{device_name: name}, context) when is_binary(name) do
    with {:ok, scope} <- Tools.project_scope(context),
         true <- permitted?(scope, context),
         {:ok, device} <- find_device(scope, name),
         {:ok, _} <- Devices.destroy(scope, device) do
      {:ok, %{"device_id" => device.id, "display_name" => Device.display_name(device)}}
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  def script_result(_params, _context), do: {:error, :invalid_device_name}

  defp permitted?(scope, context) do
    owner?(scope) or main_agent?(scope, context)
  end

  defp owner?(%{user: %{id: user_id}, active_account_id: account_id})
       when not is_nil(user_id) and is_binary(account_id),
       do: MembersRepository.get_user_role(user_id, account_id) == :owner

  defp owner?(_scope), do: false

  defp main_agent?(scope, %{agent_id: agent_id}) when is_binary(agent_id) do
    case Agents.fetch_agent(scope, agent_id) do
      {:ok, %{role: :main}} -> true
      _ -> false
    end
  end

  defp main_agent?(_scope, _context), do: false

  defp find_device(scope, name) do
    case Enum.filter(Devices.list_devices(scope), &(Device.display_name(&1) == name)) do
      [device] -> {:ok, device}
      [] -> {:error, :not_found}
      _ -> {:error, :ambiguous_device_name}
    end
  end
end
