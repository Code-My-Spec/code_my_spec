defmodule CodeMySpec.IssuesFixtures do
  @moduledoc """
  Test fixtures for issues.
  """

  alias CodeMySpec.Issues
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphInputs

  def issue_fixture(scope, attrs \\ %{}) do
    defaults = %{
      title: "Test issue #{System.unique_integer([:positive])}",
      severity: :medium,
      description: "A test issue description",
      scope: :app
    }

    {:ok, issue} = Issues.create_issue(scope, Map.merge(defaults, attrs))
    issue
  end

  @doc """
  Mark `issue` resolved directly, announcing the graph change
  `Issues.resolve_issue/3` normally fires through its own `broadcast/2`.

  `Issues.resolve_issue/3` itself refuses a story-owned issue with no
  working-copy assignment ("must go through shared story QA and
  promotion") — correct for the real surface, but a scenario setting up a
  cross-story blocker's resolved *state* (story 1116, criterion 2196) is
  not simulating that other story's own promotion pipeline, which is
  criterion 2101's scenario, not this one.
  """
  def resolved_issue_fixture(scope, issue, resolution \\ "Fixed.") do
    {:ok, issue} =
      issue
      |> Ecto.Changeset.change(status: :resolved, resolution: resolution)
      |> Repo.update()

    GraphInputs.announce(scope, "Issues", [], :project_wide)
    issue
  end

  @doc """
  Re-triage `issue` onto `story_id`, announcing the graph change the way
  `update_issue` does through its own `broadcast/2`. A spex scenario needs
  the re-triaged *state* to drive the surface under test; re-triage itself
  is a product decision, not something the scenario is specifying.
  """
  def retriaged_issue_fixture(scope, issue, story_id) do
    {:ok, issue} = Issues.update_issue(scope, issue, %{story_id: story_id})
    issue
  end
end
