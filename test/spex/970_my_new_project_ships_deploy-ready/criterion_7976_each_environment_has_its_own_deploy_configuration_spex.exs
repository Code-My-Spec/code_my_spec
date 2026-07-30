defmodule CodeMySpecSpex.Story970.Criterion7976Spex do
  @moduledoc """
  Story 970 — My new project ships deploy-ready
  Criterion 7976 — Each environment has its own deploy configuration.

  A generated project carries one deploy configuration per environment it
  will run, and each names its own host and its own environment
  discriminator. One config with a swapped variable is how a UAT deploy ends
  up pointing at production.

  Surface note: see criterion 7979 — these describe the cms_new generator's
  output, which lives outside the spex boundary.

  Surface: filesystem — the generated project tree.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Each environment has its own deploy configuration" do
    scenario "one config per environment, each naming its own host and discriminator" do
      given_ "Sam generates a project", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view |> element("[data-test='generate-project']") |> render_click()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he looks at its deploy configuration", context do
        {:ok, entries} = Environments.list_directory(context.environment, ".")

        configs =
          Enum.filter(entries, fn path ->
            String.contains?(path, "deploy") and Path.extname(path) in [".yml", ".yaml"]
          end)

        {:ok, Map.put(context, :configs, configs)}
      end

      then_ "there is one configuration per environment he will run", context do
        # Anchor: deploy configuration was generated at all.
        assert length(context.configs) >= 2,
               "expected a deploy configuration per environment, found: #{inspect(context.configs)}"

        {:ok, context}
      end

      then_ "each names its own host and its own environment discriminator", context do
        details =
          Enum.map(context.configs, fn path ->
            {:ok, body} = Environments.read_file(context.environment, path)

            {path, Regex.run(~r/host:\s*(\S+)/, body), Regex.run(~r/APP_ENV:\s*(\S+)/, body)}
          end)

        for {path, host, app_env} <- details do
          assert host != nil,
                 "expected #{path} to name its host"

          assert app_env != nil,
                 "expected #{path} to set its own APP_ENV discriminator"
        end

        hosts = Enum.map(details, fn {_p, host, _e} -> host end)
        envs = Enum.map(details, fn {_p, _h, app_env} -> app_env end)

        assert hosts == Enum.uniq(hosts),
               "expected each environment to have a distinct host, got #{inspect(hosts)}"

        assert envs == Enum.uniq(envs),
               "expected each environment to have a distinct APP_ENV, got #{inspect(envs)}"

        {:ok, context}
      end
    end
  end
end
