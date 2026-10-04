defmodule CodeMySpec.Agents.Main.GapRepositoryTest do
  @moduledoc """
  The counting is the part story 1058's criterion 3330 turns on, and it is the
  part a spex reads only through an issue title — so it is checked here as well,
  where a wrong count is a wrong number rather than a missing word.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.Main.GapRepository

  test "one gap is one row, and every recurrence is counted" do
    scope = user_scope_fixture()
    project = CodeMySpec.ProjectsFixtures.project_fixture(scope)

    {:ok, first} = GapRepository.record(project.id, "product", "a thing")
    {:ok, second} = GapRepository.record(project.id, "product", "a thing")
    {:ok, third} = GapRepository.record(project.id, "product", "a thing")

    assert {first.occurrences, second.occurrences, third.occurrences} == {1, 2, 3}
    assert first.id == second.id and second.id == third.id
  end

  # The unique index on `capability` is a btree, whose entries cap near 2.7KB.
  # Past that the insert raised rather than returned; `note_gap/3` rescued it.
  test "a capability too long to index is refused, not raised" do
    project = CodeMySpec.ProjectsFixtures.project_fixture(user_scope_fixture())
    capability = 5_000 |> :crypto.strong_rand_bytes() |> Base.encode64()

    assert {:error, changeset} = GapRepository.record(project.id, "coding", capability)
    assert changeset.errors[:capability]
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

  describe "the issue title a gap is filed under" do
    # `issues.title` is varchar(255) and `capability_gaps.capability` is text.
    # `answer_notification` asks its caller for prose, so the natural input
    # overflows: a ~300-character `worked_around` raised 22001 on 2026-09-23 and
    # was reported to the caller as the whole answer failing, after the answer
    # had already committed.
    test "fits the column no matter how long the capability is" do
      capability = String.duplicate("read the promote log itself, which it cannot ", 40)

      title = CodeMySpec.Agents.Main.gap_title(%{role: "coding", capability: capability})

      assert byte_size(title) <= 255,
             "issues.title is varchar(255); a title longer than that does not " <>
               "get rejected, it raises 22001 and takes the answer down with it"

      assert String.starts_with?(title, "The coding role cannot: ")
      assert String.ends_with?(title, "…")
    end

    test "leaves a capability that already fits exactly as it is" do
      title = CodeMySpec.Agents.Main.gap_title(%{role: "qa", capability: "read its own tool set"})

      assert title == "The qa role cannot: read its own tool set"
      refute String.ends_with?(title, "…")
    end

    test "cuts on a character boundary, not a byte one" do
      capability = String.duplicate("é", 300)

      title = CodeMySpec.Agents.Main.gap_title(%{role: "product", capability: capability})

      assert byte_size(title) <= 255
      assert String.valid?(title), "a byte-wise cut would split a two-byte é in half"
    end
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
