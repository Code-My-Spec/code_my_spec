defmodule CodeMySpec.Requirements.EdgesAreWrittenAsADifferenceTest do
  @moduledoc """
  Writing the same topology twice costs nothing the second time.

  `write_edges/2` used to delete every edge at a vantage and insert the whole
  set back whenever topology moved at all. Measured on dev: 124,760 edges, so
  ~249,500 row writes to express one component appearing — and components move
  around fifty times an hour while agents work, which made this 79% of all
  write volume across 192 drains.

  The gate above it was never the problem. `Freshness.topology/2` is stable
  across identical reads and the reprojections were each warranted; what was
  wrong was answering "something moved" with "rewrite everything".

  `NodeRepository.replace_edges/3` has always done this properly for the real
  table. This is the same claim for the writer the event path uses — which
  matters beyond the shadow, because after the swap that writer owns the real
  edges.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.Requirements.Shadow

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Application.put_env(:code_my_spec, :graph_shadow_projection, true)
    on_exit(fn -> Application.delete_env(:code_my_spec, :graph_shadow_projection) end)
    :ok
  end

  defp edge(from, to), do: %{from: from, to: to}

  describe "writing a topology that has not moved" do
    test "writes nothing the second time", %{scope: scope} do
      edges = [
        edge(
          {"project", scope.active_project_id, "personas_complete"},
          {"project", scope.active_project_id, "stories_exist"}
        ),
        edge(
          {"project", scope.active_project_id, "stories_exist"},
          {"project", scope.active_project_id, "architecture_designed"}
        )
      ]

      {:ok, first} = Shadow.write_edges(scope, edges)
      assert first > 0, "the first write should have inserted the edges"

      {:ok, second} = Shadow.write_edges(scope, edges)

      assert second == 0,
             """
             Rewriting an unchanged topology cost #{second} row write(s).

             Every one of them deleted an edge and put it back identical. That
             is what made a single component appearing rewrite the whole edge
             set — 124,760 rows on this project, 79% of all write volume.
             """
    end

    test "writes only the difference when topology moves", %{scope: scope} do
      a =
        edge(
          {"project", scope.active_project_id, "personas_complete"},
          {"project", scope.active_project_id, "stories_exist"}
        )

      b =
        edge(
          {"project", scope.active_project_id, "stories_exist"},
          {"project", scope.active_project_id, "architecture_designed"}
        )

      {:ok, _} = Shadow.write_edges(scope, [a, b])

      # One edge goes, one arrives, one stays.
      c =
        edge(
          {"project", scope.active_project_id, "architecture_designed"},
          {"project", scope.active_project_id, "code_generation"}
        )

      {:ok, moved} = Shadow.write_edges(scope, [b, c])

      assert moved == 2,
             """
             One edge was dropped and one added, so this should have cost two
             writes. It cost #{moved}, which means the edge that did not change
             was rewritten along with them.
             """
    end
  end
end
