defmodule CodeMySpecSpex.Story1039.Criterion3011Spex do
  @moduledoc """
  Story 1039 — I choose which model each agent runs on
  Criterion 3011 — You cannot choose a provider you have not connected

  A screen offering a provider the account has no key for produces an agent
  that fails on its first model call — minutes later, in a log nobody reads.
  `Agents`' own moduledoc says the credential ordering exists to prevent
  exactly that, and a settings screen can reintroduce it from the front.

  Absent is not the same as refused: hiding an unconnected provider makes it
  indistinguishable from one that does not exist, so somebody goes looking for
  a feature that is right there waiting to be connected.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I choose which model each agent runs on" do
    scenario "You cannot choose a provider you have not connected" do
      given_ "the account has a key for one provider only", context do
        Fixtures.connect_provider(context.scope, "zai")
        {:ok, context}
      end

      when_ "the choices for the QA type are looked at", context do
        {:ok, view, html} = live(context.conn, "/app/accounts/#{context.account.id}/agents")
        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "the connected provider can be chosen", context do
        assert has_element?(context.view, "[data-test='provider-zai']")
        refute has_element?(context.view, "[data-test='provider-zai'][disabled]")
        {:ok, context}
      end

      then_ "and the unconnected one is shown but cannot be", context do
        assert has_element?(context.view, "[data-test='provider-anthropic'][disabled]"),
               "an unconnected provider that is simply gone reads as one that does not exist"

        assert context.html =~ "connect"
        {:ok, context}
      end
    end
  end
end
