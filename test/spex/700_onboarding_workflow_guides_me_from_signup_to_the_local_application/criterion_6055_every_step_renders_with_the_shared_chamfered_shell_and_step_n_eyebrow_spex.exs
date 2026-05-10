defmodule CodeMySpecSpex.Story700.Criterion6055Spex do
  @moduledoc """
  Story 700 — Onboarding workflow guides me from signup to the local application.
  Criterion 6055 — Rule: All four steps share a unified visual shell
  — same chamfered card surface and a "// step 0N · <name>" eyebrow
  — so the progression reads as a single ladder.

  Each step's root carries the shared `cms-onboarding` class, and
  each eyebrow declares the step's number and name in the standard
  `// step 0N · <name>` form.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  spex "Every step renders with the shared shell and a step-N eyebrow" do
    scenario "Every step renders with the shared chamfered shell and step-N eyebrow" do
      given_ "the user is on /app with all four steps rendered", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "each step's root carries the shared chamfered shell class", context do
        for rung <- ~w(account-rung project-rung plugin-rung application-rung) do
          assert has_element?(context.view, "[data-test='#{rung}'].cms-onboarding"),
                 "expected #{rung} to carry the .cms-onboarding shell class"
        end

        {:ok, context}
      end

      then_ "each step's eyebrow declares its step number and name", context do
        eyebrows = [
          {"account-rung", 1, "account"},
          {"project-rung", 2, "project"},
          {"plugin-rung", 3, "plugin"},
          {"application-rung", 4, "application"}
        ]

        for {rung, n, name} <- eyebrows do
          rendered = element(context.view, "[data-test='#{rung}']") |> render()

          padded = String.pad_leading("#{n}", 2, "0")

          assert rendered =~ "// step #{padded}",
                 "expected #{rung} to contain '// step #{padded}'; got: #{rendered}"

          assert rendered =~ name,
                 "expected #{rung} to contain '#{name}'; got: #{rendered}"
        end

        {:ok, context}
      end
    end
  end
end
