defmodule CodeMySpec.Environments.Tools.ListEnvironments do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.{AppInstances, Environments, Tools}

  @impl true
  def name, do: "list_environments"

  @impl true
  def description do
    """
    List this project's durable environments and their assigned app instances.
    Reports management (harness or provisioned), host, device, source,
    status and revision. Does not create environments or start instances.
    Use these IDs with assign_app_instance_environment or assign_environment_device
    to change a binding.
    """
  end

  @impl true
  def params, do: %{}

  @impl true
  def call(params, context) do
    with {:ok, environments} <- script_result(params, context),
         do: {:ok, Jason.encode!(environments)}
  end

  @impl true
  def script_result(_params, context) do
    with {:ok, scope} <- Tools.project_scope(context) do
      {:ok, Enum.map(Environments.list_existing(scope), &row(scope, &1))}
    end
  end

  defp row(scope, environment) do
    %{
      "id" => environment.id,
      "name" => environment.name,
      "management" => to_string(environment.management),
      "host" => environment.host,
      "device_id" => environment.device_id,
      "instances" =>
        Enum.map(AppInstances.list_for_environment(scope, environment.id), &instance_row/1)
    }
  end

  defp instance_row(instance) do
    %{
      "id" => instance.id,
      "device_id" => instance.device_id,
      "working_copy_id" => instance.working_copy_id,
      "source_root" => instance.source_root,
      "status" => instance.status,
      "commit" => instance.commit,
      "deployment_image" => instance.deployment_image,
      "serving_commit" => instance.serving_commit
    }
  end
end
