defmodule CodeMySpecSpex.Story1040.Criterion3022Spex do
  @moduledoc """
  Story 1040 — I connect a model provider by pasting its API key
  Criterion 3022 — Sam connects Z.ai by pasting the key from its console

  Every other provider on this page proves its credential by completing an
  OAuth exchange, and Z.ai issues a key instead. Until there is somewhere to
  paste one, `Agents.Providers` offers a provider `Integrations` has no door
  for, and every agent type falls through to the one subscription an account
  can actually connect.

  Driven through the page rather than the context, because a connection nobody
  can make from the screen is the state this criterion exists to end.
  """

  use CodeMySpecSpex.Case

  setup :register_log_in_setup_account

  spex "I connect a model provider by pasting its API key", criterion: 1097 do
    scenario "Sam connects Z.ai by pasting the key from its console" do
      given_ "Z.ai will accept the key it is handed", context do
        Req.Test.stub(CodeMySpec.Integrations.Providers.ApiKey, fn conn ->
          Req.Test.json(conn, %{"ok" => true})
        end)

        {:ok, context}
      end

      when_ "he pastes the key from Z.ai's console into his settings and saves", context do
        {:ok, view, _html} = live(context.conn, ~p"/app/users/settings")

        html =
          view
          |> form("[data-test='api-key-form-zai']", %{"api_key" => %{"key" => "zai-live-key"}})
          |> render_submit()

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "Z.ai reads as connected, beside the rest", context do
        assert has_element?(context.view, "[data-test='service-zai']")

        assert context.view |> element("[data-test='service-zai']") |> render() =~ "Connected"

        {:ok, context}
      end
    end

    scenario "Sam's Z.ai key is real but the account has no balance" do
      given_ "Z.ai answers the check with 429 code 1113, its own way of saying a real key " <>
               "has nothing to spend",
             context do
        Req.Test.stub(CodeMySpec.Integrations.Providers.ApiKey, fn conn ->
          conn
          |> Plug.Conn.put_status(429)
          |> Req.Test.json(%{
            "error" => %{
              "code" => "1113",
              "message" => "Insufficient balance or no resource package."
            }
          })
        end)

        {:ok, context}
      end

      when_ "he pastes the key from Z.ai's console into his settings and saves", context do
        {:ok, view, _html} = live(context.conn, ~p"/app/users/settings")

        html =
          view
          |> form("[data-test='api-key-form-zai']", %{"api_key" => %{"key" => "zai-live-key"}})
          |> render_submit()

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "the key is saved, Z.ai reads as connected, and he is told it has no balance",
            context do
        assert has_element?(context.view, "[data-test='service-zai']")

        assert context.view |> element("[data-test='service-zai']") |> render() =~ "Connected"

        assert context.html =~ "no balance",
               "a real key on an unfunded account is accepted, not refused -- but the " <>
                 "person has to be told agents will not run on it until it is funded"

        {:ok, context}
      end
    end
  end
end
