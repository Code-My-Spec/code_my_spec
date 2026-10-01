defmodule CodeMySpec.Components.Types do
  @moduledoc """
  The component types an agent can author.

  Each has a meaning of its own downstream: a requirement template
  (`RequirementDefinitionData.graph_for_type/1`), a conventional path, or — for
  `infrastructure` — no requirements at all. `module` is the general case.

  A module of its own, depending on nothing, so a tool's schema can list them
  without a compile-time dependency on the `Component` schema.
  """

  @types ~w(
    context coordination_context live_context schema behaviour json
    liveview liveview_component controller module infrastructure
  )

  @doc "Every authorable type, in order."
  def all, do: @types
end
