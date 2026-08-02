defmodule CodeMySpecSpex.Story970.Criterion7974Spex do
  @moduledoc """
  Story 970 — My new project ships deploy-ready
  Criterion 7974 — A fresh project's first push produces an image.

  A generated project pushed to a fresh repo produces a deployable image
  without Sam adding files of his own. The generator ships the Dockerfile and
  the CI workflow, so the very first push is enough — that is what lets the
  setup routine fill in values rather than write build tooling.

  Surface note: see criterion 7979 — these describe the cms_new generator's
  output, which lives outside the spex boundary.

  Surface: filesystem for the generated tree, plus a cassette for the build.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "github_ci_first_push_publishes_image"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "A fresh project's first push produces an image" do
    scenario "the generated project builds and publishes without Sam adding files" do
      given_ "Sam generates a project", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view |> element("[data-test='generate-project']") |> render_click()

        {:ok, entries} = Environments.list_directory(context.environment, ".")

        {:ok, context |> Map.put(:view, view) |> Map.put(:generated, entries)}
      end

      then_ "the build tooling is already present", context do
        # Anchor, and the substance of "without Sam adding files": the two
        # artifacts a first-push build needs must come from the generator.
        assert Enum.any?(context.generated, &(Path.basename(&1) == "Dockerfile")),
               "expected a Dockerfile in the generated project, entries: #{inspect(context.generated)}"

        assert Enum.any?(context.generated, &String.contains?(&1, ".github/workflows")),
               "expected a CI workflow in the generated project, entries: #{inspect(context.generated)}"

        {:ok, context}
      end

      when_ "he pushes it to a fresh repo and the build runs", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='repository'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "a deployable image is published to the registry", context do
        image =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='published-image']")

        assert image != [], "expected the first push to publish an image"

        registry = image |> Floki.attribute("data-registry") |> List.first()
        tag = image |> Floki.attribute("data-tag") |> List.first()

        assert is_binary(registry) and registry != "",
               "expected the image to name the registry it went to"

        assert is_binary(tag) and tag != "",
               "expected the image to carry a tag"

        {:ok, context}
      end

      then_ "Sam added no files of his own to make that happen", context do
        {:ok, now} = Environments.list_directory(context.environment, ".")

        assert now == context.generated,
               "expected the tree to be unchanged from what the generator produced:\n  added: #{inspect(now -- context.generated)}"

        {:ok, context}
      end
    end
  end
end
