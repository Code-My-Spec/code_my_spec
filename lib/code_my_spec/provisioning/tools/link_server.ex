defmodule CodeMySpec.Provisioning.Tools.LinkServer do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Environments
  alias CodeMySpec.Resources
  alias CodeMySpec.Servers

  @impl true
  def name, do: "link_server"

  @impl true
  def description do
    """
    Legacy provider-name convenience for binding a provisioned environment to
    an account's existing provider device. Use list_devices and
    assign_environment_device for canonical UUID-based placement, including
    harness-managed environments. Provider devices are managed under /app/devices.

    The named server must already be linked to this account. Creates the
    provisioned environment if needed. This only changes its device binding;
    it does not move or deploy app instances or working copies.
    """
  end

  @impl true
  def params do
    %{
      server_name:
        {:required,
         {:meta, :string,
          [
            description:
              "Name of a server already linked to this account, e.g. \"fuellytics-prod\"."
          ]}},
      environment:
        {:required,
         {:meta, :string, [description: "Environment name, e.g. \"prod\" or \"uat\"."]}}
    }
  end

  @impl true
  def call(%{environment: environment, server_name: server_name}, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- CodeMySpec.Tools.connected_project(scope),
         scope <- Resources.project_scope(scope, project),
         {:ok, server} <- find_linked_server(scope, server_name) do
      scope
      |> Environments.put_deployment(environment, %{device_id: server.id})
      |> reply(environment, server_name, context)
    else
      {:error, reason} -> error(reason)
    end
  end

  defp find_linked_server(scope, server_name) do
    case Servers.get_linked(scope, server_name) do
      nil ->
        {:error,
         "#{server_name} is not linked to this account yet — link it first, then point the environment at it"}

      server ->
        {:ok, server}
    end
  end

  defp reply({:ok, _environment}, environment, server_name, _context),
    do: ok("#{environment} now points at #{server_name}.")

  defp reply({:error, reason}, _environment, _server_name, _context), do: error(reason)

  defp ok(text), do: {:ok, text}

  defp error(reason),
    do: {:error, "Could not link the server: #{inspect(reason)}"}
end
