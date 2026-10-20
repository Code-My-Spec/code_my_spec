defmodule CodeMySpec.Issues.AnIssueRecordsWhenItWasAcceptedAndClosedTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Issues.Issue

  defp issue(attrs),
    do:
      struct(
        Issue,
        Map.merge(%{status: :incoming, title: "t", severity: :medium, description: "d"}, attrs)
      )

  test "accepting stamps accepted_at once" do
    cs = Issue.status_changeset(issue(%{}), %{status: :accepted})
    assert %DateTime{} = Ecto.Changeset.get_change(cs, :accepted_at)

    earlier = ~U[2026-01-01 00:00:00.000000Z]
    cs = Issue.changeset(issue(%{status: :incoming, accepted_at: earlier}), %{status: :accepted})
    assert Ecto.Changeset.get_field(cs, :accepted_at) == earlier
  end

  test "resolving or dismissing stamps closed_at, and reopening clears it" do
    for status <- [:resolved, :dismissed] do
      cs = Issue.changeset(issue(%{status: :accepted}), %{status: status})
      assert %DateTime{} = Ecto.Changeset.get_change(cs, :closed_at)
    end

    closed = issue(%{status: :resolved, closed_at: ~U[2026-01-01 00:00:00.000000Z]})
    cs = Issue.changeset(closed, %{status: :incoming})
    assert Ecto.Changeset.get_field(cs, :closed_at) == nil
  end

  test "an edit that does not change status leaves the times alone" do
    cs = Issue.changeset(issue(%{status: :accepted}), %{title: "renamed"})
    refute Ecto.Changeset.changed?(cs, :accepted_at)
    refute Ecto.Changeset.changed?(cs, :closed_at)
  end
end
