defmodule CodeMySpecSpex.Story1040.Criterion3024Spex do
  @moduledoc """
  Story 1040 — I connect a model provider by pasting its API key
  Criterion 3024 — Sam pastes a key with a character missing off the end

  The failure the check exists for. A short paste is the ordinary way a key
  goes wrong, and it is indistinguishable from a good one by looking at it.

  Two things have to hold and they are separate: nothing is stored, so the
  page does not claim a connection; and the message says the provider refused
  the key, because "something went wrong" sends someone to look at us instead
  of at their clipboard.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "I connect a model provider by pasting its API key" do
    scenario "Sam pastes a key with a character missing off the end" do
      given_ "Anthropic refuses the key it is handed", context do
        Req.Test.stub(CodeMySpec.Integrations.Providers.ApiKey, fn conn ->
          conn
          |> Plug.Conn.put_status(401)
          |> Req.Test.json(%{"error" => %{"message" => "invalid x-api-key"}})
        end)

        {:ok, context}
      end

      when_ "he pastes the truncated key and saves", context do
        {:ok, view, _html} = live(context.conn, ~p"/app/users/settings")

        html =
          view
          |> form("[data-test='api-key-form-anthropic']", %{
            "api_key" => %{"key" => "sk-ant-real-ke"}
          })
          |> render_submit()

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "Anthropic still reads as not connected", context do
        refute context.view
               |> element("[data-test='service-anthropic']")
               |> render() =~ "Connected"

        {:ok, context}
      end

      then_ "and he is told the provider rejected it", context do
        assert context.html =~ "Anthropic rejected"

        {:ok, context}
      end
    end
  end
end
