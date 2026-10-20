defmodule CodeMySpec.Qa.BlockedScenarioTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Qa.{IssueQaAttempt, QaAttempt, Scenario}

  test "blocked scenarios require a valid blocker issue id" do
    base = %{name: "Live check", status: "blocked", observation: "Service unavailable"}

    for blocker <- [nil, "", "not-an-issue-id"] do
      changeset = Scenario.changeset(Map.put(base, :blocker_issue_id, blocker))
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :blocker_issue_id)
    end

    id = Ecto.UUID.generate()
    changeset = Scenario.changeset(Map.put(base, :blocker_issue_id, id))
    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :blocker_issue_id) == id
  end

  test "story and issue attempts reject a pass containing failed or blocked scenarios" do
    for schema <- [QaAttempt, IssueQaAttempt], status <- [:fail, :blocked] do
      blocker = Ecto.UUID.generate()

      attrs = %{
        story_id: 1,
        issue_id: Ecto.UUID.generate(),
        status: :pass,
        submitted_at: DateTime.utc_now(),
        issue_ids: [blocker],
        scenarios: [
          %{
            name: "Live check",
            status: status,
            observation: "Could not confirm the behavior",
            blocker_issue_id: blocker
          }
        ]
      }

      changeset = schema.changeset(attrs)
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :status)
    end
  end

  test "partial attempts retain the blocker in their issue list" do
    blocker = Ecto.UUID.generate()

    for schema <- [QaAttempt, IssueQaAttempt] do
      attrs = %{
        story_id: 1,
        issue_id: Ecto.UUID.generate(),
        status: :partial,
        submitted_at: DateTime.utc_now(),
        issue_ids: [blocker],
        scenarios: [
          %{
            name: "Live check",
            status: :blocked,
            observation: "Service unavailable",
            blocker_issue_id: blocker
          }
        ]
      }

      assert schema.changeset(attrs).valid?
      refute schema.changeset(%{attrs | issue_ids: []}).valid?
    end
  end
end
