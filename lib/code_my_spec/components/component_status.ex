defmodule CodeMySpec.Components.ComponentStatus do
  @moduledoc """
  Embedded schema for component analysis status computed by ComponentAnalyzer.
  Contains file existence status, test results, and all computed analysis data.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          design_exists: boolean(),
          code_exists: boolean(),
          test_exists: boolean(),
          spec_exists: boolean(),
          review_exists: boolean(),
          test_status: :passing | :failing | :not_run,
          expected_files: %{atom() => String.t()},
          actual_files: [String.t()],
          failing_tests: [String.t()],
          computed_at: DateTime.t() | nil
        }

  @primary_key false
  embedded_schema do
    field :design_exists, :boolean, default: false
    field :code_exists, :boolean, default: false
    field :test_exists, :boolean, default: false
    field :spec_exists, :boolean, default: false
    field :review_exists, :boolean, default: false
    field :test_status, Ecto.Enum, values: [:passing, :failing, :not_run], default: :not_run
    field :expected_files, :map, default: %{}
    field :actual_files, {:array, :string}, default: []
    field :failing_tests, {:array, :string}, default: []
    field :computed_at, :utc_datetime
  end

  def changeset(component_status, attrs) do
    component_status
    |> cast(attrs, [
      :design_exists,
      :code_exists,
      :test_exists,
      :spec_exists,
      :review_exists,
      :test_status,
      :expected_files,
      :actual_files,
      :failing_tests,
      :computed_at
    ])
    |> validate_required([
      :design_exists,
      :code_exists,
      :test_exists,
      :spec_exists,
      :review_exists,
      :test_status
    ])
  end

  @doc """
  Creates a ComponentStatus from analysis data.
  """
  def from_analysis(expected_files, actual_files, failing_tests) do
    # Check review_file only if it exists in expected_files (context components)
    review_file = Map.get(expected_files, :review_file)
    review_exists = review_file != nil and review_file in actual_files

    %__MODULE__{
      design_exists: expected_files.design_file in actual_files,
      code_exists: expected_files.code_file in actual_files,
      test_exists: expected_files.test_file in actual_files,
      spec_exists: expected_files.spec_file in actual_files,
      review_exists: review_exists,
      test_status: determine_test_status(failing_tests, actual_files, expected_files.test_file),
      expected_files: expected_files,
      actual_files: actual_files,
      failing_tests: failing_tests,
      computed_at: DateTime.utc_now()
    }
  end

  @doc """
  Determines test status based on test file existence and failures.
  """
  def determine_test_status(failing_tests, actual_files, expected_test_file) do
    has_test_file = expected_test_file in actual_files
    has_failing_tests = failing_tests != []

    cond do
      not has_test_file -> :not_run
      has_failing_tests -> :failing
      has_test_file -> :passing
    end
  end

  @doc """
  Returns true if all file requirements are satisfied (design, code, test exist and tests pass).
  """
  def fully_satisfied?(%__MODULE__{} = status) do
    status.design_exists and
      status.code_exists and
      status.test_exists and
      status.spec_exists and
      status.test_status == :passing
  end

  @doc """
  Returns true if component is ready for the next development step.
  """
  def ready_for_work?(%__MODULE__{} = status) do
    cond do
      # Ready for design
      not status.design_exists -> true
      not status.spec_exists -> true
      # Ready for coding if design exists
      not status.code_exists -> status.design_exists
      # Ready for testing if code exists
      not status.test_exists -> status.code_exists
      # Ready for test fixing
      status.test_status == :failing -> true
      # All done
      true -> false
    end
  end

  @doc """
  Returns the next recommended action for this component.
  """
  def next_action(%__MODULE__{} = status) do
    cond do
      not status.design_exists -> :create_design
      not status.spec_exists -> :create_spec
      not status.code_exists -> :implement_code
      not status.test_exists -> :write_tests
      status.test_status == :failing -> :fix_tests
      true -> :complete
    end
  end
end
