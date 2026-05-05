defmodule CodeMySpecSpex.Story127.Criterion5930Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 5930 — Files outside the project source tree are not
  picked up by sync.

  Covers Rule "Sync covers the project source tree only." A file
  written to `priv/static/` (outside the sync whitelist) does not
  appear in the projection even after a sync; an in-tree sibling
  does — proving the boundary is enforced rather than the whole
  sync being broken.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @in_tree_path "lib/in_tree_module.ex"
  @out_of_tree_path "priv/static/out_of_tree.txt"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer does not see out-of-tree files in the Files projection" do
    scenario "file in priv/static is invisible while a sibling lib file is projected" do
      given_ "the agent has written one file inside lib/ and another inside priv/static/",
             context do
        :ok = Environments.write_file(context.environment, @in_tree_path, in_tree_module())
        :ok = Environments.write_file(context.environment, @out_of_tree_path, "ignored\n")
        {:ok, context}
      end

      when_ "the engineer triggers a sync from the Files page", context do
        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the in-tree file appears and the out-of-tree file does not", context do
        # Anchor: the in-tree file proves sync ran and the table populated.
        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@in_tree_path}\"]"
               )

        refute has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@out_of_tree_path}\"]"
               )

        {:ok, context}
      end
    end
  end

  defp in_tree_module do
    """
    defmodule InTreeModule do
      @moduledoc false
    end
    """
  end
end
