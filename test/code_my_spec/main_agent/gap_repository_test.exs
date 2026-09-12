defmodule CodeMySpec.MainAgent.GapRepositoryTest do
  @moduledoc """
  The counting is the part story 1058's criterion 3330 turns on, and it is the
  part a spex reads only through an issue title — so it is checked here as well,
  where a wrong count is a wrong number rather than a missing word.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.MainAgent.GapRepository

  test "one gap is one row, and every recurrence is counted" do
    scope = user_scope_fixture()
    project = CodeMySpec.ProjectsFixtures.project_fixture(scope)

    {:ok, first} = GapRepository.record(project.id, "product", "a thing")
    {:ok, second} = GapRepository.record(project.id, "product", "a thing")
    {:ok, third} = GapRepository.record(project.id, "product", "a thing")

    assert {first.occurrences, second.occurrences, third.occurrences} == {1, 2, 3}
    assert first.id == second.id and second.id == third.id
  end

  test "the issue attached to a gap survives the next recurrence" do
    scope = full_scope_fixture()

    {:ok, gap} = GapRepository.record(scope.active_project_id, "product", "a thing")

    # A real issue: `capability_gaps.issue_id` is a foreign key, which is the
    # point — a gap cannot claim to have been filed as something that is not
    # there.
    {:ok, issue} =
      CodeMySpec.Issues.create_issue(scope, %{
        title: "the product role cannot do a thing",
        severity: :medium,
        scope: :framework,
        description: "filed once"
      })

    :ok = GapRepository.attach_issue(gap, issue.id)

    {:ok, again} = GapRepository.record(scope.active_project_id, "product", "a thing")

    assert again.issue_id,
           "the upsert lost the issue this gap was already filed as, so the next " <>
             "recurrence files a second one"

    assert again.occurrences == 2
  end

  test "a different role's gap is a different row" do
    scope = user_scope_fixture()
    project = CodeMySpec.ProjectsFixtures.project_fixture(scope)

    {:ok, product} = GapRepository.record(project.id, "product", "a thing")
    {:ok, coding} = GapRepository.record(project.id, "coding", "a thing")

    refute product.id == coding.id
    assert coding.occurrences == 1
  end
end
