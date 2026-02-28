defmodule CodeMySpec.AcceptanceCriteria.CriterionTest do
  use CodeMySpec.DataCase, async: true

  alias CodeMySpec.AcceptanceCriteria.Criterion

  describe "changeset/2" do
    test "accepts valid attributes with all required fields" do
      attrs = valid_attrs()

      changeset = Criterion.changeset(%Criterion{}, attrs)

      assert changeset.valid?
      assert changeset.changes.description == "User can log in with email and password"
      assert changeset.changes.story_id == attrs.story_id
      assert changeset.changes.project_id == attrs.project_id
    end

    test "accepts criterion with verified status" do
      attrs = valid_attrs(%{verified: true})

      changeset = Criterion.changeset(%Criterion{}, attrs)

      assert changeset.valid?
      assert changeset.changes.verified == true
    end

    test "accepts criterion with verified_at timestamp" do
      verified_at = ~U[2026-01-20 10:00:00Z]
      attrs = valid_attrs(%{verified_at: verified_at})

      changeset = Criterion.changeset(%Criterion{}, attrs)

      assert changeset.valid?
      assert changeset.changes.verified_at == verified_at
    end

    test "accepts criterion with all fields populated" do
      verified_at = ~U[2026-01-20 10:00:00Z]

      attrs =
        valid_attrs(%{
          verified: true,
          verified_at: verified_at
        })

      changeset = Criterion.changeset(%Criterion{}, attrs)

      assert changeset.valid?
      assert changeset.changes.description == "User can log in with email and password"
      assert changeset.changes.verified == true
      assert changeset.changes.verified_at == verified_at
    end

    test "defaults verified to false when not provided" do
      attrs = valid_attrs() |> Map.delete(:verified)

      changeset = Criterion.changeset(%Criterion{}, attrs)

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :verified)
    end

    test "accepts nil verified_at" do
      attrs = valid_attrs(%{verified_at: nil})

      changeset = Criterion.changeset(%Criterion{}, attrs)

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :verified_at)
    end

    test "requires description" do
      attrs = valid_attrs() |> Map.delete(:description)

      changeset = Criterion.changeset(%Criterion{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).description
    end

    test "requires story_id" do
      attrs = valid_attrs() |> Map.delete(:story_id)

      changeset = Criterion.changeset(%Criterion{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).story_id
    end

    test "requires project_id" do
      attrs = valid_attrs() |> Map.delete(:project_id)

      changeset = Criterion.changeset(%Criterion{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).project_id
    end

    test "rejects nil description" do
      attrs = valid_attrs(%{description: nil})

      changeset = Criterion.changeset(%Criterion{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).description
    end

    test "rejects empty description" do
      attrs = valid_attrs(%{description: ""})

      changeset = Criterion.changeset(%Criterion{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).description
    end

    test "rejects nil story_id" do
      attrs = valid_attrs(%{story_id: nil})

      changeset = Criterion.changeset(%Criterion{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).story_id
    end

    test "rejects nil project_id" do
      attrs = valid_attrs(%{project_id: nil})

      changeset = Criterion.changeset(%Criterion{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).project_id
    end

  end

  # Fixture functions

  defp valid_attrs(overrides \\ %{}) do
    story_id = System.unique_integer([:positive])
    project_id = Ecto.UUID.generate()

    Map.merge(
      %{
        description: "User can log in with email and password",
        story_id: story_id,
        project_id: project_id
      },
      overrides
    )
  end
end
