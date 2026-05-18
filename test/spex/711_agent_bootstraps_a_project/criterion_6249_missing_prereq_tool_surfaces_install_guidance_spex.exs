defmodule CodeMySpecSpex.Story711.Criterion6249Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6249 — Missing prereq tool surfaces install guidance.

  When the engineer opens the PhoenixInstaller init step's per-step page
  against a toolchain where `mix phx.new --version` returns a non-zero
  exit, the page renders the step with a "Not done" badge whose detail
  text names the `mix archive.install hex phx_new` remediation, and the
  per-step prompt block surfaces the install command.

  Surface: `InitLive` at `/projects/:project_name/init/phoenix_installer`.
  ExCliVcr replays `init_phx_installer_missing.json` so the test doesn't
  depend on the host having or lacking the phx_new archive.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "PhoenixInstaller surfaces install guidance when phx_new is missing" do
    scenario "Missing prereq tool surfaces install guidance" do
      given_ "the active toolchain has no phx_new archive installed",
             context do
        {:ok, context}
      end

      when_ "the engineer opens the PhoenixInstaller per-step page", context do
        {view, html} =
          use_cmd_cassette "init_phx_installer_missing", record: :none do
            {:ok, view, html} =
              live(
                context.conn,
                ~p"/projects/#{context.project.name}/init/phoenix_installer"
              )

            {view, html}
          end

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the step shows the Not done badge naming the install remediation", context do
        assert context.html =~ "badge-warning",
               "expected the not-done badge on the PhoenixInstaller per-step page, got:\n#{context.html}"

        assert context.html =~ ~r/mix archive\.install hex phx_new/,
               "expected the detail to name `mix archive.install hex phx_new`, got:\n#{context.html}"

        {:ok, context}
      end

      and_ "the per-step prompt block surfaces the install command", context do
        assert context.view |> has_element?(~s|pre|),
               "expected a <pre> prompt block on a not-done step"

        prompt_text =
          context.view
          |> element(~s|pre|)
          |> render()

        assert prompt_text =~ ~r/mix archive\.install hex phx_new/,
               "expected the prompt to contain the install command, got:\n#{prompt_text}"

        {:ok, context}
      end
    end
  end
end
