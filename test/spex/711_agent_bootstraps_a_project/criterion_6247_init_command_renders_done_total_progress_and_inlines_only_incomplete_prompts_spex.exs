defmodule CodeMySpecSpex.Story711.Criterion6247Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6247 — Init checklist renders done/total progress and exposes
  the incomplete step's prompt at its per-step page.

  When the engineer opens `/projects/:project_name/init` with a scope where
  two of the three init sub-steps are :valid and Init.Auth is :invalid
  (no OAuth credentials seeded), the rendered checklist:
    1. Shows `(2/3)` progress in the page header.
    2. Lists every sub-step name in the menu.
    3. Marks the two done steps with the success badge (`✓`) and the Auth
       step with the ghost badge (`○`).
    4. Links the Auth row to `/projects/:project_name/init/auth`, which —
       on its own per-step page — exposes the Auth sub-step's prompt
       text (the surface equivalent of "Auth is the next actionable" +
       "Auth's prompt is inlined").

  Surface: `InitLive` at `/projects/:project_name/init[/:step]`. The three
  prereq sub-steps shell out via `System.cmd` during the LiveView mount;
  ExCliVcr replays `init_all_prereqs_pass.json` so each probe reports a
  passing version.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Init aggregates sub-steps into one checklist with progress and per-step prompts" do
    scenario "Init checklist shows 2/3 with Auth as the incomplete step, and the Auth page exposes the auth prompt" do
      given_ "the working directory has the full Phoenix project shape (mix.exs, lib/, config/)",
             context do
        CodeMySpecSpex.Fixtures.add_phoenix_project_shape(context.scope)
        {:ok, context}
      end

      given_ "no OAuth credentials are seeded for the active user (Auth will be the only incomplete sub-step)",
             context do
        {:ok, context}
      end

      when_ "the engineer opens the init checklist page", context do
        {checklist_view, checklist_html} =
          use_cmd_cassette "init_all_prereqs_pass", record: :none do
            {:ok, view, html} =
              live(context.conn, ~p"/app/projects/#{context.project.id}/init")

            {view, html}
          end

        {:ok,
         Map.merge(context, %{
           checklist_view: checklist_view,
           checklist_html: checklist_html
         })}
      end

      then_ "the header reports 2/3 progress", context do
        assert context.checklist_html =~ ~r/Project Init\s*<[^>]*>\s*\(\s*2\s*\/\s*3\s*\)/,
               "expected `Project Init (2/3)` in the header, got:\n#{context.checklist_html}"

        {:ok, context}
      end

      and_ "every sub-step name appears in the checklist", context do
        for name <- ["Auth", "Phoenix project", "Cli config"] do
          assert context.checklist_html =~ name,
                 "expected `#{name}` in checklist HTML, got:\n#{context.checklist_html}"
        end

        {:ok, context}
      end

      and_ "the Auth row shows the ghost badge (not done) and the other five show the success badge",
           context do
        auth_row =
          context.checklist_view
          |> element("li", "Auth")
          |> render()

        assert auth_row =~ "badge-ghost",
               "expected Auth row to show the ghost (not-done) badge, got:\n#{auth_row}"

        for name <- ["Phoenix project", "Cli config"] do
          row =
            context.checklist_view
            |> element("li", name)
            |> render()

          assert row =~ "badge-success",
                 "expected `#{name}` row to show the success (done) badge, got:\n#{row}"
        end

        {:ok, context}
      end

      and_ "the Auth row links to /projects/:name/init/auth (the next actionable surface)",
           context do
        assert context.checklist_view
               |> has_element?(
                 ~s|li a[href*="/init/auth"]|,
                 "Auth"
               ),
               "expected Auth row to link to its per-step page"

        {:ok, context}
      end

      and_ "the Auth per-step page exposes the auth prompt", context do
        {:ok, _view, auth_html} =
          use_cmd_cassette "init_all_prereqs_pass", record: :none do
            live(context.conn, ~p"/app/projects/#{context.project.id}/init/auth")
          end

        assert auth_html =~ "badge-warning",
               "expected Auth per-step page to show the not-done badge, got:\n#{auth_html}"

        assert auth_html =~ "Authenticate with CodeMySpec",
               "expected Auth per-step prompt to surface the auth instructions, got:\n#{auth_html}"

        {:ok, context}
      end
    end
  end
end
