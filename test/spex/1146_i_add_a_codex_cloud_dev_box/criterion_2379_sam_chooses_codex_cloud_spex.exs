defmodule CodeMySpecSpex.Story1146.Criterion2379Spex do
  @moduledoc "Story 1146 — Sam chooses Codex Cloud alongside the existing dev-box providers."
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.DevBoxHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam chooses Codex Cloud", criterion: 2379 do
    scenario "An account owner opens Add on Dev boxes" do
      given_ "Sam owns the account and is on Dev boxes", context do
        {:ok, view, _html} = open_dev_boxes(context.conn, context.project)
        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam chooses Add", context do
        context.view |> element("[data-test='add-dev-box']") |> render_click()
        {:ok, context}
      end

      then_ "Codex Cloud, Claude Code cloud and Local are available", context do
        assert has_element?(context.view, "input[name='dev_box[provider]'][value='codex_cloud']")

        assert has_element?(
                 context.view,
                 "input[name='dev_box[provider]'][value='claude_code_cloud']"
               )

        assert has_element?(context.view, "input[name='dev_box[provider]'][value='local']")
        assert render(context.view) =~ "Codex Cloud"
        {:ok, context}
      end
    end
  end
end
