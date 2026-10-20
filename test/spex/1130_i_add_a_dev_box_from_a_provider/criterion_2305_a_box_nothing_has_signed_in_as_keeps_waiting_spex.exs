defmodule CodeMySpecSpex.Story1130.Criterion2305Spex do
  @moduledoc """
  Story 1130 — I add a dev box from a provider.
  Criterion 2305 — A box nothing has signed in as keeps waiting.
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

  spex "A box nothing has signed in as says so", criterion: 2305 do
    scenario "Sam opens Dev boxes later" do
      given_ "Sam added a box and no harness has signed in with its token", context do
        {:ok, live, _html} = open_dev_boxes(context.conn)
        add_dev_box(live, "cloud-1", "claude_code_cloud")
        {:ok, context}
      end

      when_ "he opens Dev boxes", context do
        {:ok, live, _html} = open_dev_boxes(context.conn)
        {:ok, Map.put(context, :live, live)}
      end

      then_ "the box says it has never connected", context do
        status =
          context.live
          |> element(
            "[data-test='dev-box'][data-box-name='cloud-1'] [data-test='dev-box-status']"
          )
          |> render()

        assert status =~ "Never connected"
        {:ok, context}
      end
    end
  end
end
