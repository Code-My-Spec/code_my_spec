defmodule CodeMySpecSpex.Story1130.Criterion2304Spex do
  @moduledoc """
  Story 1130 — I add a dev box from a provider.
  Criterion 2304 — Sam watches his box connect.
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

  spex "The page shows the box connect without a reload", criterion: 2304 do
    scenario "a harness signs in with the box's token" do
      given_ "Sam has just added a box and is still on its page", context do
        {:ok, live, _html} = open_dev_boxes(context.conn)
        add_dev_box(live, "cloud-1", "claude_code_cloud")
        {:ok, Map.merge(context, %{live: live, token: shown_token(live)})}
      end

      when_ "a harness signs in with that box's token", context do
        reply = sign_in_with(context.token)
        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "the page shows the box as connected without a reload", context do
        assert context.reply["device_id"] == box_device_id(context.live, "cloud-1")

        eventually(fn ->
          row =
            context.live
            |> element(
              "[data-test='dev-box'][data-box-name='cloud-1'] [data-test='dev-box-status']"
            )
            |> render()

          assert row =~ "Connected"
        end)

        {:ok, context}
      end
    end
  end
end
