defmodule CodeMySpecSpex.Story1130.Criterion2300Spex do
  @moduledoc """
  Story 1130 — I add a dev box from a provider.
  Criterion 2300 — Sam sees his new box's token once.
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

  spex "A box's token is shown once", criterion: 2300 do
    scenario "Sam adds a box, leaves, and comes back" do
      given_ "Sam adds a box named cloud-1", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        add_dev_box(live, "cloud-1", "claude_code_cloud")
        {:ok, Map.merge(context, %{live: live, token: shown_token(live)})}
      end

      then_ "its token is shown to him", context do
        assert is_binary(context.token) and context.token != ""
        assert render(context.live) =~ context.token
        {:ok, context}
      end

      when_ "he leaves the page and comes back", context do
        {:ok, again, html} = open_dev_boxes(context.conn, context.project)
        {:ok, Map.merge(context, %{again: again, html: html})}
      end

      then_ "the box is listed but its token is not shown again", context do
        assert has_element?(context.again, "[data-test='dev-box'][data-box-name='cloud-1']")
        refute has_element?(context.again, "[data-test='new-dev-box-token']")
        refute context.html =~ context.token
        {:ok, context}
      end
    end
  end
end
