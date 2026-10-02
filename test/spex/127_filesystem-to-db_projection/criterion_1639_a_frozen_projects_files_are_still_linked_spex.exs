defmodule CodeMySpecSpex.Story127.Criterion1639Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1639 — In a frozen project, files are still linked to the component that owns them.

  Components as records, step 4 (3aeb66cf): once a project is frozen, a sync
  stops treating its files as the description of its components. Surface:
  files written into the working copy, `sync_project`, `freeze_components`;
  observed through `get_component`, `list_components` and `show_architecture`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "In a frozen project, files are still linked to the component that owns them",
    criterion: 1639 do
    scenario "Accounts gets its code after the freeze" do
      given_ "a frozen project whose Accounts and Web have specs", context do
        app = app(context)
        spec!(context, "#{app}.Accounts", [], description: "Accounts, as specified")
        spec!(context, "#{app}.Web")
        sync!(context)
        freeze(context, write: true)
        {:ok, context}
      end

      when_ "Accounts' code is written and the engineer syncs from the Files page", context do
        implementation!(context, "#{app(context)}.Accounts")
        {:ok, files_live, _html} = live(context.conn, "/app/projects/#{context.project.id}/files")
        files_live |> element("[data-test='sync-button']") |> render_click()
        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the code file is linked to Accounts", context do
        path = "lib/#{Macro.underscore("#{app(context)}.Accounts")}.ex"

        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{path}\"] [data-test='file-component']",
                 "Accounts"
               )

        {:ok, context}
      end
    end
  end
end
