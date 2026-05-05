defmodule CodeMySpecSpex.Story127.Criterion5927Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 5927 — mix.exs validity comes from concern-keyed checks
  readable by Setup steps.

  Covers Rule "Validity is determined per file role" for the
  `:mix_exs` role. A mix.exs missing required CodeMySpec deps fails
  the concern-keyed validator; the File row shows up as invalid.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @mix_exs_path "mix.exs"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees a misconfigured mix.exs flagged invalid in the projection" do
    scenario "mix.exs missing required deps is marked invalid after sync" do
      given_ "the agent has written a minimal mix.exs missing CodeMySpec deps",
             context do
        :ok = Environments.write_file(context.environment, @mix_exs_path, mix_exs_missing_deps())
        {:ok, context}
      end

      when_ "the engineer triggers a sync from the Files page", context do
        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the mix.exs row shows the invalid badge", context do
        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@mix_exs_path}\"] [data-validity='invalid']"
               )

        {:ok, context}
      end
    end
  end

  # Has an app name (so app_name extraction succeeds) but no CodeMySpec
  # deps and no boundary/spex compilers — multiple concerns flip to fail
  # in the validation_errors map.
  defp mix_exs_missing_deps do
    """
    defmodule ExampleApp.MixProject do
      use Mix.Project

      def project do
        [
          app: :example_app,
          version: "0.1.0",
          elixir: "~> 1.16",
          deps: deps()
        ]
      end

      def application, do: [extra_applications: [:logger]]

      defp deps, do: []
    end
    """
  end
end
