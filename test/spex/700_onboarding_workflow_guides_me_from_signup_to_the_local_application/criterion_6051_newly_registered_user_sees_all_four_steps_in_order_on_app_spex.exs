defmodule CodeMySpecSpex.Story700.Criterion6051Spex do
  @moduledoc """
  Story 700 — Onboarding workflow guides me from signup to the local application.
  Criterion 6051 — Rule: The dashboard presents four onboarding
  steps in a fixed order: account, project, plugin, application.

  A newly-registered user with no account, no project, and no CLI
  history must see all four step rungs on /app, in order, with the
  expected eyebrow text on each.

  Surface contract assumed:
    * [data-test="account-rung"], [data-test="project-rung"],
      [data-test="plugin-rung"], [data-test="application-rung"]
    * Each rung's eyebrow contains "// step 0N · <name>" matching its
      position (01 · account, 02 · project, 03 · plugin, 04 · application)
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  spex "All four onboarding steps render on /app in the fixed order" do
    scenario "Newly registered user sees all four steps in order on /app" do
      given_ "the user has just registered with no account, no project, no CLI history",
             context do
        {:ok, view, html} = live(context.conn, "/app")
        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "all four step rungs are present", context do
        for rung <- ~w(account-rung project-rung plugin-rung application-rung) do
          assert has_element?(context.view, "[data-test='#{rung}']"),
                 "expected [data-test='#{rung}'] to be present on /app"
        end

        {:ok, context}
      end

      then_ "the steps appear in document order", context do
        order =
          ~w(account-rung project-rung plugin-rung application-rung)
          |> Enum.map(fn rung ->
            {rung, :binary.match(context.html, ~s|data-test="#{rung}"|)}
          end)

        positions = Enum.map(order, fn {_, m} -> m end)

        refute :nomatch in positions,
               "all four rungs must appear in the initial render; got: #{inspect(order)}"

        sorted = Enum.sort_by(order, fn {_, {at, _}} -> at end)

        assert Enum.map(sorted, fn {rung, _} -> rung end) ==
                 ~w(account-rung project-rung plugin-rung application-rung),
               "expected document order account → project → plugin → application; got: #{inspect(sorted)}"

        {:ok, context}
      end

      then_ "each rung's eyebrow declares its step number and name", context do
        eyebrows = %{
          "account-rung" => {1, "account"},
          "project-rung" => {2, "project"},
          "plugin-rung" => {3, "plugin"},
          "application-rung" => {4, "application"}
        }

        for {rung, {n, name}} <- eyebrows do
          rendered = element(context.view, "[data-test='#{rung}']") |> render()

          padded = String.pad_leading("#{n}", 2, "0")

          assert rendered =~ "step #{padded}",
                 "expected #{rung} eyebrow to contain 'step #{padded}'; got: #{rendered}"

          assert rendered =~ name,
                 "expected #{rung} eyebrow to contain '#{name}'; got: #{rendered}"
        end

        {:ok, context}
      end
    end
  end
end
