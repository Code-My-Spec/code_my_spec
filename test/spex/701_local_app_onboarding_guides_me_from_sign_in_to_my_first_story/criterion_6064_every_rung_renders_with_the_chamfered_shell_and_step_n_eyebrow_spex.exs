defmodule CodeMySpecSpex.Story701.Criterion6064Spex do
  @moduledoc """
  Story 701 — Local app onboarding guides me from sign-in to my first story.
  Criterion 6064 — Rule: Both ladders use the same chamfered card
  shell and `// step 0N · <name>` eyebrow as the dashboard's
  onboarding ladder so the experience reads as one continuous journey.

  Verified on the per-project ladder where all three rungs are visible
  in pending/active configurations.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_and_log_in_user

  setup context do
    _client_user = Fixtures.client_user_fixture(context.user)
    :ok
  end

  setup :setup_active_account
  setup :setup_active_project

  spex "Every rung renders with the shared shell and a step-N eyebrow" do
    scenario "Every rung renders with the chamfered shell and step-N eyebrow" do
      given_ "the user is on /projects/:p with the per-project ladder active", context do
        {:ok, view, _html} = live(context.conn, ~p"/app/projects/#{context.project.name}")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "each rung carries the shared chamfered shell class", context do
        for rung <- ~w(init-rung project-setup-rung first-story-rung) do
          assert has_element?(context.view, "[data-test='#{rung}'].cms-onboarding"),
                 "expected #{rung} to carry the .cms-onboarding shell class"
        end

        {:ok, context}
      end

      then_ "each rung's eyebrow declares its step number and name", context do
        eyebrows = [
          {"init-rung", 1, "init"},
          {"project-setup-rung", 2, "project setup"},
          {"first-story-rung", 3, "first story"}
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
