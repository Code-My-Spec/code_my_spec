defmodule CodeMySpecSpex.Story813.Criterion6554Spex do
  @moduledoc """
  Story 813 — Non-technical user watches the agent work in a live progress view.
  Criterion 6554 — Rule (curated arm): major task types show curated
  plain-language help with a video when one exists.

  Surface (forward-looking): `CodeMySpecLocalWeb.AgentProgressLive` at
  `/projects/:project_name/progress`, backed by the `CodeMySpec.TaskHelp`
  context which reads `.code_my_spec/content/<task_type>.md` (body) plus its
  `.yaml` sidecar (`video_url`). We write a help file for the
  `architecture_design` task type into the in-memory environment, focus an
  ArchitectureDesign task, and assert the curated body and the video render.

  Contract: `[data-test="task-help-video"]` carries the sidecar's video URL.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  @video_url "https://videos.example.com/architecture-design.mp4"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Major task shows curated help and video" do
    scenario "a major task type renders its curated help body and video" do
      given_ "curated help content exists for the architecture_design task type",
             context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/content/help/architecture_design.md",
            """
            # Designing your architecture

            In this step the agent maps your stories to the contexts and
            modules that will satisfy them.
            """
          )

        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/content/help/architecture_design.yaml",
            """
            video_url: "#{@video_url}"
            """
          )

        {:ok, context}
      end

      given_ "an active architecture_design task is in progress", context do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        earlier = DateTime.add(now, -3600, :second)
        project_id = context.scope.active_project_id

        task_id = Ecto.UUID.generate()

        session =
          Fixtures.session_fixture(context.scope, %{
            type: CodeMySpec.AgentTasks.ArchitectureDesign,
            status: :active,
            inserted_at: earlier,
            updated_at: now,
            tasks: [
              %{
                id: task_id,
                status: :active,
                requirement_name: "architecture_designed",
                session_type: CodeMySpec.AgentTasks.ArchitectureDesign,
                project_id: project_id,
                started_at: earlier
              }
            ]
          })

        {:ok, Map.merge(context, %{task_id: task_id, session_id: session.id})}
      end

      when_ "the user opens the progress view", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/progress")

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the curated help body and video render in the help pane", context do
        assert render(context.view) =~ "Designing your architecture",
               "expected the curated help body to render while the task is focused"

        assert has_element?(context.view, "[data-test='task-help-video']"),
               "expected a help video to render for the focused major task"

        {:ok, context}
      end

      then_ "the help video points at the sidecar's video URL", context do
        assert render(context.view) =~ @video_url,
               "expected the curated video URL from the .yaml sidecar to render"

        {:ok, context}
      end
    end
  end
end
