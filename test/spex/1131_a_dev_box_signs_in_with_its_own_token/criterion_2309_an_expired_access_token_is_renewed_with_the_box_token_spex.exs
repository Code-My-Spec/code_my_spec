defmodule CodeMySpecSpex.Story1131.Criterion2309Spex do
  @moduledoc """
  Story 1131 — A dev box signs in with its own token.
  Criterion 2309 — An expired access token is renewed with the box token.
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

  spex "A harness whose access token expired trades its box token again", criterion: 2309 do
    scenario "the access token runs out" do
      given_ "Sam's box has been connected longer than its access token lasts", context do
        short_lived_access_tokens(1)
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        box = add_box(live, "cloud-1", "claude_code_cloud")
        first = exchanged(box.token)
        assert {:ok, _socket} = connect_socket(first["access_token"])
        {:ok, Map.merge(context, %{box: box, first: first})}
      end

      when_ "the access token expires", context do
        eventually(fn ->
          refute match?({:ok, _}, connect_socket(context.first["access_token"]))
        end)

        {:ok, context}
      end

      then_ "the harness trades its box token again and stays connected", context do
        second = exchanged(context.box.token)
        assert second["device_id"] == context.box.id
        assert second["access_token"] != context.first["access_token"]
        assert {:ok, _socket} = connect_socket(second["access_token"])
        {:ok, context}
      end
    end
  end
end
