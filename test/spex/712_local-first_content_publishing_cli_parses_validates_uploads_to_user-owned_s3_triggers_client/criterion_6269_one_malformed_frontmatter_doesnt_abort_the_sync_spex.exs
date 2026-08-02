defmodule CodeMySpecSpex.Story712.Criterion6269Spex do
  @moduledoc """
  Story 712 — Local-first content publishing.
  Criterion 6269 — One malformed frontmatter doesn't abort the sync.

  Rule: CLI parses every markdown file + YAML frontmatter against the
  Content schema; per-file `parse_status` (`:success` / `:error`) and a
  `parse_errors` map land in the local store. Sync never aborts on a single
  bad file — failures surface as data, not as exceptions.

  Surface:
    * Local-web admin LiveView at `/admin/content`. A directory with two
      valid posts and one broken-YAML post syncs to three rows — two
      success, one error carrying parse-error detail — and the operation
      reports a 2/1 summary rather than crashing.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  @source "codemyspec-content"

  spex "A single malformed file degrades to an error row, not an abort" do
    scenario "One malformed frontmatter doesn't abort the sync" do
      given_ "two valid posts and one with broken YAML frontmatter", context do
        env = context.environment

        for slug <- ~w(good-one good-two) do
          :ok =
            Environments.write_file(env, "#{@source}/blog/#{slug}.md", """
            ---
            title: #{slug}
            slug: #{slug}
            content_type: blog
            ---
            Body.
            """)
        end

        :ok =
          Environments.write_file(env, "#{@source}/blog/broken.md", """
          ---
          title: broken
          slug: broken
            content_type: : : not valid yaml :::
          - dangling
          ---
          Body.
          """)

        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.name}/content")

        view
        |> form("[data-test='content-source-form']", source: %{path: @source})
        |> render_submit()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam runs a content sync", context do
        context.view |> element("[data-test='sync-button']") |> render_click()
        {:ok, context}
      end

      then_ "the snapshot holds two success rows and one error row, exit clean", context do
        html = render(context.view)

        assert has_element?(
                 context.view,
                 "[data-test='content-row-good-one'][data-parse-status='success']"
               )

        assert has_element?(
                 context.view,
                 "[data-test='content-row-good-two'][data-parse-status='success']"
               )

        assert has_element?(
                 context.view,
                 "[data-test='content-row-broken'][data-parse-status='error']"
               ),
               "the broken file must land as an error row, not abort the sync"

        assert html =~ "2 success, 1 error",
               "expected the summary to report 2 success, 1 error"

        assert render(context.view) =~ ~r/yaml/i,
               "the error row must name the YAML parse failure in its parse_errors detail"

        {:ok, context}
      end
    end
  end
end
