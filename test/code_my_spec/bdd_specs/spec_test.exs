defmodule CodeMySpec.BddSpecs.SpecTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.BddSpecs.Spec
  alias CodeMySpec.BddSpecs.Scenario

  describe "changeset/2" do
    test "returns valid changeset when name and file_path are provided" do
      attrs = valid_attrs()

      changeset = Spec.changeset(%Spec{}, attrs)

      assert changeset.valid?
      assert changeset.changes.name == "User authentication"
      assert changeset.changes.file_path == "/path/to/spec.exs"
    end

    test "returns invalid changeset when name is missing" do
      attrs = valid_attrs() |> Map.delete(:name)

      changeset = Spec.changeset(%Spec{}, attrs)

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "returns invalid changeset when file_path is missing" do
      attrs = valid_attrs() |> Map.delete(:file_path)

      changeset = Spec.changeset(%Spec{}, attrs)

      refute changeset.valid?
      assert %{file_path: ["can't be blank"]} = errors_on(changeset)
    end

    test "allows nil for description, story_number, criterion_id" do
      attrs =
        valid_attrs()
        |> Map.put(:description, nil)
        |> Map.put(:story_number, nil)
        |> Map.put(:criterion_id, nil)

      changeset = Spec.changeset(%Spec{}, attrs)

      assert changeset.valid?
    end

    test "casts scenarios as embedded schemas" do
      attrs =
        valid_attrs()
        |> Map.put(:scenarios, [
          %{
            name: "Successful login",
            given_steps: ["user exists"],
            when_steps: ["user logs in"],
            then_steps: ["user is authenticated"]
          },
          %{
            name: "Failed login",
            given_steps: ["invalid credentials"],
            when_steps: ["user attempts login"],
            then_steps: ["error is shown"]
          }
        ])

      changeset = Spec.changeset(%Spec{}, attrs)

      assert changeset.valid?
      assert length(changeset.changes.scenarios) == 2

      [scenario1, scenario2] = changeset.changes.scenarios
      assert scenario1.data.__struct__ == Scenario
      assert scenario1.changes.name == "Successful login"
      assert scenario2.data.__struct__ == Scenario
      assert scenario2.changes.name == "Failed login"
    end

    test "sets default empty list for tags when not provided" do
      attrs = valid_attrs() |> Map.delete(:tags)

      changeset = Spec.changeset(%Spec{}, attrs)

      assert changeset.valid?
      # Tags should default to empty list in the schema
      refute Map.has_key?(changeset.changes, :tags)
    end

    test "sets default empty list for scenarios when not provided" do
      attrs = valid_attrs() |> Map.delete(:scenarios)

      changeset = Spec.changeset(%Spec{}, attrs)

      assert changeset.valid?
      # Scenarios should default to empty list in the schema
      refute Map.has_key?(changeset.changes, :scenarios)
    end
  end

  describe "new/1" do
    test "returns Spec struct with all fields populated" do
      attrs =
        valid_attrs()
        |> Map.put(:description, "Authentication spec")
        |> Map.put(:story_number, 123)
        |> Map.put(:criterion_id, 456)
        |> Map.put(:tags, [:integration, :auth])
        |> Map.put(:scenarios, [
          %{
            name: "Login scenario",
            given_steps: ["user exists"],
            when_steps: ["user logs in"],
            then_steps: ["user is authenticated"]
          }
        ])

      spec = Spec.new(attrs)

      assert spec.name == "User authentication"
      assert spec.file_path == "/path/to/spec.exs"
      assert spec.description == "Authentication spec"
      assert spec.story_number == 123
      assert spec.criterion_id == 456
      assert spec.tags == [:integration, :auth]
      assert length(spec.scenarios) == 1
      assert hd(spec.scenarios).name == "Login scenario"
    end

    test "raises when required fields are missing" do
      attrs = valid_attrs() |> Map.delete(:name)

      assert_raise Ecto.InvalidChangesetError, fn ->
        Spec.new(attrs)
      end
    end

    test "populates scenarios list from nested scenario data" do
      attrs =
        valid_attrs()
        |> Map.put(:scenarios, [
          %{
            name: "Scenario 1",
            given_steps: ["step 1"],
            when_steps: ["step 2"],
            then_steps: ["step 3"]
          },
          %{
            name: "Scenario 2",
            given_steps: ["step A"],
            when_steps: ["step B"],
            then_steps: ["step C"]
          }
        ])

      spec = Spec.new(attrs)

      assert length(spec.scenarios) == 2
      assert Enum.at(spec.scenarios, 0).name == "Scenario 1"
      assert Enum.at(spec.scenarios, 0).given_steps == ["step 1"]
      assert Enum.at(spec.scenarios, 1).name == "Scenario 2"
      assert Enum.at(spec.scenarios, 1).then_steps == ["step C"]
    end

    test "defaults tags to empty list when not provided" do
      attrs = valid_attrs() |> Map.delete(:tags)

      spec = Spec.new(attrs)

      assert spec.tags == []
    end
  end

  # Fixture functions

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "User authentication",
        file_path: "/path/to/spec.exs",
        scenarios: []
      },
      overrides
    )
  end
end
