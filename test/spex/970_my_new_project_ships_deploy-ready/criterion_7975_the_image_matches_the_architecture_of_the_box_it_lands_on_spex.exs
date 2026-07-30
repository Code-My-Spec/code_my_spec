defmodule CodeMySpecSpex.Story970.Criterion7975Spex do
  @moduledoc """
  Story 970 — My new project ships deploy-ready
  Criterion 7975 — The image matches the architecture of the box it lands on.

  Hetzner's cheap plans are a mix: the ARM64 `cax` line and the amd64
  `cx`/`cpx` line. An image built for one architecture and deployed to the
  other fails at container start, after a deploy that otherwise looked
  healthy. So the built image has to match the box, whichever Sam ends up on.

  Surface note: see criterion 7979 — these describe the cms_new generator's
  output, which lives outside the spex boundary.

  Surface: filesystem for the generated build config, plus a cassette for the
  deploy.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "arm_box_receives_arm_image"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The image matches the architecture of the box it lands on" do
    scenario "an ARM box receives an image that starts" do
      given_ "Sam's server is an ARM box", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view |> element("[data-test='generate-project']") |> render_click()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the image is built and deployed", context do
        html =
          ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='deploy'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the container starts rather than failing on an architecture mismatch", context do
        parsed = Floki.parse_document!(context.html)

        deployment = parsed |> Floki.find("[data-test='deployed-version']")

        # Anchor: a deployment happened.
        assert deployment != [], "expected the deploy to be recorded"

        image_arch = deployment |> Floki.attribute("data-image-arch") |> List.first()
        host_arch = deployment |> Floki.attribute("data-host-arch") |> List.first()

        assert is_binary(image_arch) and is_binary(host_arch),
               "expected the deploy to record both the image and host architecture"

        assert image_arch == host_arch,
               "expected the image architecture to match the host, got image=#{image_arch} host=#{host_arch}"

        {:ok, Map.put(context, :parsed, parsed)}
      end

      then_ "the container did not fail to start", context do
        refute context.html =~ ~r/data-test="container-start"[^>]*data-state="failed"/,
               "expected the container to start on the deployed architecture"

        {:ok, context}
      end

      then_ "the generated build config can target the host's architecture", context do
        {:ok, entries} = Environments.list_directory(context.environment, ".")

        workflow =
          Enum.find(entries, &String.contains?(&1, ".github/workflows"))

        assert workflow != nil, "expected a CI workflow in the generated project"

        {:ok, body} = Environments.read_file(context.environment, workflow)

        assert body =~ ~r/arm64|platforms/,
               "expected the generated workflow to be able to build for the box's architecture, got:\n#{body}"

        {:ok, context}
      end
    end
  end
end
