defmodule CodeMySpec.AcceptanceCriteriaFixtures do
  @moduledoc """
  Test data for `CodeMySpec.AcceptanceCriteria`.
  """

  alias CodeMySpec.AcceptanceCriteria

  @doc """
  Generate a criterion with valid attributes.
  """
  def criterion_fixture(scope, story, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        description:
          "Given a user is logged in, when they view the dashboard, then they see their recent activity"
      })

    {:ok, criterion} = AcceptanceCriteria.create_criterion(scope, story, attrs)
    criterion
  end

  @doc """
  Generate a verified criterion.
  """
  def verified_criterion_fixture(scope, story, attrs \\ %{}) do
    criterion = criterion_fixture(scope, story, attrs)
    {:ok, verified} = AcceptanceCriteria.mark_verified(scope, criterion)
    verified
  end

  @doc """
  Generate multiple criteria for a story.
  """
  def multiple_criteria_fixture(scope, story, count \\ 3) do
    Enum.map(1..count, fn i ->
      criterion_fixture(scope, story, %{
        description: "Acceptance criterion #{i} for story"
      })
    end)
  end

  @doc """
  Valid attributes for creating a criterion.
  """
  def valid_criterion_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      description: "Given valid input, when processing, then success occurs"
    })
  end

  @doc """
  Invalid attributes for creating a criterion (missing required fields).
  """
  def invalid_criterion_attrs do
    %{description: nil}
  end
end
