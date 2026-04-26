defmodule CodeMySpecSpex.Story603.Criterion5371Spex do
  @moduledoc """
  Story 603 — Onboarding detects empty state and asks for a project name
  Criterion 5371 — Rule: The project-name input is presented at the top
  of /app/onboarding alongside the install instructions, not buried below
  them.

  Observed via the rendered HTML — the project-name input must appear
  before the install instructions in document order.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import_givens CodeMySpecSpex.SharedGivens

  spex "The project-name input appears alongside the install instructions" do
    scenario "The project-name input appears alongside the install instructions" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      then_ "the project-name input is positioned before the install instructions",
            context do
        html = context.html

        input_pos =
          case Regex.run(~r/<input[^>]*name="project\[name\]"/, html, return: :index) do
            [{start, _}] -> start
            _ -> flunk("expected a project-name input on the onboarding page")
          end

        install_pos =
          case Regex.run(~r/plugin marketplace add/i, html, return: :index) do
            [{start, _}] -> start
            _ -> flunk("expected install instructions on the onboarding page")
          end

        assert input_pos < install_pos,
               "expected the project-name input (offset #{input_pos}) to appear before " <>
                 "the install instructions (offset #{install_pos}) — must not be buried below"

        :ok
      end

      then_ "the input is part of the same onboarding view, not behind a link",
            context do
        # The input is rendered in the initial mount HTML (no click-through).
        assert has_element?(context.view, "input[name='project[name]']"),
               "expected the input to be rendered inline on the onboarding page"

        :ok
      end
    end
  end
end
