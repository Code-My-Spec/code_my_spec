defmodule CodeMySpecSpex.Story1146.Criterion2383Spex do
  @moduledoc """
  Story 1146 — adding Codex Cloud preserves the existing local machine-token path.

  The existing desktop server's token-authenticated announce is driven over HTTP;
  it must identify the box directly, without a person/device authorization grant.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.DevBoxHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam retains desktop authentication", criterion: 2383 do
    scenario "A Local box starts with its existing machine authorization" do
      given_ "Sam has added his Local desktop box", context do
        {:ok, view, _html} = open_dev_boxes(context.conn, context.project)
        add_dev_box(view, "my-desktop", "local")

        {:ok,
         Map.merge(context, %{
           view: view,
           device_id: box_device_id(view, "my-desktop"),
           token: shown_token(view)
         })}
      end

      when_ "the desktop harness announces itself using the existing token", context do
        {:ok, Map.put(context, :reply, sign_in_with(context.token, "my-desktop"))}
      end

      then_ "the machine is identified without an interactive authorization challenge", context do
        assert context.reply["device_id"] == context.device_id
        refute Map.has_key?(context.reply, "verification_uri")
        refute Map.has_key?(context.reply, "user_code")
        assert has_element?(context.view, "[data-test='setup-local']")
        {:ok, context}
      end
    end
  end
end
