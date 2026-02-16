defmodule CodeMySpec.BddSpecs do
  @moduledoc """
  Context for working with BDD specifications.

  Provides file-based discovery and coverage analysis of Spex DSL specs without
  database persistence. Maps specs to stories and acceptance criteria through file
  naming conventions, enabling traceability between requirements and executable
  specifications.
  """

  require Logger

  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.BddSpecs.{Parser, Spec, SpecProjector, Spex}
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @doc """
  Returns all BDD specs for the project as parsed summaries.

  ## Examples

      iex> list_specs(env)
      [%Spec{}, ...]

  """
  @spec list_specs(Environment.t()) :: [Spec.t()]
  def list_specs(%Environment{} = env) do
    Logger.debug("[BddSpecs] list_specs: cwd=#{inspect(env.cwd)}")

    pattern = "test/spex/**/*_spex.exs"
    Logger.debug("[BddSpecs] list_specs: pattern=#{inspect(pattern)}")

    files = Environments.glob(env, pattern)
    Logger.debug("[BddSpecs] list_specs: found #{length(files)} spec files")
    Logger.debug("[BddSpecs] list_specs: file paths: #{inspect(files)}")

    specs =
      files
      |> Enum.map(&parse_spec_file/1)
      |> Enum.reject(&is_nil/1)

    Logger.debug("[BddSpecs] list_specs: successfully parsed #{length(specs)} specs")
    specs
  end

  @doc """
  Returns specs linked to a specific story.

  ## Examples

      iex> list_specs_for_story(env, story_id)
      [%Spec{}, ...]

  """
  @spec list_specs_for_story(Environment.t(), integer()) :: [Spec.t()]
  def list_specs_for_story(%Environment{} = env, story_id) when is_integer(story_id) do
    specs = list_specs(env)

    # Debug: log what story_ids we found in the spec files
    found_story_ids = specs |> Enum.map(& &1.story_id) |> Enum.uniq()

    Logger.debug(
      "[BddSpecs] list_specs_for_story: looking for story_id=#{story_id}, found story_ids in files: #{inspect(found_story_ids)}"
    )

    Enum.filter(specs, &(&1.story_id == story_id))
  end

  @doc """
  Returns specs linked to a specific acceptance criterion.

  ## Examples

      iex> list_specs_for_criterion(env, criterion_id)
      [%Spec{}, ...]

  """
  @spec list_specs_for_criterion(Environment.t(), integer()) :: [Spec.t()]
  def list_specs_for_criterion(%Environment{} = env, criterion_id)
      when is_integer(criterion_id) do
    env
    |> list_specs()
    |> Enum.filter(&(&1.criterion_id == criterion_id))
  end

  @doc """
  Returns a formatted coverage report showing spec coverage across stories.

  ## Examples

      iex> get_coverage_report(env, stories)
      "# BDD Spec Coverage\\n\\n..."

  """
  @spec get_coverage_report(Environment.t(), [Story.t()]) :: String.t()
  def get_coverage_report(%Environment{} = env, stories) do
    specs = list_specs(env)
    SpecProjector.format_coverage(stories, specs)
  end

  @doc """
  Checks which acceptance criteria for a story have BDD specs.

  ## Examples

      iex> check_story_coverage(env, story)
      %{covered: [1, 2], missing: [3, 4]}

  """
  @spec check_story_coverage(Environment.t(), Story.t()) :: %{
          covered: [integer()],
          missing: [integer()]
        }
  def check_story_coverage(%Environment{} = env, %Story{} = story) do
    Logger.debug("[BddSpecs] check_story_coverage for story #{story.id}")

    # Use criteria embedded in story (loaded via stories API)
    criteria = story.criteria || []

    Logger.debug(
      "[BddSpecs] story.criteria is_list: #{is_list(criteria)}, length: #{if is_list(criteria), do: length(criteria), else: "N/A"}"
    )

    all_criterion_ids = Enum.map(criteria, & &1.id)
    Logger.debug("[BddSpecs] all_criterion_ids: #{inspect(all_criterion_ids)}")

    # Get specs for this story
    specs = list_specs_for_story(env, story.id)
    Logger.debug("[BddSpecs] Found #{length(specs)} specs for story #{story.id}")

    covered_criterion_ids =
      specs
      |> Enum.map(& &1.criterion_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    missing_criterion_ids = all_criterion_ids -- covered_criterion_ids

    Logger.debug(
      "[BddSpecs] check_story_coverage result: covered=#{length(covered_criterion_ids)}, missing=#{length(missing_criterion_ids)}"
    )

    %{
      covered: covered_criterion_ids,
      missing: missing_criterion_ids
    }
  end

  @doc """
  Returns the next incomplete story that needs BDD specs, ordered by priority.

  Finds the highest-priority story that has at least one acceptance criterion
  without a corresponding BDD spec file. Returns nil if all stories have
  complete spec coverage.

  ## Examples

      iex> get_next_incomplete_story(env, scope)
      %Story{id: 42, title: "User Login", ...}

      iex> get_next_incomplete_story(env, scope)  # when all complete
      nil

  """
  @spec get_next_incomplete_story(Environment.t(), Scope.t()) :: Story.t() | nil
  def get_next_incomplete_story(%Environment{} = env, scope) do
    stories = Stories.list_project_stories_by_priority(scope)

    Enum.find(stories, fn story ->
      coverage = check_story_coverage(env, story)
      not Enum.empty?(coverage.missing)
    end)
  end

  @doc """
  Validates that a spec file has correct Spex DSL syntax.

  ## Examples

      iex> validate_spec_syntax("/path/to/spec.exs")
      :ok

      iex> validate_spec_syntax("/path/to/invalid.exs")
      {:error, ["Missing spex macro"]}

  """
  @spec validate_spec_syntax(String.t()) :: :ok | {:error, [String.t()]}
  def validate_spec_syntax(file_path) do
    Parser.validate_syntax(file_path)
  end

  @doc """
  Returns the conventional file path for a story/criterion spec.

  ## Examples

      iex> spec_file_path(story, criterion)
      "test/spex/42_user_authentication/criterion_1_valid_credentials_spex.exs"

  """
  @spec spec_file_path(Story.t(), Criterion.t()) :: String.t()
  def spec_file_path(%Story{} = story, %Criterion{} = criterion) do
    story_slug = slugify(story.title)
    story_dir = "#{story.id}_#{story_slug}"
    criterion_slug = slugify(criterion.description)
    filename = "criterion_#{criterion.id}_#{criterion_slug}_spex.exs"

    Path.join(["test/spex", story_dir, filename])
  end

  @doc """
  Execute BDD specs for the given file paths.

  Runs the specs via `mix spex` and returns structured failure information.

  ## Options

  - `:project_root` - Project root directory (required)
  - `:quiet` - Suppress console output (default: false)

  ## Returns

  - `{:ok, failures, exit_code}` - List of failures (empty if all pass) and exit code
  - `{:error, reason}` - If execution fails

  ## Examples

      iex> run_specs(["test/spex/login_spex.exs"], project_root: "/path/to/project")
      {:ok, [], 0}

      iex> run_specs(["test/spex/failing_spex.exs"], project_root: "/path/to/project")
      {:ok, [%Spex.Failure{...}], 1}

  """
  @spec run_specs([String.t()], keyword()) ::
          {:ok, [Spex.Failure.t()], integer()} | {:error, term()}
  def run_specs(file_paths, opts \\ []) do
    Spex.execute(file_paths, opts)
  end

  # Private helper to parse a spec file, returning nil on error
  defp parse_spec_file(file_path) do
    case Parser.parse_file(file_path) do
      {:ok, spec} ->
        Logger.debug(
          "[BddSpecs] parse_spec_file: SUCCESS for #{file_path}, story_id=#{inspect(spec.story_id)}, criterion_id=#{inspect(spec.criterion_id)}"
        )

        spec

      {:error, reason} ->
        Logger.warning(
          "[BddSpecs] parse_spec_file: FAILED for #{file_path}, reason=#{inspect(reason)}"
        )

        nil
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
