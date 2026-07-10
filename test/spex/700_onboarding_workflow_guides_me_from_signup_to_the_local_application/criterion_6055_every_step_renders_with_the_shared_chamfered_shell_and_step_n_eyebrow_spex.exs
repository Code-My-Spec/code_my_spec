defmodule CodeMySpecSpex.Story700.Criterion6055Spex do
  @moduledoc """
  Story 700 — Onboarding workflow guides me from signup to the local application.
  Criterion 6055 — Rule: All four steps share a unified visual shell and a
  step-N eyebrow — so the progression reads as a single ladder.

  Post-redesign (standard daisyUI): each step's root carries the shared
  `card bg-base-100` shell, and each eyebrow declares the step's number and
  name as a "Step N · Name" badge.
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

      then_ "each step's root carries the shared card shell class", context do
        for rung <- ~w(account-rung project-rung plugin-rung application-rung) do
          assert has_element?(context.view, "[data-test='#{rung}'].card"),
                 "expected #{rung} to carry the shared .card shell class"
        end

        {:ok, context}
      end

      then_ "each step's eyebrow declares its step number and name", context do
        eyebrows = [
          {"account-rung", 1, "Account"},
          {"project-rung", 2, "Project"},
          {"plugin-rung", 3, "Plugin"},
          {"application-rung", 4, "Application"}
        ]

        for {rung, n, name} <- eyebrows do
          rendered = element(context.view, "[data-test='#{rung}']") |> render()

          assert rendered =~ "Step #{n}",
                 "expected #{rung} to contain 'Step #{n}'; got: #{rendered}"

          assert rendered =~ name,
                 "expected #{rung} to contain '#{name}'; got: #{rendered}"
        end

        {:ok, context}
      end
    end
  end
end
