defmodule CodeMySpecSpex.Story1040.Criterion3028Spex do
  @moduledoc """
  Story 1040 — I connect a model provider by pasting its API key
  Criterion 3028 — Sam disconnects Z.ai while QA is pointed at it

  A setting can outlive the credential it names. Disconnecting is the ordinary
  way that happens, and a stored row saying "QA runs on Z.ai" after the Z.ai
  key is gone is a page that promises a launch the launcher will refuse.

  Falling back rather than erroring, because the account still has a provider
  and the person has already said what they want when there is a choice —
  making them say it again is asking about something that has not changed.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account

  spex "I connect a model provider by pasting its API key" do
    scenario "Sam disconnects Z.ai while QA is pointed at it" do
      given_ "both providers are connected and QA is pointed at Z.ai", context do
        Fixtures.connect_provider(context.scope, "zai")
        Fixtures.connect_provider(context.scope, "openai")

        {:ok, view, _html} = live(context.conn, ~p"/app/accounts/#{context.account.id}/agents")

        view
        |> form("[data-test='agent-models-form']", %{
          "qa" => %{"provider" => "zai", "model" => "glm-cheap"}
        })
        |> render_submit()

        {:ok, context}
      end

      when_ "he disconnects Z.ai", context do
        conn = delete(context.conn, ~p"/auth/zai")
        {:ok, Map.put(context, :conn, recycle(conn))}
      end

      then_ "Z.ai reads as not connected", context do
        {:ok, view, _html} = live(context.conn, ~p"/app/users/settings")

        refute view |> element("[data-test='service-zai']") |> render() =~ "Connected"

        {:ok, context}
      end

      then_ "and QA runs on what is left, without being set again", context do
        {:ok, view, _html} = live(context.conn, ~p"/app/accounts/#{context.account.id}/agents")

        rendered = view |> element("[data-test='agent-type-qa']") |> render()

        refute rendered =~ "glm-cheap",
               "a setting naming a disconnected provider promises a launch that will be refused"

        assert rendered =~ "default"

        {:ok, context}
      end
    end
  end
end
