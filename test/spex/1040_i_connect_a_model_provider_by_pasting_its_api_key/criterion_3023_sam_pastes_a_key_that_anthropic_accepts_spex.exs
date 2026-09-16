defmodule CodeMySpecSpex.Story1040.Criterion3023Spex do
  @moduledoc """
  Story 1040 — I connect a model provider by pasting its API key
  Criterion 3023 — Sam pastes a key that Anthropic accepts

  A pasted key proves nothing on its own. An OAuth grant is checked by the
  exchange that produces it; a key is a string somebody typed, and storing it
  unasked means the settings page reports a connection whose first evidence
  arrives when an agent fails a model call minutes later.

  So the assertion is not only that Anthropic ends up connected — it is that
  Anthropic was asked, before anything was written.
  """

  use CodeMySpecSpex.Case

  cloud_endpoint()

  setup :register_log_in_setup_account

  spex "I connect a model provider by pasting its API key" do
    scenario "Sam pastes a key that Anthropic accepts" do
      given_ "Anthropic will accept the key, and says so when asked", context do
        CodeMySpecSpex.Fixtures.stub_accepting_and_noting_host(
          CodeMySpec.Integrations.Providers.ApiKey,
          self()
        )

        {:ok, context}
      end

      when_ "he pastes his Anthropic key and saves", context do
        {:ok, view, _html} = live(context.conn, ~p"/app/users/settings")

        view
        |> form("[data-test='api-key-form-anthropic']", %{
          "api_key" => %{"key" => "sk-ant-real-key"}
        })
        |> render_submit()

        {:ok, Map.put(context, :view, view)}
      end

      then_ "Anthropic was asked about the key", context do
        assert_received {:asked, host}

        assert host =~ "anthropic",
               "a key stored without asking the provider reports a connection nobody verified"

        {:ok, context}
      end

      then_ "and Anthropic reads as connected", context do
        assert context.view
               |> element("[data-test='service-anthropic']")
               |> render() =~ "Connected"

        {:ok, context}
      end
    end
  end
end
