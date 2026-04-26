defmodule CodeMySpec.McpServers.Components.Tools.CreateDependencies do
  @moduledoc """
  Creates multiple dependencies in batch.
  Returns successful creations and any validation errors.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Components.ComponentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :dependencies,
          {:list,
           {:object,
            %{
              source_component_id: {:required, :integer},
              target_component_id: {:required, :integer}
            }}},
          required: true
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_scope(frame) do
      {:ok, scope} ->
        create_batch(scope, params, frame)

      {:error, reason} ->
        {:reply, ComponentsMapper.error(reason), frame}
    end
  end

  defp create_batch(scope, params, frame) do
    {successes, failures} =
      params.dependencies
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {dependency, index}, {success_acc, failure_acc} ->
        case Components.create_dependency(scope, dependency) do
          {:ok, created_dependency} ->
            {[created_dependency | success_acc], failure_acc}

          {:error, changeset} ->
            {success_acc, [{index, changeset} | failure_acc]}
        end
      end)

    successes = Enum.reverse(successes)
    failures = Enum.reverse(failures)

    case failures do
      [] ->
        {:reply, ComponentsMapper.dependencies_batch_response(successes), frame}

      _has_failures ->
        {:reply, ComponentsMapper.batch_errors_response(successes, failures), frame}
    end
  end
end
