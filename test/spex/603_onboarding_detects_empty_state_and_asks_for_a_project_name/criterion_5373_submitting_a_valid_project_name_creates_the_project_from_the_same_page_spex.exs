defmodule CodeMySpecSpex.Story603.Criterion5373Spex do
  @moduledoc """
  Story 603 — Onboarding detects empty state and asks for a project name
  Criterion 5373 — Rule: Submitting a valid project name creates the
  project in place.

  Observable: submitting a non-empty project-name on /app/onboarding
  results in a navigation away from the onboarding page (the next step
  out of onboarding) — the user is NOT routed through any separate
  "/projects/new" or similar form en route. Whether they land on
  `/app` or some other ready-to-work view is asserted in story 604.
  Here we just confirm the onboarding form is the one and only form
  involved in creating the first project.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  spex "Submitting a valid project name creates the project from the same page" do
    scenario "Submitting a valid project name creates the project from the same page" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      when_ "they submit the project-name form with a non-empty value", context do
        result =
          context.view
          |> form("#project_form", project: %{name: "My First Project"})
          |> render_submit()

        {:ok, Map.put(context, :submit_result, result)}
      end

      then_ "the submit produces a navigation rather than a fresh form", context do
        # render_submit returns either the new HTML (if the LiveView didn't
        # navigate) or a tuple/raise representing the navigation. We pattern-
        # match against the live navigation that `assert_redirect` /
        # `assert_redirected` would observe.
        assert {:error, {kind, %{to: target}}} =
                 catch_navigation(context.view, context.submit_result),
               "expected a live_redirect or live_patch out of /app/onboarding " <>
                 "after submitting a valid project name"

        assert kind in [:redirect, :live_redirect],
               "expected a redirect-style navigation, got: #{inspect(kind)}"

        refute target =~ ~r"/projects/new",
               "expected NOT to be routed through a separate '/projects/new' form, " <>
                 "got: #{target}"

        refute target == "/app/onboarding",
               "expected to be navigated AWAY from /app/onboarding after creation, " <>
                 "got: #{target}"

        {:ok, context}
      end
    end
  end

  # If render_submit triggered a navigation, the live process has died with
  # a redirect reason. Catch it here without depending on internal LiveView
  # test helpers. Returns `{:error, {kind, %{to: target}}}` on navigation,
  # or the original render result if the LV stayed put.
  defp catch_navigation(view, render_result) do
    case render_result do
      {:error, _} = err -> err
      _other -> Phoenix.LiveViewTest.assert_redirect(view)
    end
  rescue
    e in [ExUnit.AssertionError] -> reraise e, __STACKTRACE__
  end
end
