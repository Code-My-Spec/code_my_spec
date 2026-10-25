defmodule CodeMySpec.AppInstances.Tools.GetAppInstance do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.{AppInstances, Tools}
  alias CodeMySpec.AppInstances.Tools.Presentation

  @impl true
  def name, do: "get_app_instance"

  @impl true
  def description do
    "Inspect one app instance in the current project by UUID from list_app_instances. " <>
      "Includes instances without a working copy. Returns last recorded state and bindings, " <>
      "not a live health check; does not start, stop, or contact the runtime."
  end

  @impl true
  def params do
    %{instance_id: {:required, {:meta, :string, [description: "App instance UUID."]}}}
  end

  @impl true
  def call(params, context) do
    with {:ok, result} <- script_result(params, context), do: {:ok, Jason.encode!(result)}
  end

  @impl true
  def script_result(%{instance_id: id}, context) do
    with {:ok, scope} <- Tools.project_scope(context),
         {:ok, id} <- Ecto.UUID.cast(id),
         instance when not is_nil(instance) <- AppInstances.get(scope, id) do
      {:ok, Presentation.row(instance)}
    else
      :error -> {:error, :invalid_instance_id}
      nil -> {:error, :not_found}
      error -> error
    end
  end
end
