defmodule CodeMySpecSpex.Story1040.Criterion3025Spex do
  @moduledoc """
  Story 1040 — I connect a model provider by pasting its API key
  Criterion 3025 — Sam returns to settings and sees that a key is there, not what it is

  Every credential this app holds is encrypted at rest and none of them are
  rendered — the OAuth ones never could be, because there was never a field
  showing a token. A pasted key arrives through a form, and a form is the one
  shape that invites being filled back in with what it holds.

  Masking is not the bar either: a masked key is still on the wire and still in
  the page source. The page says that a key is there, and nothing else.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account

  spex "I connect a model provider by pasting its API key" do
    scenario "Sam returns to settings and sees that a key is there, not what it is" do
      given_ "he connected Z.ai yesterday", context do
        Fixtures.connect_provider(context.scope, "zai", access_token: "zai-secret-value")
        {:ok, context}
      end

      when_ "he opens his settings today", context do
        {:ok, view, html} = live(context.conn, ~p"/app/users/settings")
        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "Z.ai reads as connected", context do
        assert context.view |> element("[data-test='service-zai']") |> render() =~ "Connected"
        {:ok, context}
      end

      then_ "and the key itself is nowhere on the page", context do
        refute context.html =~ "zai-secret-value",
               "a key rendered back is a key in the page source, masked or not"

        {:ok, context}
      end
    end
  end
end
