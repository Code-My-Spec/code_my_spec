defmodule CodeMySpec.Devices.Tools.ListDevices do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.{Devices, Tools}

  @impl true
  def name, do: "list_devices"

  @impl true
  def description do
    """
    List machines on the active account, including deployment-only and dormant devices.
    Returns canonical device UUIDs, provider identity and current-project working copy IDs.
    Enrollment describes device-token registration, not live availability: desktop harnesses
    may connect without a device token. project_harness_connected and connected_working_copy_ids
    report live harness connections for this project only, not machine power or other projects.
    last_seen_at is historical observation, not evidence of a current connection.
    """
  end

  @impl true
  def params, do: %{}

  @impl true
  def call(params, context) do
    with {:ok, result} <- script_result(params, context), do: {:ok, Jason.encode!(result)}
  end

  @impl true
  def script_result(_params, context) do
    with {:ok, scope} <- Tools.project_scope(context) do
      copies = Devices.Tools.copies_by_device(scope)
      {:ok, Enum.map(Devices.list_devices(scope), &Devices.Tools.describe(&1, copies))}
    end
  end
end
