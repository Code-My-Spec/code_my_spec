defmodule CodeMySpecWeb.ProjectLive.PickerTest do
  @moduledoc """
  Picking a project used to always send you to its stories. John: the default
  landing page for a project should be the agent conversation for its main
  agent — not a page that still makes you go find one.

  A freshly-created project has no checkout yet, so it has no main agent
  either (`Agents.ensure_main_agent/1` needs a working copy to start one in).
  That is the common case this pins: the picker still has to land somewhere
  useful rather than erroring, and `MainAgentConversation.path/2`'s own
  fallback — the agent-conversation index, which explains what is missing —
  is that somewhere.
  """

  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeMySpec.ProjectsFixtures

  setup [:register_and_log_in_user, :setup_active_account]

  defp create_project(%{scope: scope}) do
    %{project: project_fixture(scope)}
  end

  setup :create_project

  test "selecting a project with no main working copy lands on its agent conversation, not stories",
       %{conn: conn, project: project} do
    {:ok, picker_live, _html} = live(conn, ~p"/app/projects/picker")

    {:error, {:live_redirect, %{to: to}}} =
      picker_live
      |> element("a[phx-value-project-id='#{project.id}']")
      |> render_click()

    assert to == "/app/projects/#{project.id}/agent-conversation",
           "the default landing page for a project should be its agent conversation, " <>
             "not #{to}"
  end
end
