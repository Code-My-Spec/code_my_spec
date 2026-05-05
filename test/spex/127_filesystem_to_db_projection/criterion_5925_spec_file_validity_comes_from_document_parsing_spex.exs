defmodule CodeMySpecSpex.Story127.Criterion5925Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 5925 — Spec file validity comes from document parsing.

  Covers Rule "Validity is determined per file role." Well-formed spec
  → File row marked valid in the projection.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  @spec_path ".code_my_spec/spec/example_context.spec.md"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees well-formed specs marked valid in the projection" do
    scenario "well-formed context spec gets a valid badge in the Files table" do
      given_ :synced_context_component

      when_ "the engineer opens the Files page", context do
        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the spec file row shows the valid badge", context do
        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@spec_path}\"] [data-validity='valid']"
               )

        {:ok, context}
      end
    end
  end
end
