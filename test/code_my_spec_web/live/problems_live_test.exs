defmodule CodeMySpecWeb.ProblemsLiveTest do
  @moduledoc """
  The problems index, and what it does with a message that is not one line.

  A row is one problem and the table is for finding the one you want. Measured
  on this project: 360 of 724 messages fit in 80 characters, but 15 run past
  400, the longest is 4,393, and 28 contain newlines — a spex failure carries
  its whole stack trace. Rendered whole, one of those is taller than the rest
  of the table put together.

  The first line is what identifies a problem; the rest is evidence, and the
  table is not where evidence is read.
  """

  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.DevicesFixtures

  import Phoenix.LiveViewTest

  alias CodeMySpec.Problems
  alias CodeMySpec.WorkingCopies

  setup [:register_log_in_setup_account]

  setup %{scope: scope, account: account} do
    project = CodeMySpec.ProjectsFixtures.project_fixture(scope, account_id: account.id)
    scope = %{scope | active_project_id: project.id, active_project: project}

    {:ok, harness} =
      WorkingCopies.issue(scope, nil,
        label: "the harness at /repo/main",
        device: device_fixture(scope)
      )

    %{project: project, scope: %{scope | active_working_copy_id: harness.id}}
  end

  defp record(scope, message) do
    {:ok, _} =
      Problems.create_problems(scope, [
        %{
          severity: :error,
          source: "credo",
          source_type: :static_analysis,
          file_path: "lib/example.ex",
          line: 12,
          message: message,
          category: "readability"
        }
      ])
  end

  defp path(project), do: "/app/projects/#{project.id}/problems"

  describe "a message that runs long" do
    test "only its first line is shown", %{conn: conn, scope: scope, project: project} do
      record(scope, "The step never reported done\n  stack trace line 1\n  stack trace line 2")

      {:ok, view, _html} = live(conn, path(project))

      assert has_element?(view, "[data-test='problem-message']")

      text = view |> element("[data-test='problem-message-line']") |> render()

      assert text =~ "The step never reported done"

      refute text =~ "stack trace line 2",
             "the table is for finding a problem, not for reading its evidence"
    end

    test "a single very long line is capped", %{conn: conn, scope: scope, project: project} do
      long = String.duplicate("alias ordering is wrong here ", 60)

      record(scope, long)

      {:ok, view, _html} = live(conn, path(project))

      text = view |> element("[data-test='problem-message-line']") |> render()

      assert text =~ "…", "a 1,700-character line with no newline still has to be cut"

      refute String.length(text) > 600,
             "the cell grew with the message, which is what makes the table unreadable"
    end

    test "the whole message stays reachable", %{conn: conn, scope: scope, project: project} do
      record(scope, "The step never reported done\n  the part that says why")

      {:ok, _view, html} = live(conn, path(project))

      assert html =~ "the part that says why",
             "truncating the cell must not throw the evidence away — it rides on the title"
    end
  end

  describe "an ordinary message" do
    test "is shown unchanged", %{conn: conn, scope: scope, project: project} do
      record(scope, "`with` contains only one <- clause")

      {:ok, view, _html} = live(conn, path(project))

      text = view |> element("[data-test='problem-message-line']") |> render()

      assert text =~ "contains only one"

      refute text =~ "…",
             "capping every message would put an ellipsis on the 360 that already fit"
    end
  end

  describe "the charts" do
    defp record_at(scope, source, file_path, n) do
      {:ok, _} =
        Problems.create_problems(
          scope,
          for line <- 1..n do
            %{
              severity: :error,
              source: source,
              source_type: :static_analysis,
              file_path: file_path,
              line: line,
              message: "#{source} #{line}",
              category: "c"
            }
          end
        )
    end

    defp option(view, selector) do
      view
      |> element(selector <> " [phx-hook='EChart']")
      |> render()
      |> then(&Regex.run(~r/data-option="([^"]*)"/, &1, capture: :all_but_first))
      |> hd()
      |> String.replace("&quot;", ~s("))
      |> Jason.decode!()
    end

    test "stack each copy's problems by source, and the picked copy's files", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      {:ok, other} =
        WorkingCopies.issue(scope, nil,
          label: "the harness at /repo/other",
          device: device_fixture(scope)
        )

      other_scope = %{scope | active_working_copy_id: other.id}

      record_at(scope, "credo", "lib/a.ex", 3)
      record_at(scope, "exunit", "test/a_test.exs", 1)
      record_at(other_scope, "credo", "lib/b.ex", 1)

      {:ok, view, _html} =
        live(conn, "#{path(project)}?harness=#{scope.active_working_copy_id}")

      by_copy = option(view, "[data-test='problems-by-copy']")
      assert by_copy["categories"] |> hd() =~ "main"
      assert by_copy["ids"] == [scope.active_working_copy_id, other.id]
      assert Enum.find(by_copy["stacks"], &(&1["name"] == "credo"))["data"] == [3, 1]
      assert Enum.find(by_copy["stacks"], &(&1["name"] == "exunit"))["data"] == [1, 0]

      by_file = option(view, "[data-test='problems-by-file']")
      assert by_file["categories"] == ["lib/a.ex", "test/a_test.exs"]

      render_hook(view, "pick_copy", %{"id" => other.id})
      assert_patch(view, "#{path(project)}?harness=#{other.id}")

      assert option(view, "[data-test='problems-by-file']")["categories"] == ["lib/b.ex"]
    end
  end
end
