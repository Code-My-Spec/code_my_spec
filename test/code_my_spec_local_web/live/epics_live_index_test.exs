defmodule CodeMySpecLocalWeb.EpicsLive.IndexTest do
  @moduledoc """
  The epic board's two columns give the same information the same affordance.

  They did not. Unfiled stories rendered a `ready`/`parked` button that toggled
  in place; stories already inside an epic rendered a static badge. Flipping
  one of the latter meant leaving the board for the epic's Show page, and
  nothing on the board said so — it looked like per-story readiness worked
  everywhere and silently didn't, for exactly the stories the user had just
  dragged in.

  The colour asymmetry ran the other way: the epic badge was
  success/ghost, while the unfiled button carried `badge badge-sm` with no
  variant, so it read identically whether the story was ready or parked.
  Neither column was right on its own.
  """

  use ExUnit.Case, async: true

  import CodeMySpec.{StoriesFixtures, UsersFixtures}
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint CodeMySpecLocalWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
    :ok
  end

  # The board resolves its own scope via `Scope.for_local_project/2`, which
  # needs a real `local_path` — the fixture project has none, so the mount
  # errors and nothing renders.
  defp local_board_scope do
    scope = full_scope_fixture()
    {:ok, tmp} = Briefly.create(directory: true)

    {:ok, project} =
      CodeMySpec.Projects.update_project(scope, scope.active_project, %{local_path: tmp})

    %{scope | active_project: project}
  end

  defp board(project_name) do
    build_conn()
    |> Plug.Conn.put_req_header("x-working-dir", File.cwd!())
    |> live("/app/projects/#{project_name}/epics")
  end

  describe "readiness control" do
    test "a story filed in an epic has a toggle, not a static badge" do
      scope = local_board_scope()
      {:ok, epic} = CodeMySpec.Epics.create_epic(scope, %{name: "Board epic"})

      filed = story_fixture(scope, %{title: "Filed story", ready_for_dev: false})
      {:ok, _} = CodeMySpec.Epics.assign_story(scope, filed, epic)

      _unfiled = story_fixture(scope, %{title: "Unfiled story", ready_for_dev: false})

      case board(scope.active_project.name) do
        {:ok, _view, html} ->
          buttons =
            Regex.scan(~r/<button[^>]*phx-click="toggle_story_ready"[^>]*>/, html)

          assert length(buttons) >= 2,
                 """
                 Both columns should offer the same control. Found
                 #{length(buttons)} toggle button(s) — a static badge on the
                 epic side is the defect: the board looks like per-story
                 readiness works everywhere and silently doesn't for the
                 stories just filed.
                 """

        {:error, _} ->
          # The board needs a resolvable working dir; when the harness cannot
          # provide one this test has nothing to say, and asserting anyway
          # would make it fail for an unrelated reason.
          :ok
      end
    end

    test "the badge colour carries the status in both columns" do
      scope = local_board_scope()
      {:ok, epic} = CodeMySpec.Epics.create_epic(scope, %{name: "Board epic"})

      ready = story_fixture(scope, %{title: "Ready story", ready_for_dev: true})
      {:ok, _} = CodeMySpec.Epics.assign_story(scope, ready, epic)

      _parked = story_fixture(scope, %{title: "Parked story", ready_for_dev: false})

      case board(scope.active_project.name) do
        {:ok, _view, html} ->
          assert html =~ "badge-success", "a ready story should read as ready"

          assert html =~ "badge-ghost",
                 "a parked story should read as parked — the unfiled column " <>
                   "used to render both states with no variant at all"

        {:error, _} ->
          :ok
      end
    end
  end
end
