defmodule CodeMySpec.BddSpecs do
  @moduledoc """
  Context for working with BDD specifications.

  Provides file-based discovery and coverage analysis of Spex DSL specs without
  database persistence. Maps specs to stories and acceptance criteria through file
  naming conventions, enabling traceability between requirements and executable
  specifications.
  """

  alias CodeMySpec.BddSpecs.{Parser, Spec, SpecProjector}
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.Users.Scope

  @doc """
  Returns all BDD specs for the project as parsed summaries.

  ## Examples

      iex> list_specs(scope)
      [%Spec{}, ...]

  """
  @spec list_specs(Scope.t()) :: [Spec.t()]
  def list_specs(%Scope{} = scope) do
    project_root = scope.active_project.code_repo
    pattern = Path.join([project_root, "test/spex/**/*_spex.exs"])

    pattern
    |> Path.wildcard()
    |> Enum.map(&parse_spec_file/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Returns specs linked to a specific story.

  ## Examples

      iex> list_specs_for_story(scope, story_id)
      [%Spec{}, ...]

  """
  @spec list_specs_for_story(Scope.t(), integer()) :: [Spec.t()]
  def list_specs_for_story(%Scope{} = scope, story_id) when is_integer(story_id) do
    scope
    |> list_specs()
    |> Enum.filter(&(&1.story_id == story_id))
  end

  @doc """
  Returns specs linked to a specific acceptance criterion.

  ## Examples

      iex> list_specs_for_criterion(scope, criterion_id)
      [%Spec{}, ...]

  """
  @spec list_specs_for_criterion(Scope.t(), integer()) :: [Spec.t()]
  def list_specs_for_criterion(%Scope{} = scope, criterion_id) when is_integer(criterion_id) do
    scope
    |> list_specs()
    |> Enum.filter(&(&1.criterion_id == criterion_id))
  end

  @doc """
  Returns a formatted coverage report showing spec coverage across stories.

  ## Examples

      iex> get_coverage_report(scope)
      "# BDD Spec Coverage\\n\\n..."

  """
  @spec get_coverage_report(Scope.t()) :: String.t()
  def get_coverage_report(%Scope{} = scope) do
    specs = list_specs(scope)
    {:ok, stories} = Stories.list_project_stories(scope)

    SpecProjector.format_coverage(stories, specs)
  end

  @doc """
  Checks which acceptance criteria for a story have BDD specs.

  ## Examples

      iex> check_story_coverage(scope, story)
      %{covered: [1, 2], missing: [3, 4]}

  """
  @spec check_story_coverage(Scope.t(), Story.t()) :: %{
          covered: [integer()],
          missing: [integer()]
        }
  def check_story_coverage(%Scope{} = scope, %Story{} = story) do
    # Get all criteria for the story
    criteria = AcceptanceCriteria.list_story_criteria(scope, story.id)
    all_criterion_ids = Enum.map(criteria, & &1.id)

    # Get specs for this story
    specs = list_specs_for_story(scope, story.id)
    covered_criterion_ids =
      specs
      |> Enum.map(& &1.criterion_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    missing_criterion_ids = all_criterion_ids -- covered_criterion_ids

    %{
      covered: covered_criterion_ids,
      missing: missing_criterion_ids
    }
  end

  @doc """
  Validates that a spec file has correct Spex DSL syntax.

  ## Examples

      iex> validate_spec_syntax(scope, "/path/to/spec.exs")
      :ok

      iex> validate_spec_syntax(scope, "/path/to/invalid.exs")
      {:error, ["Missing spex macro"]}

  """
  @spec validate_spec_syntax(Scope.t(), String.t()) :: :ok | {:error, [String.t()]}
  def validate_spec_syntax(%Scope{} = _scope, file_path) do
    Parser.validate_syntax(file_path)
  end

  @doc """
  Returns the conventional file path for a story/criterion spec.

  ## Examples

      iex> spec_file_path(story, criterion)
      "test/spex/42_user_authentication/criterion_1_spex.exs"

  """
  @spec spec_file_path(Story.t(), Criterion.t()) :: String.t()
  def spec_file_path(%Story{} = story, %Criterion{} = criterion) do
    story_slug = slugify(story.title)
    story_dir = "#{story.id}_#{story_slug}"
    filename = "criterion_#{criterion.id}_spex.exs"

    Path.join(["test/spex", story_dir, filename])
  end

  # Private helper to parse a spec file, returning nil on error
  defp parse_spec_file(file_path) do
    case Parser.parse_file(file_path) do
      {:ok, spec} -> spec
      {:error, _} -> nil
    end
  end

  # Private helper to slugify strings for filesystem paths
  defp slugify(string) do
    string
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/\s+/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end
end
