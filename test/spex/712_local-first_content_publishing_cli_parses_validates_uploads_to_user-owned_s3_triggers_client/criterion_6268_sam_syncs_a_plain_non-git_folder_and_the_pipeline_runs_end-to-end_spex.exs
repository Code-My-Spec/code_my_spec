defmodule CodeMySpecSpex.Story712.Criterion6268Spex do
  @moduledoc """
  Story 712 — Local-first content publishing.
  Criterion 6268 — Sam syncs a plain non-Git folder and the pipeline runs
  end-to-end.

  Rule: CLI ingest accepts any content directory the user points at — Git
  working copy, separate content repo, plain folder, Dropbox/iCloud-synced
  dir — without baking a `docs_repo` field into the project. The
  source-of-truth choice belongs to the user, not the harness.

  Surface:
    * Local-web admin LiveView at `/admin/content` (port 4003). The
      operator points the source at a plain folder on disk and clicks
      "Sync". The pipeline reads markdown straight from the filesystem —
      no clone/fetch/pull. Parse results land in the local snapshot and
      render in the admin table.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  @source "codemyspec-content"

  spex "A plain non-Git folder syncs end-to-end" do
    scenario "Sam syncs a plain non-Git folder and the pipeline runs end-to-end" do
      given_ "a plain folder with three markdown files and no .git directory", context do
        env = context.environment

        for slug <- ~w(alpha beta gamma) do
          :ok =
            Environments.write_file(env, "#{@source}/blog/#{slug}.md", """
            ---
            title: #{String.capitalize(slug)}
            slug: #{slug}
            content_type: blog
            ---
            # #{String.capitalize(slug)}

            Body for #{slug}.
            """)
        end

        # No `.git` directory is created — this is a plain folder.
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/content")

        view
        |> form("[data-test='content-source-form']", source: %{path: @source})
        |> render_submit()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam runs a content sync", context do
        html =
          context.view
          |> element("[data-test='sync-button']")
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the snapshot holds three success rows and no git operation ran", context do
        html = render(context.view)

        for slug <- ~w(alpha beta gamma) do
          assert has_element?(context.view, "[data-test='content-row-#{slug}']"),
                 "expected a snapshot row for #{slug}"
        end

        assert html =~ "3 success",
               "expected the sync summary to report three successfully parsed files"

        refute html =~ ~r/clone|fetch|pull/i,
               "a plain folder must sync without any git clone/fetch/pull operation"

        {:ok, context}
      end
    end
  end
end
