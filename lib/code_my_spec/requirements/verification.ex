defmodule CodeMySpec.Requirements.Verification do
  @moduledoc """
  The agreement contract used by graph diagnostics. Freshness timestamps are
  evidence about a computation, not its answer. Details and execution metadata
  are part of the answer: changing them can change which work is offered.
  """

  @behavior_fields ~w(satisfied satisfied_by scope execution_type validation_type
    orchestrated_by parent_entity_id render_command_always? role)a
  @stored_fields ~w(satisfied owner_component_type node_scope)a

  @doc "All differences must be absent, including extra requirements."
  def clean?(report) do
    Enum.all?([:missing, :extra, :disagree, :edges_missing, :edges_extra], fn field ->
      Map.fetch!(report, field) == 0
    end) and Map.get(report, :actionable_disagree, 0) == 0
  end

  @doc """
  The behavior of a rehydrated or freshly computed requirement.

  Prerequisites are compared as resolved graph edges by the caller. The
  computed node leaves its template IDs empty; rehydration retains those IDs.
  Comparing those representations would report a difference on every chain.
  """
  def behavior(node) do
    node
    |> Map.take(@behavior_fields)
    |> Map.put(:details, details(node.details))
  end

  @doc "The persisted inputs to rehydration, excluding storage and freshness stamps."
  def stored(node) do
    node
    |> Map.take(@stored_fields)
    |> Map.put(:details, details(node.details))
  end

  @doc "Fields responsible for a disagreement, in a deterministic order."
  def changed_fields(left, right) do
    (Map.keys(left) ++ Map.keys(right))
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(left, &1) != Map.get(right, &1)))
    |> Enum.sort()
  end

  # Use exactly the representation jsonb can preserve, including nested keys,
  # atom values and timestamps. List order remains meaningful.
  defp details(value), do: value |> Kernel.||(%{}) |> Jason.encode!() |> Jason.decode!()
end
