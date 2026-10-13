defmodule CodeMySpec.Requirements.ComponentWorkIsImplementationTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Configurations.ProjectConfiguration
  alias CodeMySpec.Requirements.RequirementDefinitionData, as: Definitions

  test "all component templates contain only implementation work and valid prerequisites" do
    for type <-
          ~w(context coordination_context live_context controller schema behaviour json liveview liveview_component repository module infrastructure) do
      definitions = Definitions.graph_for_type(type)
      ids = MapSet.new(definitions, & &1.id)
      # Work is implementation; the one other node is a container's dependency
      # junction, which is never work.
      assert Enum.all?(definitions, fn definition ->
               definition.name == "implementation_file" or
                 (definition.name == "dependencies_met" and definition.check_type == :always and
                    is_nil(definition.satisfied_by))
             end)

      assert Enum.all?(definitions, fn definition ->
               Enum.all?(definition.prerequisites, &MapSet.member?(ids, &1))
             end)
    end
  end

  test "retired settings cannot reintroduce component workflow stages" do
    attrs = %{
      project_id: Ecto.UUID.generate(),
      require_specs: true,
      require_reviews: true,
      require_unit_tests: true,
      exunit: :block_all
    }

    changeset = ProjectConfiguration.changeset(%ProjectConfiguration{}, attrs)
    assert changeset.valid?

    for field <- [:require_specs, :require_reviews, :require_unit_tests] do
      refute field in ProjectConfiguration.__schema__(:fields)
      refute Map.has_key?(changeset.changes, field)
    end
  end

  test "story test and QA gates remain" do
    names = Enum.map(Definitions.story_graph(), & &1.name)
    assert "bdd_specs_exist" in names
    assert "ready_for_qa" in names
    assert "qa_complete" in names
  end
end
