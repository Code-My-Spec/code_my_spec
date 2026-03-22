defmodule CodeMySpec.McpServers.Components.Tools.CreateComponents do
  @moduledoc """
  Creates multiple components in batch.
  Returns successful creations and any validation errors.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Components.ComponentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :components,
          {:list,
           {:object,
            %{
              name: {:required, :string},
              type:
                {:required, :string,
                 enum: ["context", "coordination_context"],
                 description:
                   "Must be one of: context (domain contexts that own entities), :coordination_context (orchestrate workflows across domain context)"},
              module_name: {:required, :string},
              description: :string,
              parent_component_id: :integer
            }}},
          required: true
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame) do
      {successes, failures} =
        params.components
        |> Enum.with_index()
        |> Enum.reduce({[], []}, fn {component, index}, {success_acc, failure_acc} ->
          case Components.create_component(scope, component) do
            {:ok, created_component} ->
              {[created_component | success_acc], failure_acc}

            {:error, changeset} ->
              {success_acc, [{index, changeset} | failure_acc]}
          end
        end)

      successes = Enum.reverse(successes)
      failures = Enum.reverse(failures)

      case failures do
        [] ->
          {:reply, ComponentsMapper.components_batch_response(successes), frame}

        _has_failures ->
          {:reply, ComponentsMapper.batch_errors_response(successes, failures), frame}
      end
    else
      {:error, reason} ->
        {:reply, ComponentsMapper.error(reason), frame}
    end
  end
end
