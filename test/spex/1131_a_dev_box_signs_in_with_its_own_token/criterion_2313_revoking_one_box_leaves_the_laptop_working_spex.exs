defmodule CodeMySpecSpex.Story1131.Criterion2313Spex do
  @moduledoc """
  Story 1131 — A dev box signs in with its own token.
  Criterion 2313 — Revoking one box leaves the laptop working.
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

  spex "Revoking cloud-1 does not touch the laptop", criterion: 2313 do
    scenario "Sam revokes one of two connected boxes" do
      given_ "Sam's 'cloud-1' and 'laptop' are both connected", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        cloud = add_box(live, "cloud-1", "claude_code_cloud")
        laptop = add_box(live, "laptop", "local")
        laptop_access = exchanged(laptop.token)["access_token"]
        assert {:ok, _socket} = connect_socket(laptop_access)

        {:ok,
         Map.merge(context, %{
           live: live,
           cloud: cloud,
           laptop: laptop,
           laptop_access: laptop_access
         })}
      end

      when_ "he revokes 'cloud-1'", context do
        revoke_dev_box(context.live, context.cloud.id)
        {:ok, context}
      end

      then_ "'laptop' stays connected and keeps working", context do
        assert {:ok, _socket} = connect_socket(context.laptop_access)
        assert exchanged(context.laptop.token)["device_id"] == context.laptop.id
        {:ok, context}
      end
    end
  end
end
