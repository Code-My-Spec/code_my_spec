defmodule CodeMySpecSpex.Story1014.Criterion2867Spex do
  @moduledoc """
  Story 1014 — A working copy that vanished warns until I offboard it.
  Criterion 2867 — Authored links are never spent to clear derived rows.

  Rule: A component is reclaimed only when it has no files and no story
  references it.

  The other half of the rule, and the one that keeps offboarding safe enough to
  be a button.

  A story's link to a component is authored: somebody decided it. Files and
  problems are derived: an agent produced them and an agent reproduces them on
  the next scan. Trading the first to clear the second exchanges something nobody
  can regenerate for something that regenerates by itself.

  It matters more now than it did under the old model. That one ran on a timer,
  so a wrong reclaim was at least rare and slow; this one runs the moment
  somebody clicks, on a project where the component's files may all have come
  from the copy being removed. The link is the thing standing between "this
  checkout is gone" and "the design work that referenced it is gone".
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

  spex "A story's link outlives the copy that built the component" do
    scenario "Authored links are never spent to clear derived rows" do
      given_ :synced_context_component
      given_ :story_linked_to_component

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

      then_ "the component survives", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        assert render(view) =~ "ExampleContext",
               "a component a story is linked to was removed because its files " <>
                 "belonged to the offboarded copy. The link is authored — somebody " <>
                 "decided it — and authored data is project-scoped and shared. " <>
                 "Spending it to clear derived rows trades something nobody can " <>
                 "regenerate for something that regenerates on the next sync."

        {:ok, context}
      end

      then_ "and the story's link to it is unchanged", context do
        {:ok, view, html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/stories/#{context.story.number}"
          )

        assert render(view) =~ "ExampleContext",
               "the component survived but the story no longer points at it, so " <>
                 "the link was spent after all — just quietly enough that the " <>
                 "components list still looks right. Got: #{html}"

        {:ok, context}
      end
    end
  end
end
