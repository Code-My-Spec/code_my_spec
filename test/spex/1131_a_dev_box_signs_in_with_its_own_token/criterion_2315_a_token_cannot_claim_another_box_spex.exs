defmodule CodeMySpecSpex.Story1131.Criterion2315Spex do
  @moduledoc """
  Story 1131 — A dev box signs in with its own token.
  Criterion 2315 — A token cannot claim another box.
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

  spex "A token only ever signs in as its own box", criterion: 2315 do
    scenario "cloud-1's token says it is the laptop" do
      given_ "Sam has boxes 'cloud-1' and 'laptop'", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        cloud = add_box(live, "cloud-1", "claude_code_cloud")
        laptop = add_box(live, "laptop", "local")
        {:ok, Map.merge(context, %{cloud: cloud, laptop: laptop})}
      end

      when_ "a harness signs in with 'cloud-1''s token and says it is 'laptop'", context do
        conn =
          exchange(context.cloud.token, %{
            "device_id" => context.laptop.id,
            "hostname" => "laptop"
          })

        {:ok, Map.put(context, :conn, conn)}
      end

      then_ "it is signed in as 'cloud-1' or refused, never as 'laptop'", context do
        assert context.conn.status in [200, 401, 403]
        body = Jason.decode!(context.conn.resp_body)
        refute body["device_id"] == context.laptop.id, "cloud-1's token signed in as the laptop"
        {:ok, context}
      end
    end
  end
end
