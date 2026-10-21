defmodule CodeMySpecSpex.Story1131.Criterion2308Spex do
  @moduledoc """
  Story 1131 — A dev box signs in with its own token.
  Criterion 2308 — The harness connects with a short-lived token.
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

  spex "The channel connects with an access token that expires", criterion: 2308 do
    scenario "a box signs in and connects" do
      given_ "Sam's box signs in with its token", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        box = add_box(live, "cloud-1", "claude_code_cloud")
        {:ok, Map.merge(context, %{box: box, reply: exchanged(box.token)})}
      end

      then_ "it receives an access token that expires", context do
        assert is_binary(context.reply["access_token"]),
               "no access token in #{inspect(context.reply)}"

        assert context.reply["access_token"] != context.box.token
        assert is_integer(context.reply["expires_in"]) and context.reply["expires_in"] > 0
        {:ok, context}
      end

      then_ "its channel connects with the access token, not the box token", context do
        assert {:ok, _socket} = connect_socket(context.reply["access_token"])

        refute match?({:ok, _}, connect_socket(context.box.token)),
               "the channel accepted the box token itself"

        {:ok, context}
      end
    end
  end
end
