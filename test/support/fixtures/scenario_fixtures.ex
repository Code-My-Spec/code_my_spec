defmodule CodeMySpec.ScenarioFixtures do
  @moduledoc """
  Test fixtures for scenario replay tests.

  Provides DB state (project, stories, criteria) and project checkout
  for full-lifecycle scenario testing against the math_test_project.

  ## Usage

      setup do
        %{scope: scope, stories: stories} = scenario_base_fixture()
        project_dir = checkout_scenario_project(tmp_dir)
        scope = put_scenario_environment(scope, project_dir)
        %{scope: scope, stories: stories, project_dir: project_dir}
      end
  """

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.AcceptanceCriteriaFixtures

  alias CodeMySpec.ClientUsers.ClientUser
  alias CodeMySpec.Environments.Environment

  @math_project_repo Path.expand(
                       "../math_test_project",
                       Path.dirname(Path.dirname(Path.dirname(__DIR__)))
                     )
  @baseline_ref "f20ac60"

  # ============================================================================
  # Story Definitions
  # ============================================================================

  @addition_story %{
    title: "Addition",
    description: "As a user, I can add two numbers and see the result",
    priority: 1,
    status: :in_progress
  }

  @addition_criteria [
    "Given I am on the addition page, when I enter two valid numbers and submit, then I see their sum",
    "Given I am on the addition page, when I enter non-numeric input, then I see a validation error",
    "Given I am on the addition page, when I enter decimal numbers, then the sum handles decimals correctly"
  ]

  @subtraction_story %{
    title: "Subtraction",
    description: "As a user, I can subtract two numbers and see the result",
    priority: 2,
    status: :in_progress
  }

  @subtraction_criteria [
    "Given I am on the subtraction page, when I enter two valid numbers and submit, then I see their difference",
    "Given I am on the subtraction page, when I subtract a larger number from a smaller one, then I see a negative result",
    "Given I am on the subtraction page, when I enter non-numeric input, then I see a validation error"
  ]

  @history_story %{
    title: "Calculation History",
    description: "As a user, I can view a history of my past calculations",
    priority: 3,
    status: :in_progress
  }

  @history_criteria [
    "Given I have performed calculations, when I view the history page, then I see a list of past calculations with operation, operands, and result",
    "Given I have no past calculations, when I view the history page, then I see an empty state message",
    "Given I perform a new calculation, when I view the history page, then the new calculation appears at the top"
  ]

  @clear_history_story %{
    title: "Clear History",
    description: "As a user, I can clear my calculation history",
    priority: 4,
    status: :in_progress
  }

  @clear_history_criteria [
    "Given I have past calculations, when I click clear history, then all my calculations are removed",
    "Given I have cleared my history, when I view the history page, then I see an empty state message"
  ]

  # ============================================================================
  # Project Checkout
  # ============================================================================

  @doc """
  Exports the math_test_project at its pre-setup baseline into target_dir.

  Uses `git archive` to get a clean copy without .git metadata.
  Returns the project directory path.
  """
  def checkout_scenario_project(target_dir) do
    project_dir = Path.join(target_dir, "math_test_project")
    File.mkdir_p!(project_dir)

    {_, 0} =
      System.cmd(
        "sh",
        ["-c", "git archive #{@baseline_ref} | tar -x -C #{project_dir}"],
        cd: @math_project_repo
      )

    project_dir
  end

  # ============================================================================
  # DB Fixtures
  # ============================================================================

  @doc """
  Creates the base scenario state needed for phases 1-3.

  Returns scope with user, account, project, plus all 4 stories with criteria.
  Also inserts a ClientUser with a valid OAuth token so `OAuthClient.authenticated?/0` passes.
  Does NOT set cwd/environment — call `put_scenario_environment/2` with a project dir.
  """
  def scenario_base_fixture do
    scope = full_scope_fixture()
    stories = create_scenario_stories(scope)
    ensure_authenticated_client_user()

    %{scope: scope, stories: stories}
  end

  defp ensure_authenticated_client_user do
    CodeMySpec.Repo.insert!(%ClientUser{
      email: "scenario-test@example.com",
      oauth_token: "test-token-#{System.unique_integer([:positive])}",
      oauth_refresh_token: "test-refresh-token",
      oauth_expires_at: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    })
  end

  @doc """
  Sets up the scope's environment to point at a test project directory.
  """
  def put_scenario_environment(scope, project_dir) do
    scope
    |> Map.put(:cwd, project_dir)
    |> Map.put(:environment, Environment.new(:local, project_dir))
  end

  @doc """
  Creates a session fixture for a specific agent task phase.
  """
  def scenario_session_fixture(scope, task_module, attrs \\ %{}) do
    import CodeMySpec.SessionsFixtures

    session_fixture(scope, Map.merge(%{type: task_module, status: :active}, attrs))
  end

  # ============================================================================
  # Story Creation
  # ============================================================================

  defp create_scenario_stories(scope) do
    addition = create_story_with_criteria(scope, @addition_story, @addition_criteria)
    subtraction = create_story_with_criteria(scope, @subtraction_story, @subtraction_criteria)
    history = create_story_with_criteria(scope, @history_story, @history_criteria)
    clear_history = create_story_with_criteria(scope, @clear_history_story, @clear_history_criteria)

    %{
      addition: addition,
      subtraction: subtraction,
      history: history,
      clear_history: clear_history
    }
  end

  defp create_story_with_criteria(scope, story_attrs, criteria_descriptions) do
    story = story_fixture(scope, story_attrs)

    criteria =
      Enum.map(criteria_descriptions, fn description ->
        criterion_fixture(scope, story, %{description: description})
      end)

    %{story: story, criteria: criteria}
  end
end
