defmodule CodeMySpecSpex.Story127.Criterion1639Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1639 — Files are still linked to the component that owns them.

  Components as records (3aeb66cf): a sync reads no spec and writes nothing
  about an existing component; it only discovers what live code names and
  prunes what it discovered once the code is gone. Surface: files written into
  the working copy, `create_component`, `add_dependency`, `sync_project`;
  observed through `get_component`, `list_components` and `show_architecture`.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Files are still linked to the component that owns them",
    criterion: 1639 do
    scenario "Accounts gets its code" do
      given_ "Accounts and Web, designed", context do
        app = app(context)
        design!(context, "#{app}.Accounts", [], description: "Accounts, as designed")
        design!(context, "#{app}.Web")
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
