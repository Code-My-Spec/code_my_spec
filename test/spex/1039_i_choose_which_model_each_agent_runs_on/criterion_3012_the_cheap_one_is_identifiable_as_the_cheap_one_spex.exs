defmodule CodeMySpecSpex.Story1039.Criterion3012Spex do
  @moduledoc """
  Story 1039 — I choose which model each agent runs on
  Criterion 3012 — The cheap one is identifiable as the cheap one

  The reason the setting exists is to run QA on something cheap, and nobody can
  make that choice from model names. `glm-4.6` against `claude-sonnet-5` says
  nothing about which costs more, so a screen that lists only names has not
  given anybody the decision it exists to offer.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I choose which model each agent runs on" do
    scenario "The cheap one is identifiable as the cheap one" do
      given_ "an account that can choose between providers", context do
        Fixtures.connect_provider(context.scope, "zai")
        Fixtures.connect_provider(context.scope, "anthropic")
        {:ok, context}
      end

      when_ "the choices for the QA type are looked at", context do
        {:ok, view, html} = live(context.conn, "/app/accounts/#{context.account.id}/agents")
        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "each choice says what it costs", context do
        assert has_element?(context.view, "[data-test='model-cost']"),
               "the choice this screen exists for cannot be made from model names"

        {:ok, context}
      end

      then_ "and the screen renders the types it is for", context do
        # Anchor: without it the refute-shaped assertion above would pass on a
        # page that failed to render anything at all.
        assert context.html =~ "qa"
        {:ok, context}
      end
    end
  end
end
