defmodule CodeMySpecSpex.ComponentHelpers do
  @moduledoc """
  Surface-level component setup for spex tests. Drives the
  `CreateComponent` MCP tool — the same patch-mode surface the
  architect uses in production — and reads back the persisted
  component via the bridge's `get_component_by_module_name/2`
  delegate (a read accessor, mirroring how
  `:synced_context_component` reads the result of its sync click).

  Use this instead of `Fixtures.component_fixture` when a spec needs
  a Component without going through the full architecture-proposal
  flow but does want surface-driven creation.

  Note: `CreateComponent` writes a stub spec file at the canonical
  path as a side effect — the spec body is left for the
  `ComponentSpec` phase to fill in. Specs that need a "no spec file
  on disk" precondition can call `delete_stub/2` to strip it.
  """

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
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

    {:reply, _response, _frame} = CreateComponent.execute(params, frame)

    Fixtures.get_component_by_module_name(scope, params.module_name)
  end

  @doc """
  Removes the stub spec file `CreateComponent` writes as a side
  effect. Use when a spec needs the `spec_file` requirement to
  remain unsatisfied after the component is created.
  """
  @spec delete_stub(map(), term()) :: :ok | {:error, term()}
  def delete_stub(scope, component) do
    spec_path = canonical_spec_path(component.module_name)
    Environments.delete_file(scope.environment, spec_path)
  end

  # Mirrors `CodeMySpec.Architecture.SpecStub.canonical_spec_path/1` —
  # the canonical spec lives at `.code_my_spec/spec/<module>.spec.md`
  # with the module path under_scored.
  defp canonical_spec_path(module_name) when is_binary(module_name) do
    relative =
      module_name
      |> String.split(".")
      |> Enum.map_join("/", &Macro.underscore/1)

    ".code_my_spec/spec/#{relative}.spec.md"
  end
end
