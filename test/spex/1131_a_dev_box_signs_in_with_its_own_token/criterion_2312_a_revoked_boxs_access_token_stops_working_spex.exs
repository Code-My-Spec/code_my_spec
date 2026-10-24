defmodule CodeMySpecSpex.Story1131.Criterion2312Spex do
  @moduledoc """
  Story 1131 — A dev box signs in with its own token.
  Criterion 2312 — A revoked box's access token stops working.
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

  spex "An access token issued before the revoke is dead after it", criterion: 2312 do
    scenario "the revoked box uses its old access token" do
      given_ "'cloud-1' was issued an access token before Sam revoked it", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        box = add_box(live, "cloud-1", "claude_code_cloud")
        access = exchanged(box.token)["access_token"]
        revoke_dev_box(live, box.id)
        {:ok, Map.put(context, :access, access)}
      end

      when_ "it uses that access token", context do
        {:ok, Map.put(context, :result, connect_socket(context.access))}
      end

      then_ "it is refused", context do
        refute match?({:ok, _}, context.result), "a revoked box's access token still connects"
        {:ok, context}
      end
    end
  end
end
