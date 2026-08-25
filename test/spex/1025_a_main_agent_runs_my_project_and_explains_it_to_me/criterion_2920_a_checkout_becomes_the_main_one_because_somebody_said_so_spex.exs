defmodule CodeMySpecSpex.Story963.Criterion2920Spex do
  @moduledoc """
  Story 963 — A main agent runs my project and explains it to me.
  Criterion 2920 — A checkout becomes the main one because somebody said so.

  Rule: A project's main working copy is one somebody designated, not one that was guessed.

  Designation rather than inference, and the reason is a case that already
  exists on this project: six checkouts of one repository, several of them
  worktrees, one of them the place the work actually belongs. Nothing about a
  path, a label or a last-seen time picks the right one.

  `projects.default_working_copy_id` is deliberately not this. That column is a
  nil-object — a derived, rootless row for writers with no checkout, which never
  joins and has no disk — so adopting it would change its meaning for everything
  already relying on it.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A project's main working copy is one somebody designated, not one that was guessed" do
    scenario "A checkout becomes the main one because somebody said so" do
      given_ "a project with more than one working copy", context do
        first = CodeMySpec.TempFile.dir("spex_2920_first")
        second = CodeMySpec.TempFile.dir("spex_2920_second")
        File.mkdir_p!(first)
        File.mkdir_p!(second)

        one = join_working_copy(context, first, "the first checkout")
        two = join_working_copy(context, second, "the second checkout")

        {:ok,
         context |> Map.put(:chosen, two.working_copy_id) |> Map.put(:other, one.working_copy_id)}
      end

      when_ "one of them is designated the main working copy", context do
        {:ok, live, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/working-copies/#{context.chosen}"
          )

        html =
          live
          |> element("[data-test=designate-main-copy]")
          |> render_click()

        {:ok, context |> Map.put(:html, html)}
      end

      then_ "the main agent runs there", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        assert html =~ context.chosen,
               "the main agent is not on the copy that was designated, so designating " <>
                 "one decided nothing"

        {:ok, Map.put(context, :conversation_html, html)}
      end

      then_ "and the designation is visible rather than inferred", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/working-copies")

        assert html =~ "data-test=\"main-copy\"",
               "nothing on the list says which checkout is the main one. A designation " <>
                 "nobody can see is indistinguishable from a guess, which is the thing " <>
                 "this rule exists to rule out."

        {:ok, context}
      end
    end
  end
end
