defmodule CodeMySpecSpex.Story1131.Criterion2310Spex do
  @moduledoc """
  Story 1131 — A dev box signs in with its own token.
  Criterion 2310 — The token arrives as a header the box never held.
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

  spex "The proxy supplies the token", criterion: 2310 do
    scenario "the harness asks for an access token without sending a token itself" do
      given_ "Sam's Claude Code cloud environment attaches the box's token as a bearer header",
             context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        {:ok, Map.put(context, :box, add_box(live, "cloud-1", "claude_code_cloud"))}
      end

      when_ "the harness asks for an access token without sending a token itself", context do
        conn =
          build_conn()
          |> through_cloud_proxy(context.box.token)
          |> post("/api/devices/token", %{})

        {:ok, Map.put(context, :reply, json_response(conn, 200))}
      end

      then_ "it is signed in as that box", context do
        assert context.reply["device_id"] == context.box.id
        {:ok, context}
      end
    end
  end
end
