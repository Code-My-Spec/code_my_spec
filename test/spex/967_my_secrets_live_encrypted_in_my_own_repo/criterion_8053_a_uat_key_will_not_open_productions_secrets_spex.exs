defmodule CodeMySpecSpex.Story967.Criterion8053Spex do
  @moduledoc """
  Story 967 — My secrets live encrypted in my own repo
  Criterion 8053 — A UAT key will not open production's secrets.

  One key per environment. Someone holding UAT's key cannot decrypt
  production's file, so being able to deploy UAT reveals nothing about
  production. With a single project-wide key, whoever can touch staging can
  read prod — which is the blast radius this criterion exists to close.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Sops`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :real_working_directory

  spex "A UAT key will not open production's secrets" do
    scenario "each environment's file is encrypted to its own key only" do
      given_ "each environment has its own key", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        open_secrets_dialog(view)

        view
        |> form("[data-test='secret-form']",
          secret: %{key: "DATABASE_URL", value: "ecto://uat", environment: "uat"}
        )
        |> render_submit()

        view
        |> form("[data-test='secret-form']",
          secret: %{key: "DATABASE_URL", value: "ecto://prod", environment: "prod"}
        )
        |> render_submit()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the recipients of each environment's file are compared", context do
        recipients =
          context.view
          |> render()
          |> Floki.parse_document!()
          |> Floki.find("[data-test='sops-recipient']")
          |> Enum.group_by(
            &(Floki.attribute(&1, "data-environment") |> List.first()),
            &(Floki.attribute(&1, "data-key-fingerprint") |> List.first())
          )

        {:ok, Map.put(context, :recipients, recipients)}
      end

      then_ "UAT's key is not among production's recipients", context do
        # Anchor: both environments declared recipients at all.
        assert Map.has_key?(context.recipients, "uat"),
               "expected UAT to declare its encryption recipient"

        assert Map.has_key?(context.recipients, "prod"),
               "expected production to declare its encryption recipient"

        uat_keys = MapSet.new(context.recipients["uat"])
        prod_keys = MapSet.new(context.recipients["prod"])

        assert MapSet.disjoint?(uat_keys, prod_keys),
               "expected no shared key between environments, uat=#{inspect(MapSet.to_list(uat_keys))} prod=#{inspect(MapSet.to_list(prod_keys))}"

        {:ok, context}
      end

      then_ "production's file does not name UAT's key as a recipient", context do
        {:ok, prod_file} = Environments.read_file(context.environment, "envs/prod.enc.env")

        for uat_key <- context.recipients["uat"] do
          refute prod_file =~ uat_key,
                 "expected production's file not to be decryptable with UAT's key #{inspect(uat_key)}"
        end

        {:ok, context}
      end
    end
  end
end
