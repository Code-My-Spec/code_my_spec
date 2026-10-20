defmodule CodeMySpecSpex.Story1130.Criterion2299Spex do
  @moduledoc """
  Story 1130 — I add a dev box from a provider.
  Criterion 2299 — Sam picks Claude Code cloud or Local.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.DevBoxHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Sam picks a provider", criterion: 2299 do
    scenario "Sam adds a Claude Code cloud box" do
      given_ "Sam chooses Add on Dev boxes", context do
        {:ok, live, _html} = open_dev_boxes(context.conn)
        live |> element("[data-test='add-dev-box']") |> render_click()
        {:ok, Map.put(context, :live, live)}
      end

      then_ "he is offered Local and Claude Code cloud", context do
        html = render(context.live)
        assert html =~ "Local"
        assert html =~ "Claude Code cloud"
        assert has_element?(context.live, "input[name='dev_box[provider]'][value='local']")

        assert has_element?(
                 context.live,
                 "input[name='dev_box[provider]'][value='claude_code_cloud']"
               )

        {:ok, context}
      end

      when_ "he picks Claude Code cloud and names the box", context do
        context.live
        |> form("[data-test='add-dev-box-form']",
          dev_box: %{name: "cloud-1", provider: "claude_code_cloud"}
        )
        |> render_submit()

        {:ok, context}
      end

      then_ "a Claude Code cloud box with that name is added", context do
        row =
          context.live
          |> element("[data-test='dev-box'][data-box-name='cloud-1']")
          |> render()

        assert row =~ "Claude Code cloud"
        {:ok, context}
      end
    end
  end
end
