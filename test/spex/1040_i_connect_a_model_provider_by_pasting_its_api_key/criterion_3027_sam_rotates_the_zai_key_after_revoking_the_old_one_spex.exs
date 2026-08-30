defmodule CodeMySpecSpex.Story1040.Criterion3027Spex do
  @moduledoc """
  Story 1040 — I connect a model provider by pasting its API key
  Criterion 3027 — Sam rotates the Z.ai key after revoking the old one

  Rotation is the ordinary reason to paste a key twice, and it is the case a
  connect flow gets wrong by insisting the provider is already connected — or
  by adding a second row, so which of two keys an agent starts on becomes a
  question about insert order.

  `integrations` is unique on (user_id, provider) and upserts, which is what
  makes one connection the only possible outcome. This says it from the page.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account

  spex "I connect a model provider by pasting its API key" do
    scenario "Sam rotates the Z.ai key after revoking the old one" do
      given_ "Z.ai is connected on the key he has just revoked", context do
        Fixtures.connect_provider(context.scope, "zai", access_token: "zai-revoked-key")
        {:ok, context}
      end

      given_ "Z.ai will accept the replacement", context do
        Req.Test.stub(CodeMySpec.Integrations.Providers.ApiKey, fn conn ->
          Req.Test.json(conn, %{"ok" => true})
        end)

        {:ok, context}
      end

      when_ "he pastes the new key and saves", context do
        {:ok, view, _html} = live(context.conn, ~p"/app/users/settings")

        html =
          view
          |> form("[data-test='api-key-form-zai']", %{"api_key" => %{"key" => "zai-rotated-key"}})
          |> render_submit()

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "there is still exactly one Z.ai connection", context do
        rows =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='service-zai']")

        assert length(rows) == 1,
               "a second row makes which key an agent starts on a question about insert order"

        {:ok, context}
      end

      then_ "and it is still connected, rather than refused for already being so", context do
        assert context.view |> element("[data-test='service-zai']") |> render() =~ "Connected"
        {:ok, context}
      end
    end
  end
end
