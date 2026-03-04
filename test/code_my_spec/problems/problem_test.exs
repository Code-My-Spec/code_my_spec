defmodule CodeMySpec.Problems.ProblemTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Problems.Problem

  describe "changeset/2" do
    test "accepts valid attributes with all required fields" do
      attrs = valid_attrs()

      changeset = Problem.changeset(%Problem{}, attrs)

      assert changeset.valid?
      assert changeset.changes.severity == :error
      assert changeset.changes.source_type == :static_analysis
      assert changeset.changes.source == "credo"
      assert changeset.changes.file_path == "lib/my_app/foo.ex"
      assert changeset.changes.message == "Module attribute @doc is undefined"
      assert changeset.changes.category == "readability"
    end

    test "accepts problem with optional line number" do
      attrs = valid_attrs(%{line: 42})

      changeset = Problem.changeset(%Problem{}, attrs)

      assert changeset.valid?
      assert changeset.changes.line == 42
    end

    test "accepts problem with optional rule" do
      attrs = valid_attrs(%{rule: "Credo.Check.Readability.ModuleDoc"})

      changeset = Problem.changeset(%Problem{}, attrs)

      assert changeset.valid?
      assert changeset.changes.rule == "Credo.Check.Readability.ModuleDoc"
    end

    test "accepts problem with optional metadata" do
      attrs = valid_attrs(%{metadata: %{"priority" => "high", "column" => 5}})

      changeset = Problem.changeset(%Problem{}, attrs)

      assert changeset.valid?
      assert changeset.changes.metadata == %{"priority" => "high", "column" => 5}
    end

    test "accepts warning severity" do
      attrs = valid_attrs(%{severity: :warning})

      changeset = Problem.changeset(%Problem{}, attrs)

      assert changeset.valid?
      assert changeset.changes.severity == :warning
    end

    test "accepts info severity" do
      attrs = valid_attrs(%{severity: :info})

      changeset = Problem.changeset(%Problem{}, attrs)

      assert changeset.valid?
      assert changeset.changes.severity == :info
    end

    test "accepts test source type" do
      attrs = valid_attrs(%{source_type: :test})

      changeset = Problem.changeset(%Problem{}, attrs)

      assert changeset.valid?
      assert changeset.changes.source_type == :test
    end

    test "accepts runtime source type" do
      attrs = valid_attrs(%{source_type: :runtime})

      changeset = Problem.changeset(%Problem{}, attrs)

      assert changeset.valid?
      assert changeset.changes.source_type == :runtime
    end

    test "uses default source_type when not provided" do
      attrs = valid_attrs() |> Map.delete(:source_type)

      changeset = Problem.changeset(%Problem{}, attrs)

      assert changeset.valid?
    end

    test "accepts nil line number" do
      attrs = valid_attrs(%{line: nil})

      changeset = Problem.changeset(%Problem{}, attrs)

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :line)
    end

    test "accepts nil rule" do
      attrs = valid_attrs(%{rule: nil})

      changeset = Problem.changeset(%Problem{}, attrs)

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :rule)
    end

    test "accepts nil metadata" do
      attrs = valid_attrs(%{metadata: nil})

      changeset = Problem.changeset(%Problem{}, attrs)

      assert changeset.valid?
    end

    test "requires severity" do
      attrs = valid_attrs() |> Map.delete(:severity)

      changeset = Problem.changeset(%Problem{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).severity
    end

    test "requires source" do
      attrs = valid_attrs() |> Map.delete(:source)

      changeset = Problem.changeset(%Problem{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).source
    end

    test "requires file_path" do
      attrs = valid_attrs() |> Map.delete(:file_path)

      changeset = Problem.changeset(%Problem{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).file_path
    end

    test "requires message" do
      attrs = valid_attrs() |> Map.delete(:message)

      changeset = Problem.changeset(%Problem{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).message
    end

    test "requires category" do
      attrs = valid_attrs() |> Map.delete(:category)

      changeset = Problem.changeset(%Problem{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).category
    end

    test "requires project_id" do
      attrs = valid_attrs() |> Map.delete(:project_id)

      changeset = Problem.changeset(%Problem{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).project_id
    end

    test "rejects invalid severity" do
      attrs = valid_attrs(%{severity: :critical})

      changeset = Problem.changeset(%Problem{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).severity
    end

    test "rejects invalid source_type" do
      attrs = valid_attrs(%{source_type: :compile})

      changeset = Problem.changeset(%Problem{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).source_type
    end

    test "rejects nil source" do
      attrs = valid_attrs(%{source: nil})

      changeset = Problem.changeset(%Problem{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).source
    end

    test "rejects source string longer than 255 characters" do
      attrs = valid_attrs(%{source: String.duplicate("a", 256)})

      changeset = Problem.changeset(%Problem{}, attrs)

      refute changeset.valid?
      assert "should be at most 255 character(s)" in errors_on(changeset).source
    end

    test "rejects nil file_path" do
      attrs = valid_attrs(%{file_path: nil})

      changeset = Problem.changeset(%Problem{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).file_path
    end

    test "rejects nil category string" do
      attrs = valid_attrs(%{category: nil})

      changeset = Problem.changeset(%Problem{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).category
    end

    test "rejects category string longer than 255 characters" do
      attrs = valid_attrs(%{category: String.duplicate("a", 256)})

      changeset = Problem.changeset(%Problem{}, attrs)

      refute changeset.valid?
      assert "should be at most 255 character(s)" in errors_on(changeset).category
    end

    test "rejects line number less than or equal to zero" do
      attrs = valid_attrs(%{line: 0})

      changeset = Problem.changeset(%Problem{}, attrs)

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).line
    end

    test "rejects negative line number" do
      attrs = valid_attrs(%{line: -5})

      changeset = Problem.changeset(%Problem{}, attrs)

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).line
    end
  end

  # Fixture functions

  defp valid_attrs(overrides \\ %{}) do
    project_id = Ecto.UUID.generate()

    Map.merge(
      %{
        severity: :error,
        source_type: :static_analysis,
        source: "credo",
        file_path: "lib/my_app/foo.ex",
        message: "Module attribute @doc is undefined",
        category: "readability",
        project_id: project_id
      },
      overrides
    )
  end
end
