defmodule CodeMySpecSpex.Story1131.Criterion2311Spex do
  @moduledoc """
  Story 1131 — A dev box signs in with its own token.
  Criterion 2311 — Sam revokes a box and it drops off.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.DevBoxHelpers

  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Revoking a box ends its connection", criterion: 2311 do
    scenario "Sam revokes a connected box" do
      given_ "Sam's box 'cloud-1' is connected", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        box = add_box(live, "cloud-1", "claude_code_cloud")
        reply = exchanged(box.token)
        {:ok, socket} = connect_socket(reply["access_token"])
        CodeMySpecWeb.Endpoint.subscribe(UserSocket.id(socket))
        {:ok, Map.merge(context, %{live: live, box: box})}
      end

      when_ "Sam revokes its token", context do
        revoke_dev_box(context.live, context.box.id)
        {:ok, context}
      end

      then_ "its connection ends", context do
        assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
        {:ok, context}
      end

      then_ "and when its harness tries to sign in again it is refused", context do
        assert json_response(exchange(context.box.token), 401)["error"]
        {:ok, context}
      end
    end
  end
end
