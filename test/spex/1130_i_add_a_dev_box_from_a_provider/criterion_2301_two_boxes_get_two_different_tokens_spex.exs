defmodule CodeMySpecSpex.Story1130.Criterion2301Spex do
  @moduledoc """
  Story 1130 — I add a dev box from a provider.
  Criterion 2301 — Two boxes get two different tokens.
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

  spex "Each box has its own token", criterion: 2301 do
    scenario "Sam adds cloud-1 and then laptop" do
      given_ "Sam adds cloud-1 and then laptop", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        add_dev_box(live, "cloud-1", "claude_code_cloud")
        cloud_token = shown_token(live)
        add_dev_box(live, "laptop", "local")
        laptop_token = shown_token(live)

        {:ok,
         Map.merge(context, %{
           live: live,
           cloud_token: cloud_token,
           laptop_token: laptop_token
         })}
      end

      then_ "each has its own token", context do
        assert context.cloud_token != context.laptop_token
        {:ok, context}
      end

      then_ "neither token signs in as the other box", context do
        cloud_box = box_device_id(context.live, "cloud-1")
        laptop_box = box_device_id(context.live, "laptop")
        assert cloud_box != laptop_box

        assert sign_in_with(context.cloud_token)["device_id"] == cloud_box
        assert sign_in_with(context.laptop_token)["device_id"] == laptop_box
        {:ok, context}
      end
    end
  end
end
