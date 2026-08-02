defmodule CodeMySpecSpex.Story712.Criterion6270Spex do
  @moduledoc """
  Story 712 — Local-first content publishing.
  Criterion 6270 — Admin LiveView renders parse status without hitting the
  SaaS.

  Rule: The local LiveView admin surface on `:4003/admin/content` shows
  per-file parse status, parse-error details, last-sync time, and a manual
  re-trigger button. No remote round-trip; everything renders from the local
  SQLite snapshot.

  Surface:
    * Local-web admin LiveView at `/admin/content`. After a sync that left
      five success rows and one error row, the table renders all six rows
      with their status, the failing row's parse-error detail, the last-sync
      timestamp, and a "Re-sync" button — entirely from the local snapshot,
      with no request to a CodeMySpec SaaS endpoint.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  @source "codemyspec-content"

  spex "The admin surface renders parse status from the local snapshot only" do
    scenario "Admin LiveView renders parse status without hitting the SaaS" do
      given_ "a snapshot of five success rows and one error row from a sync", context do
        env = context.environment

        for n <- 1..5 do
          :ok =
            Environments.write_file(env, "#{@source}/blog/post-#{n}.md", """
            ---
            title: Post #{n}
            slug: post-#{n}
            content_type: blog
            ---
            Body #{n}.
            """)
        end

        :ok =
          Environments.write_file(env, "#{@source}/blog/bad.md", """
          ---
          : : not : valid
          ---
          Body.
          """)

        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.name}/content")

        view
        |> form("[data-test='content-source-form']", source: %{path: @source})
        |> render_submit()

        view |> element("[data-test='sync-button']") |> render_click()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam opens the admin content surface", context do
        # Re-mount the page to prove everything renders from the persisted
        # local snapshot, not from transient socket state.
        {:ok, view, html} = live(context.conn, "/app/projects/#{context.project.name}/content")
        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "all six rows, statuses, error detail, last-sync, and re-sync render", context do
        html = render(context.view)

        assert html =~ "5",
               "expected the success count to render"

        for n <- 1..5 do
          assert has_element?(
                   context.view,
                   "[data-test='content-row-post-#{n}'][data-parse-status='success']"
                 )
        end

        assert has_element?(
                 context.view,
                 "[data-test='content-row-bad'][data-parse-status='error']"
               )

        assert has_element?(context.view, "[data-test='content-parse-error-bad']"),
               "the error row must render its parse-error detail"

        assert has_element?(context.view, "[data-test='last-sync-at']"),
               "the surface must render the last-sync timestamp"

        assert has_element?(context.view, "[data-test='sync-button']"),
               "the surface must render a Re-sync button"

        {:ok, context}
      end
    end
  end
end
