defmodule CodeMySpecSpex.Story1130.Criterion2302Spex do
  @moduledoc """
  Story 1130 — I add a dev box from a provider.
  Criterion 2302 — Claude Code cloud tells Sam where the token goes.
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

  spex "A Claude Code cloud box says where its token goes", criterion: 2302 do
    scenario "Sam has just added a Claude Code cloud box" do
      given_ "Sam has just added a Claude Code cloud box", context do
        {:ok, live, _html} = open_dev_boxes(context.conn)
        add_dev_box(live, "cloud-1", "claude_code_cloud")
        {:ok, Map.put(context, :live, live)}
      end

      then_ "he is shown the setup script, the hosts to allow, and the network secret to add with the token",
            context do
        assert has_element?(context.live, "[data-test='setup-script']")
        assert has_element?(context.live, "[data-test='setup-hosts']")
        assert has_element?(context.live, "[data-test='setup-network-secret']")
        {:ok, context}
      end

      then_ "each has a copy button", context do
        assert has_element?(context.live, "[data-test='copy-setup-script']")
        assert has_element?(context.live, "[data-test='copy-setup-hosts']")
        assert has_element?(context.live, "[data-test='copy-network-secret']")
        {:ok, context}
      end
    end
  end
end
