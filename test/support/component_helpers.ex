defmodule CodeMySpecSpex.ComponentHelpers do
  @moduledoc """
  Surface-level component setup for spex tests. Drives the
  `CreateComponent` MCP tool — the same patch-mode surface the
  architect uses in production — and reads back the persisted
  component via the bridge's `get_component_by_module_name/2`
  delegate (a read accessor, mirroring how
  `:synced_context_component` reads the result of its sync click).

  Use this when a spec needs a Component without going through the
  full architecture-proposal flow but does want surface-driven
  creation.
  """

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.CreateComponent
  alias CodeMySpecSpex.Fixtures

  @doc """
  Drives the `CreateComponent` MCP tool and returns the persisted
  component. `attrs` matches the tool's schema (`:name`, `:type`,
  `:module_name`, `:description`, `:parent_component_id`).
  """
  @spec create(map(), keyword() | map()) :: term()
  def create(scope, attrs) do
    frame = %Frame{assigns: %{current_scope: scope}}
    params = attrs |> Enum.into(%{})

    {:reply, response, _frame} = CreateComponent.execute(params, frame)

    # Asserts its own success: a refused create used to come back as `nil` here
    # and fail somewhere later that had nothing to do with it.
    if response.isError,
      do: raise("create_component refused #{inspect(params)}: #{inspect(response.content)}")

    Fixtures.get_component_by_module_name(scope, params.module_name)
  end
end
