defmodule CodeMySpecSpex.Story967.Criterion8002Spex do
  @moduledoc """
  Story 967 — My secrets live encrypted in my own repo
  Criterion 8002 — One set of files serves the laptop and the server.

  Running the app locally reads the same encrypted files the deploy reads.
  Sam maintains no second copy of his configuration — which is what
  retiring Varlock buys: one mechanism instead of a local one and a
  deployed one that drift apart.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Sops`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "One set of files serves the laptop and the server" do
    scenario "local runs and deploys read the same encrypted files" do
      given_ "the project has encrypted secrets for its environments", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view
        |> form("[data-test='secret-form']",
          secret: %{key: "DATABASE_URL", value: "ecto://local", environment: "dev"}
        )
        |> render_submit()

        view
        |> form("[data-test='secret-form']",
          secret: %{key: "DATABASE_URL", value: "ecto://prod", environment: "prod"}
        )
        |> render_submit()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam looks at what local runs and deploys each read", context do
        sources =
          context.view
          |> render()
          |> Floki.parse_document!()
          |> Floki.find("[data-test='secret-source']")

        {:ok, Map.put(context, :sources, sources)}
      end

      then_ "both read from the same committed encrypted files", context do
        # Anchor: sources were recorded for both consumers.
        assert length(context.sources) >= 2,
               "expected both the local run and the deploy to declare where they read secrets"

        by_consumer =
          Map.new(context.sources, fn el ->
            {el |> Floki.attribute("data-consumer") |> List.first(),
             el |> Floki.attribute("data-path") |> List.first()}
          end)

        assert Map.has_key?(by_consumer, "local"),
               "expected the local run to declare a secret source"

        assert Map.has_key?(by_consumer, "deploy"),
               "expected the deploy to declare a secret source"

        assert by_consumer["local"] == by_consumer["deploy"],
               "expected one set of files for both, got #{inspect(by_consumer)}"

        {:ok, Map.put(context, :path, by_consumer["local"])}
      end

      then_ "there is no second copy of the configuration to maintain", context do
        {:ok, entries} = Environments.list_directory(context.environment, ".")

        plaintext_env_files =
          Enum.filter(entries, fn path ->
            Path.basename(path) in [".env", ".env.local", ".env.schema"]
          end)

        assert plaintext_env_files == [],
               "expected no parallel plaintext env mechanism, found: #{inspect(plaintext_env_files)}"

        {:ok, context}
      end
    end
  end
end
