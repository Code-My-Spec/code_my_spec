defmodule CodeMySpec.IssuesFixtures do
  @moduledoc """
  Test fixtures for issues.
  """

  alias CodeMySpec.Issues

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
end
