defmodule CodeMySpecSpex.Story1136.Criterion2332Spex do
  @moduledoc """
  Story 1136 — CodeMySpec starts a cloud session when there is work.
  Criterion 2332 — A box without a fire token has no Start.
  """
  use CodeMySpecSpex.Case, async: false

  import CodeMySpecSpex.DevBoxHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "No fire token, no Start", criterion: 2332 do
    scenario "Sam's cloud box has no fire token" do
      given_ "Sam's cloud box has no fire token", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        box = add_box(live, "cloud-1", "claude_code_cloud")
        {:ok, Map.merge(context, %{live: live, box: box})}
      end

      then_ "Dev boxes offers to add one instead of Start", context do
        refute has_element?(context.live, "[data-test='start-box']")

        assert has_element?(
                 context.live,
                 "[data-test='add-fire-token'][data-device-id='#{context.box.id}']"
               )

        {:ok, context}
      end
    end
  end
end
