defmodule CodeMySpecSpex.Story1017.Criterion2062Spex do
  @moduledoc """
  Story 1017 — Agent sees the questions it has open.
  Criterion 2062 — Teammates' questions reach main.

  A coding or QA agent's ordinary question — not marked `about: "criteria"`,
  naming neither `product` nor `main` as `to:` — is main's by default (story
  1052, `Agents.Main.holder_for/4`'s `target/2`). It reaches the project's
  running main agent the same way a criteria question reaches product
  (criterion 1612).
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "Teammates' questions reach main", criterion: 2062 do
    scenario "A coder asks an ordinary question, naming neither product nor main" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous main agent, and a coder holding a story's task", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Refund policy",
            description: "A story the coder is mid-way through",
            acceptance_criteria: ["The stated behavior is implemented"]
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        coder_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}

        started =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(story.number)
            },
            Map.put(coder_frame.assigns, :scope, coder_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, started), response_text(started)

        {:ok,
         Map.merge(context, %{
           main: main,
           coder_frame: coder_frame,
           coder_task: extract_task_id!(started)
         })}
      end

      when_ "the coder asks a question about something other than a story's criteria", context do
        asked =
          ToolLibrary.run(
            "ask_question",
            %{
              task_id: context.coder_task,
              questions: [
                %{
                  question: "Which Ecto adapter does this project's test config actually use?",
                  options: [%{label: "Keep current behavior"}, %{label: "Change behavior"}]
                }
              ]
            },
            Map.put(
              context.coder_frame.assigns,
              :scope,
              context.coder_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, asked), response_text(asked)
        {:ok, context}
      end

      then_ "that question reaches the running main agent, not product or the user", context do
        main_id = context.main.id

        assert_receive {:work_turn_requested, ^main_id, _ref, prompt}, 2_000
        assert prompt =~ "answer_notification"
        {:ok, context}
      end
    end
  end
end
