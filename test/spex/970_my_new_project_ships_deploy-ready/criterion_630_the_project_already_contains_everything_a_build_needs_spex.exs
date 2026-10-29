defmodule CodeMySpecSpex.Story970.Criterion630Spex do
  @moduledoc """
  Story 970 — My new project ships deploy-ready.
  Criterion 630 — The project already contains everything a build needs.

  Sam generates deploy files through the console. The fresh project tree must
  carry its Dockerfile, release migration, and deploy entry points before
  he edits any of them. The generator lives outside this repository, so this
  checks the files visible through the project's execution context.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ExecutionContexts

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :bootable_deploy_working_directory

  spex "The project already contains everything a build needs", criterion: 630 do
    scenario "a fresh project carries the build and deploy inputs without manual setup" do
      given_ "Sam has generated a new project", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/deploys")

        view |> element("[data-test='generate-project']") |> render_click()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "a build is asked for", context do
        entries = project_tree(context.execution_context)

        contents =
          Map.new(entries, fn path ->
            {path, ExecutionContexts.read_file(context.execution_context, path)}
          end)

        {build_output, build_status} =
          run_generated_application(context, ~s|IO.puts("BUILD_READY")|, ["--no-start"])

        {:ok,
         context
         |> Map.put(:contents, contents)
         |> Map.put(:build_output, build_output)
         |> Map.put(:build_status, build_status)}
      end

      then_ "everything the build needs is already in the project", context do
        health_controller =
          context.contents
          |> Map.keys()
          |> Enum.find(&String.ends_with?(&1, "_web/controllers/health_controller.ex"))

        assert health_controller, "expected a generated health controller"

        for path <- [
              "Dockerfile",
              "rel/overlays/bin/migrate",
              "bin/deploy",
              health_controller
            ] do
          assert match?({:ok, body} when is_binary(body) and body != "", context.contents[path]),
                 "expected generated build input #{path} to exist and contain instructions"
        end

        {:ok, context}
      end

      then_ "Sam has not written build tooling or researched how to containerise the release",
            context do
        {:ok, dockerfile} = Map.fetch!(context.contents, "Dockerfile")
        {:ok, migration} = Map.fetch!(context.contents, "rel/overlays/bin/migrate")

        assert dockerfile =~ "mix release",
               "expected the generated Dockerfile to build a Phoenix release"

        refute Map.has_key?(context.contents, ".github/workflows/build.yml"),
               "the builder builds the image on the burst box at deploy time"

        assert migration =~ "migrate",
               "expected a generated release migration entry point"

        assert context.build_status == 0, context.build_output
        assert context.build_output =~ "BUILD_READY", context.build_output
        refute context.build_output =~ "HealthController.init/1 is undefined"

        {:ok, context}
      end
    end
  end
end
