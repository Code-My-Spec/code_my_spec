defmodule CodeMySpecWeb.ArchitectureLive.TheBoundaryTabStatesItsClaimsTest do
  @moduledoc """
  The architecture page's default tab draws boundaries and states the claims a
  reader would otherwise have to count off the graph: how many boundaries, how
  deep, which chain is longest, and which cycles exist.
  """

  use CodeMySpecSpex.Case, async: true

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "a project whose scan recorded no declarations says so instead of drawing nothing", ctx do
    {:ok, _view, html} = live(ctx.conn, "/app/projects/#{ctx.project.id}/architecture")

    summary =
      html
      |> Floki.parse_document!()
      |> Floki.find("[data-test='boundary-summary']")
      |> Floki.text()

    assert summary =~ "No `use Boundary` declarations recorded yet"
    assert summary =~ "0 deep"
    assert summary =~ "No cycles."
  end
end
