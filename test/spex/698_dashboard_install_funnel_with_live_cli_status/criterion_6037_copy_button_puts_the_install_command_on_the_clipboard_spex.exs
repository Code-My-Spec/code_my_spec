defmodule CodeMySpecSpex.Story698.Criterion6037Spex do
  @moduledoc """
  Story 698 — Dashboard install funnel with live CLI status.
  Criterion 6037 — Rule: Each install step is one-click copyable.

  The actual clipboard write is browser-side JS — the spec can't drive
  navigator.clipboard. The contract this spec enforces is: each copy
  button carries the correct command as its clipboard payload (a
  `data-clipboard-text` attribute), so a JS hook can wire navigator
  to it and a UI test (Wallaby, future) can assert the side-effect.

  Surface contract assumed:
    * [data-test="copy-step-1|2|3"][data-clipboard-text="..."]
    * step 1: "/plugin marketplace add Code-My-Spec/plugins"
    * step 2: "/plugin install codemyspec@codemyspec"
    * step 3: "/codemyspec:authenticate"
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "Each install step is one-click copyable" do
    scenario "Copy button puts the install command on the clipboard" do
      given_ "the user is on /app with the onboarding component expanded", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "step 1 carries the marketplace-add command on its copy button", context do
        html = element(context.view, "[data-test='copy-step-1']") |> render()

        assert html =~ "/plugin marketplace add Code-My-Spec/plugins",
               "expected copy-step-1 to carry the marketplace-add command, got: #{html}"

        {:ok, context}
      end

      then_ "step 2 carries the plugin install command on its copy button", context do
        html = element(context.view, "[data-test='copy-step-2']") |> render()

        assert html =~ "/plugin install codemyspec@codemyspec",
               "expected copy-step-2 to carry the plugin-install command, got: #{html}"

        {:ok, context}
      end

      then_ "step 3 carries the authenticate command on its copy button", context do
        html = element(context.view, "[data-test='copy-step-3']") |> render()

        assert html =~ "/codemyspec:authenticate",
               "expected copy-step-3 to carry the authenticate command, got: #{html}"

        {:ok, context}
      end
    end
  end
end
