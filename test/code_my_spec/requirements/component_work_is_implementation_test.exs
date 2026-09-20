defmodule CodeMySpec.Requirements.ComponentWorkIsImplementationTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Configurations.ProjectConfiguration
  alias CodeMySpec.Requirements.RequirementDefinitionData, as: Definitions

  test "all component templates contain only implementation work and valid prerequisites" do
    for type <-
          ~w(context coordination_context live_context controller schema behaviour json liveview liveview_component repository module infrastructure) do
      definitions = Definitions.graph_for_type(type)
      ids = MapSet.new(definitions, & &1.id)
      assert Enum.all?(definitions, &(&1.name == "implementation_file"))

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
    assert "bdd_specs_passing" in names
    assert "qa_complete" in names
  end
end
