defmodule CodeMySpecSpex.Story1014.Criterion2866Spex do
  @moduledoc """
  Story 1014 — A working copy that vanished warns until I offboard it.
  Criterion 2866 — An orphan component stops blocking a gate no edit could
  clear.

  Rule: A component is reclaimed only when it has no files and no story
  references it.

  This is the payoff, and it survives the rework unchanged in substance — only
  what triggers it moved. Issue `3c6b6b63`: components held alive by the
  projection of a checkout nobody is running. The component has no files any live
  agent can edit and no story pointing at it, so nothing anybody does in any
  working copy resolves what the graph demands of it. The gate is shut and there
  is no key.

  What changed is that clearing it is now an act rather than a side effect of
  somebody else's sync. The gate stays shut a little longer and opens when
  somebody decides, instead of opening on a timer that was also capable of
  deleting a working agent's state.

  Asserted on the components list rather than on a count, because the list is
  where the orphan was visible. A reclaim that emptied a table the view does not
  read would satisfy a count and change nothing anybody sees.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Offboarding takes the orphans the copy was holding alive" do
    scenario "An orphan component stops blocking a gate no edit could clear" do
      given_ :synced_context_component

      given_ "the copy that built it is one I am offboarding", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        assert render(view) =~ "ExampleContext",
               "the premise failed: the component is not listed, so there is no " <>
                 "orphan for the offboard to take"

        {:ok, context}
      end

      when_ "the offboard runs", context do
        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        live
        |> element(
          "#offboard-#{context.scope.active_working_copy_id} [data-role='confirm-confirm']"
        )
        |> render_click()

        {:ok, context}
      end

      then_ "the component goes with it", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        refute render(view) =~ "ExampleContext",
               "a component whose only files belonged to the offboarded copy, and " <>
                 "which no story points at, is still listed. It has no files any " <>
                 "live agent can edit and nothing authored pointing at it, so " <>
                 "nothing anyone does in any working copy can resolve what the " <>
                 "graph demands of it. That is 3c6b6b63: a gate held shut by the " <>
                 "projection of a checkout that is gone."

        {:ok, context}
      end
    end
  end
end
