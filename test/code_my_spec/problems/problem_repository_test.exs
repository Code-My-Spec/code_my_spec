defmodule CodeMySpec.Problems.ProblemRepositoryTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures

  alias CodeMySpec.Problems.{Problem, ProblemRepository}
  alias CodeMySpec.Repo

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope)
    scope = user_scope_fixture(user, account, project)

    %{scope: scope, project: project, user: user, account: account}
  end

  describe "list_project_problems/2" do
    test "returns empty list when no problems exist for project", %{scope: scope} do
      result = ProblemRepository.list_project_problems(scope, [])

      assert result == []
    end

    test "returns all problems scoped to the project when no filters provided", %{scope: scope} do
      problem1 = problem_fixture(scope, %{message: "Problem 1"})
      problem2 = problem_fixture(scope, %{message: "Problem 2"})

      result = ProblemRepository.list_project_problems(scope, [])

      assert length(result) == 2
      problem_ids = Enum.map(result, & &1.id)
      assert problem1.id in problem_ids
      assert problem2.id in problem_ids
    end

    test "filters out problems from other projects", %{scope: scope} do
      problem1 = problem_fixture(scope, %{message: "My problem"})

      # Create problem in different project
      other_user = user_fixture()
      other_account = account_with_owner_fixture(other_user)
      other_scope = user_scope_fixture(other_user, other_account)
      other_project = project_fixture(other_scope)
      other_scope = user_scope_fixture(other_user, other_account, other_project)
      _other_problem = problem_fixture(other_scope, %{message: "Other problem"})

      result = ProblemRepository.list_project_problems(scope, [])

      assert length(result) == 1
      assert hd(result).id == problem1.id
    end

    test "filters by source when source filter provided", %{scope: scope} do
      credo_problem = problem_fixture(scope, %{source: "credo"})

      result = ProblemRepository.list_project_problems(scope, source: "credo")

      assert length(result) == 1
      assert hd(result).id == credo_problem.id
    end

    test "filters by source_type when source_type filter provided", %{scope: scope} do
      static_problem = problem_fixture(scope, %{source_type: :static_analysis})
      _test_problem = problem_fixture(scope, %{source_type: :test})

      result = ProblemRepository.list_project_problems(scope, source_type: :static_analysis)

      assert length(result) == 1
      assert hd(result).id == static_problem.id
    end

    test "filters by file_path when file_path filter provided (supports pattern matching)", %{
      scope: scope
    } do
      lib_problem = problem_fixture(scope, %{file_path: "lib/my_app/accounts.ex"})
      _test_problem = problem_fixture(scope, %{file_path: "test/my_app/accounts_test.exs"})

      result = ProblemRepository.list_project_problems(scope, file_path: "lib/%")

      assert length(result) == 1
      assert hd(result).id == lib_problem.id
    end

    test "filters by category when category filter provided", %{scope: scope} do
      readability_problem = problem_fixture(scope, %{category: "readability"})
      _warning_problem = problem_fixture(scope, %{category: "warning"})

      result = ProblemRepository.list_project_problems(scope, category: "readability")

      assert length(result) == 1
      assert hd(result).id == readability_problem.id
    end

    test "filters by severity when severity filter provided", %{scope: scope} do
      error_problem = problem_fixture(scope, %{severity: :error})
      _warning_problem = problem_fixture(scope, %{severity: :warning})

      result = ProblemRepository.list_project_problems(scope, severity: :error)

      assert length(result) == 1
      assert hd(result).id == error_problem.id
    end

    test "supports multiple filters combined", %{scope: scope} do
      matching_problem =
        problem_fixture(scope, %{
          source: "credo",
          severity: :error,
          category: "readability"
        })

      _wrong_severity = problem_fixture(scope, %{source: "credo", severity: :warning})

      result =
        ProblemRepository.list_project_problems(scope,
          source: "credo",
          severity: :error,
          category: "readability"
        )

      assert length(result) == 1
      assert hd(result).id == matching_problem.id
    end

    test "orders results by severity (error, warning, info) then file path", %{scope: scope} do
      # Create problems in specific order to test sorting
      _info1 = problem_fixture(scope, %{severity: :info, file_path: "lib/b.ex"})
      _error1 = problem_fixture(scope, %{severity: :error, file_path: "lib/b.ex"})
      _warning1 = problem_fixture(scope, %{severity: :warning, file_path: "lib/a.ex"})
      _error2 = problem_fixture(scope, %{severity: :error, file_path: "lib/a.ex"})

      result = ProblemRepository.list_project_problems(scope, [])

      assert length(result) == 4
      # Errors first (sorted by file_path)
      assert Enum.at(result, 0).severity == :error
      assert Enum.at(result, 0).file_path == "lib/a.ex"
      assert Enum.at(result, 1).severity == :error
      assert Enum.at(result, 1).file_path == "lib/b.ex"
      # Warnings second
      assert Enum.at(result, 2).severity == :warning
      # Info last
      assert Enum.at(result, 3).severity == :info
    end
  end

  describe "create_problems/2" do
    test "successfully inserts valid problems", %{scope: scope} do
      problems = [
        valid_problem_attrs(%{message: "Problem 1"}),
        valid_problem_attrs(%{message: "Problem 2"})
      ]

      assert {:ok, inserted_problems} = ProblemRepository.create_problems(scope, problems)

      assert length(inserted_problems) == 2
      assert Enum.at(inserted_problems, 0).message == "Problem 1"
      assert Enum.at(inserted_problems, 1).message == "Problem 2"

      # Verify database persistence
      db_problems = Repo.all(Problem)
      assert length(db_problems) == 2
    end

    test "associates problems with project from scope", %{scope: scope} do
      problems = [valid_problem_attrs(%{message: "Test problem"})]

      assert {:ok, inserted_problems} = ProblemRepository.create_problems(scope, problems)

      assert hd(inserted_problems).project_id == scope.active_project_id
    end

    test "rejects problems without required fields", %{scope: scope} do
      problems = [
        %{message: "Invalid - missing required fields"}
      ]

      assert {:error, _changeset} = ProblemRepository.create_problems(scope, problems)

      # Verify nothing was inserted
      assert Repo.all(Problem) == []
    end

    test "handles empty list gracefully", %{scope: scope} do
      assert {:ok, []} = ProblemRepository.create_problems(scope, [])

      assert Repo.all(Problem) == []
    end

    test "rolls back transaction on validation errors", %{scope: scope} do
      problems = [
        valid_problem_attrs(%{message: "Valid problem"}),
        %{message: "Invalid - missing fields"}
      ]

      assert {:error, _changeset} = ProblemRepository.create_problems(scope, problems)

      # Verify transaction rollback - no problems should be inserted
      assert Repo.all(Problem) == []
    end
  end

  describe "replace_project_problems/2" do
    test "removes all existing problems and stores new ones atomically", %{scope: scope} do
      # Create initial problems
      _existing1 = problem_fixture(scope, %{message: "Old problem 1"})
      _existing2 = problem_fixture(scope, %{message: "Old problem 2"})

      # Verify initial state
      assert length(Repo.all(Problem)) == 2

      # Replace with new problems
      new_problems = [
        valid_problem_attrs(%{message: "New problem 1"}),
        valid_problem_attrs(%{message: "New problem 2"}),
        valid_problem_attrs(%{message: "New problem 3"})
      ]

      assert {:ok, replaced_problems} =
               ProblemRepository.replace_project_problems(scope, new_problems)

      assert length(replaced_problems) == 3

      # Verify database state
      all_problems = Repo.all(Problem)
      assert length(all_problems) == 3
      assert Enum.all?(all_problems, &(&1.message =~ "New problem"))
    end

    test "rolls back both delete and insert on error", %{scope: scope} do
      # Create initial problems
      existing = problem_fixture(scope, %{message: "Existing problem"})

      # Try to replace with invalid data
      new_problems = [
        valid_problem_attrs(%{message: "Valid problem"}),
        %{message: "Invalid - missing fields"}
      ]

      assert {:error, _changeset} =
               ProblemRepository.replace_project_problems(scope, new_problems)

      # Verify rollback - original problem should still exist
      all_problems = Repo.all(Problem)
      assert length(all_problems) == 1
      assert hd(all_problems).id == existing.id
    end

    test "handles transition from many problems to zero", %{scope: scope} do
      # Create initial problems
      problem_list_fixture(scope, 5)

      assert length(Repo.all(Problem)) == 5

      # Replace with empty list
      assert {:ok, []} = ProblemRepository.replace_project_problems(scope, [])

      # Verify all problems are deleted
      assert Repo.all(Problem) == []
    end

    test "handles transition from zero problems to many", %{scope: scope} do
      # Start with no problems
      assert Repo.all(Problem) == []

      # Add multiple problems
      new_problems = [
        valid_problem_attrs(%{message: "Problem 1"}),
        valid_problem_attrs(%{message: "Problem 2"}),
        valid_problem_attrs(%{message: "Problem 3"})
      ]

      assert {:ok, inserted_problems} =
               ProblemRepository.replace_project_problems(scope, new_problems)

      assert length(inserted_problems) == 3
      assert length(Repo.all(Problem)) == 3
    end

    test "maintains problems for other projects unchanged", %{scope: scope} do
      # Create problems in current project
      _my_problem = problem_fixture(scope, %{message: "My problem"})

      # Create problems in different project
      other_user = user_fixture()
      other_account = account_with_owner_fixture(other_user)
      other_scope = user_scope_fixture(other_user, other_account)
      other_project = project_fixture(other_scope)
      other_scope = user_scope_fixture(other_user, other_account, other_project)
      other_problem = problem_fixture(other_scope, %{message: "Other problem"})

      # Verify initial state
      assert length(Repo.all(Problem)) == 2

      # Replace problems in current project
      new_problems = [
        valid_problem_attrs(%{message: "New problem"})
      ]

      assert {:ok, _replaced} = ProblemRepository.replace_project_problems(scope, new_problems)

      # Verify other project's problem is unchanged
      assert length(Repo.all(Problem)) == 2
      assert Repo.get(Problem, other_problem.id) != nil
    end
  end

  describe "replace_problems_for_files/3" do
    test "replaces only matching files, leaves others intact", %{scope: scope} do
      # Create problems across different files
      keep_problem = problem_fixture(scope, %{file_path: "lib/app/keep.ex", message: "Keep me"})

      _replace1 =
        problem_fixture(scope, %{file_path: "lib/app/accounts.ex", message: "Old accounts"})

      _replace2 =
        problem_fixture(scope, %{file_path: "lib/app/users.ex", message: "Old users"})

      assert length(Repo.all(Problem)) == 3

      new_problems = [
        valid_problem_attrs(%{file_path: "lib/app/accounts.ex", message: "New accounts"}),
        valid_problem_attrs(%{file_path: "lib/app/users.ex", message: "New users"})
      ]

      assert {:ok, inserted} =
               ProblemRepository.replace_problems_for_files(
                 scope,
                 ["lib/app/accounts.ex", "lib/app/users.ex"],
                 new_problems
               )

      assert length(inserted) == 2

      all = Repo.all(Problem)
      assert length(all) == 3

      # The untouched file's problem should still be there
      assert Repo.get(Problem, keep_problem.id) != nil

      messages = Enum.map(all, & &1.message)
      assert "Keep me" in messages
      assert "New accounts" in messages
      assert "New users" in messages
      refute "Old accounts" in messages
      refute "Old users" in messages
    end

    test "empty file_paths is a no-op", %{scope: scope} do
      existing = problem_fixture(scope, %{message: "Existing"})

      assert {:ok, []} =
               ProblemRepository.replace_problems_for_files(scope, [], [
                 valid_problem_attrs(%{message: "Should not appear"})
               ])

      all = Repo.all(Problem)
      assert length(all) == 1
      assert hd(all).id == existing.id
    end

    test "empty problems list clears files' problems", %{scope: scope} do
      _target = problem_fixture(scope, %{file_path: "lib/app/target.ex", message: "Gone"})
      keep = problem_fixture(scope, %{file_path: "lib/app/other.ex", message: "Stay"})

      assert {:ok, []} =
               ProblemRepository.replace_problems_for_files(
                 scope,
                 ["lib/app/target.ex"],
                 []
               )

      all = Repo.all(Problem)
      assert length(all) == 1
      assert hd(all).id == keep.id
    end

    test "atomic rollback on invalid data", %{scope: scope} do
      existing =
        problem_fixture(scope, %{file_path: "lib/app/accounts.ex", message: "Original"})

      invalid_problems = [
        valid_problem_attrs(%{file_path: "lib/app/accounts.ex", message: "Valid"}),
        %{message: "Invalid - missing fields"}
      ]

      assert {:error, _changeset} =
               ProblemRepository.replace_problems_for_files(
                 scope,
                 ["lib/app/accounts.ex"],
                 invalid_problems
               )

      # Original problem should still exist due to rollback
      all = Repo.all(Problem)
      assert length(all) == 1
      assert hd(all).id == existing.id
    end
  end

  describe "clear_project_problems/1" do
    test "deletes all problems for the project", %{scope: scope} do
      problem_list_fixture(scope, 3)

      assert length(Repo.all(Problem)) == 3

      assert {:ok, count} = ProblemRepository.clear_project_problems(scope)

      assert count == 3
      assert Repo.all(Problem) == []
    end

    test "returns count of deleted records", %{scope: scope} do
      problem_list_fixture(scope, 5)

      assert {:ok, 5} = ProblemRepository.clear_project_problems(scope)
    end

    test "does not affect problems from other projects", %{scope: scope} do
      # Create problems in current project
      problem_list_fixture(scope, 2)

      # Create problems in different project
      other_user = user_fixture()
      other_account = account_with_owner_fixture(other_user)
      other_scope = user_scope_fixture(other_user, other_account)
      other_project = project_fixture(other_scope)
      other_scope = user_scope_fixture(other_user, other_account, other_project)
      other_problem = problem_fixture(other_scope, %{message: "Other problem"})

      assert length(Repo.all(Problem)) == 3

      assert {:ok, 2} = ProblemRepository.clear_project_problems(scope)

      # Verify only current project's problems were deleted
      remaining = Repo.all(Problem)
      assert length(remaining) == 1
      assert hd(remaining).id == other_problem.id
    end

    test "handles case when no problems exist", %{scope: scope} do
      assert Repo.all(Problem) == []

      assert {:ok, 0} = ProblemRepository.clear_project_problems(scope)

      assert Repo.all(Problem) == []
    end
  end

  describe "clear_problems_for_source/3 with :all file scope" do
    test "clears only the matching source project-wide", %{scope: scope} do
      qa1 = problem_fixture(scope, %{source: "qa_validation", file_path: "lib/a.ex"})
      qa2 = problem_fixture(scope, %{source: "qa_validation", file_path: "lib/b.ex"})
      credo = problem_fixture(scope, %{source: "credo", file_path: "lib/a.ex"})

      assert {:ok, 2} =
               ProblemRepository.clear_problems_for_source(
                 scope,
                 [source: "qa_validation"],
                 :all
               )

      remaining_ids = Repo.all(Problem) |> Enum.map(& &1.id)
      assert remaining_ids == [credo.id]
      refute qa1.id in remaining_ids
      refute qa2.id in remaining_ids
    end

    test "does not affect problems from other projects", %{scope: scope} do
      problem_fixture(scope, %{source: "qa_validation"})

      other_user = user_fixture()
      other_account = account_with_owner_fixture(other_user)
      other_scope = user_scope_fixture(other_user, other_account)
      other_project = project_fixture(other_scope)
      other_scope = user_scope_fixture(other_user, other_account, other_project)
      other_problem = problem_fixture(other_scope, %{source: "qa_validation"})

      assert {:ok, 1} =
               ProblemRepository.clear_problems_for_source(
                 scope,
                 [source: "qa_validation"],
                 :all
               )

      remaining = Repo.all(Problem)
      assert length(remaining) == 1
      assert hd(remaining).id == other_problem.id
    end
  end

  describe "replace_problems_for_components/4" do
    test "replaces problems for specific components and source", %{scope: scope} do
      component = component_fixture(scope)

      _old =
        problem_fixture(scope, %{
          source: "credo",
          component_id: component.id,
          message: "Old credo"
        })

      keep =
        problem_fixture(scope, %{
          source: "sobelow",
          component_id: component.id,
          message: "Keep sobelow"
        })

      new_problems = [
        valid_problem_attrs(%{
          source: "credo",
          component_id: component.id,
          message: "New credo"
        })
      ]

      assert {:ok, [inserted]} =
               ProblemRepository.replace_problems_for_components(
                 scope,
                 [component.id],
                 "credo",
                 new_problems
               )

      assert inserted.message == "New credo"

      all = Repo.all(Problem)
      assert length(all) == 2
      messages = Enum.map(all, & &1.message)
      assert "New credo" in messages
      assert "Keep sobelow" in messages
      assert Repo.get(Problem, keep.id) != nil
    end

    test "empty component_ids is a no-op", %{scope: scope} do
      _existing = problem_fixture(scope)

      assert {:ok, []} =
               ProblemRepository.replace_problems_for_components(scope, [], "credo", [])

      assert length(Repo.all(Problem)) == 1
    end

    test "clears problems when new list is empty", %{scope: scope} do
      component = component_fixture(scope)

      _old =
        problem_fixture(scope, %{source: "credo", component_id: component.id})

      assert {:ok, []} =
               ProblemRepository.replace_problems_for_components(
                 scope,
                 [component.id],
                 "credo",
                 []
               )

      assert Repo.all(Problem) == []
    end
  end

  describe "delete_problems_for_components/2" do
    test "deletes all problems for given component IDs", %{scope: scope} do
      comp_a = component_fixture(scope)
      comp_b = component_fixture(scope)

      _pa = problem_fixture(scope, %{component_id: comp_a.id, message: "A"})
      _pb = problem_fixture(scope, %{component_id: comp_b.id, message: "B"})
      keep = problem_fixture(scope, %{message: "No component"})

      assert {:ok, 2} =
               ProblemRepository.delete_problems_for_components(scope, [comp_a.id, comp_b.id])

      all = Repo.all(Problem)
      assert length(all) == 1
      assert hd(all).id == keep.id
    end

    test "empty list is a no-op", %{scope: scope} do
      _existing = problem_fixture(scope)

      assert {:ok, 0} = ProblemRepository.delete_problems_for_components(scope, [])
      assert length(Repo.all(Problem)) == 1
    end
  end
end
