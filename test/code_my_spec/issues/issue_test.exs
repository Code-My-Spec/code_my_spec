defmodule CodeMySpec.Issues.IssueTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Issues.Issue
  import CodeMySpec.UsersFixtures

  describe "changeset/2" do
    test "returns valid changeset when required fields are provided" do
      changeset = Issue.changeset(%Issue{}, valid_attrs())

      assert changeset.valid?
    end

    test "returns invalid changeset when title is missing" do
      changeset = Issue.changeset(%Issue{}, valid_attrs() |> Map.delete(:title))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).title
    end

    test "returns invalid changeset when severity is missing" do
      changeset = Issue.changeset(%Issue{}, valid_attrs() |> Map.delete(:severity))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).severity
    end

    test "returns invalid changeset when description is missing" do
      changeset = Issue.changeset(%Issue{}, valid_attrs() |> Map.delete(:description))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).description
    end

    test "validates severity values" do
      changeset = Issue.changeset(%Issue{}, valid_attrs(%{severity: :not_a_severity}))

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).severity
    end

    test "validates scope values" do
      changeset = Issue.changeset(%Issue{}, valid_attrs(%{scope: :not_a_scope}))

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).scope
    end

    test "defaults scope to :app" do
      changeset = Issue.changeset(%Issue{}, valid_attrs() |> Map.delete(:scope))

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :scope) == :app
    end

    test "defaults status to :incoming" do
      changeset = Issue.changeset(%Issue{}, valid_attrs() |> Map.delete(:status))

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :status) == :incoming
    end

    test "enforces unique title per project + story_id" do
      scope = full_scope_fixture()

      # Use an explicit story_id so the unique index fires (PostgreSQL treats NULL as distinct)
      attrs = %{title: "Duplicate Issue", severity: :high, description: "test", story_id: 42}

      {:ok, _} =
        %Issue{}
        |> Issue.changeset(attrs)
        |> Ecto.Changeset.put_change(:project_id, scope.active_project.id)
        |> Ecto.Changeset.put_change(:account_id, scope.active_account.id)
        |> CodeMySpec.Repo.insert()

      {:error, changeset} =
        %Issue{}
        |> Issue.changeset(attrs)
        |> Ecto.Changeset.put_change(:project_id, scope.active_project.id)
        |> Ecto.Changeset.put_change(:account_id, scope.active_account.id)
        |> CodeMySpec.Repo.insert()

      assert "has already been taken" in errors_on(changeset).title
    end

    test "allows nil story_id (for braindump issues)" do
      changeset = Issue.changeset(%Issue{}, valid_attrs(%{story_id: nil}))

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :story_id) == nil
    end
  end

  describe "status_changeset/2" do
    test "allows incoming → accepted transition" do
      issue = %Issue{status: :incoming}
      changeset = Issue.status_changeset(issue, %{status: :accepted})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :status) == :accepted
    end

    test "allows incoming → dismissed transition (requires resolution)" do
      issue = %Issue{status: :incoming}
      changeset = Issue.status_changeset(issue, %{status: :dismissed, resolution: "Not reproducible"})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :status) == :dismissed
      assert Ecto.Changeset.get_field(changeset, :resolution) == "Not reproducible"
    end

    test "allows accepted → resolved transition (requires resolution)" do
      issue = %Issue{status: :accepted}
      changeset = Issue.status_changeset(issue, %{status: :resolved, resolution: "Fixed in PR #42"})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :status) == :resolved
      assert Ecto.Changeset.get_field(changeset, :resolution) == "Fixed in PR #42"
    end

    test "rejects invalid transitions (e.g., dismissed → accepted)" do
      issue = %Issue{status: :dismissed}
      changeset = Issue.status_changeset(issue, %{status: :accepted})

      refute changeset.valid?
      assert errors_on(changeset).status != []
    end

    test "only casts status and resolution fields" do
      issue = %Issue{status: :incoming}

      changeset =
        Issue.status_changeset(issue, %{
          status: :accepted,
          title: "Injected title",
          severity: :critical
        })

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :title)
      refute Map.has_key?(changeset.changes, :severity)
    end
  end

  describe "severity_index/1" do
    test "critical returns 0" do
      assert Issue.severity_index(:critical) == 0
    end

    test "high returns 1" do
      assert Issue.severity_index(:high) == 1
    end

    test "medium returns 2" do
      assert Issue.severity_index(:medium) == 2
    end

    test "low returns 3" do
      assert Issue.severity_index(:low) == 3
    end

    test "info returns 4" do
      assert Issue.severity_index(:info) == 4
    end
  end

  # Fixture functions

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        title: "Issue #{System.unique_integer([:positive])}",
        severity: :high,
        scope: :app,
        description: "Something is broken and needs attention"
      },
      overrides
    )
  end
end
