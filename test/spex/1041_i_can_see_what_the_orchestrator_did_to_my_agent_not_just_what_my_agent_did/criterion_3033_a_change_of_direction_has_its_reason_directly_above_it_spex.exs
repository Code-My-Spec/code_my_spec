defmodule CodeMySpecSpex.Story1041.Criterion1107Spex do
  @moduledoc """
  Story 1041 — I can see what the orchestrator did to my agent, not just what
  my agent did.
  Criterion 1107 — A change of direction has its reason directly above it.

  The change of direction is Main force-releasing a team's active story and
  giving the team another. Before this, the agents on that copy were told
  nothing: their task on the old story stayed open and their next message was
  about the new one, with no line saying why the work changed (story 1147,
  force-moved off copy ccccc328, 2026-10-26).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  defp run(tool, params, scope, agent_id),
    do: ToolLibrary.run(tool, params, %{scope: scope, agent_id: agent_id})

  defp ok!(response) do
    assert match?({:ok, _}, response), response_text(response)
    response_text(response)
  end

  spex "A change of direction has its reason directly above it", criterion: 1107 do
    scenario "Main takes a team's story away and gives it another" do
      given_ "a coding agent on a team copy, working a task on one story", context do
        main_scope = context.scope
        :ok = Fixtures.designate_main(main_scope, main_scope.active_working_copy_id)
        main = Fixtures.running_agent(main_scope, role: "main")

        team_scope = Fixtures.live_agent_scope(main_scope, label: "team copy")
        copy = %{id: team_scope.active_working_copy_id}
        coder = Fixtures.running_agent(team_scope, role: "coding")

        first = Fixtures.released_story(main_scope, "Border dispute")
        second = Fixtures.released_story(main_scope, "Trade embargo")

        ok!(
          run(
            "set_active_story",
            %{story_number: first.number, working_copy_id: copy.id},
            main_scope,
            main.id
          )
        )

        started =
          ok!(
            run(
              "start_task",
              %{
                requirement_name: "bdd_specs_exist",
                entity_type: "story",
                entity_id: to_string(first.number)
              },
              team_scope,
              coder.id
            )
          )

        [_, task_id] = Regex.run(~r/Task ID: `([0-9a-f-]{36})`/, started)

        {:ok,
         Map.merge(context, %{
           main: main,
           main_scope: main_scope,
           copy: copy,
           coder: coder,
           team_scope: team_scope,
           first: first,
           second: second,
           task_id: task_id
         })}
      end

      when_ "Main force-releases that story and gives the team another", context do
        ok!(
          run(
            "release_story_from_working_copy",
            %{story_number: context.first.number, force: true},
            context.main_scope,
            context.main.id
          )
        )

        ok!(
          run(
            "set_active_story",
            %{story_number: context.second.number, working_copy_id: context.copy.id},
            context.main_scope,
            context.main.id
          )
        )

        {:ok, context}
      end

      then_ "the agent's transcript says its story was taken and its task cancelled, before the new work",
            context do
        transcript =
          ok!(
            run(
              "read_agent_conversation",
              %{agent_id: context.coder.id},
              context.main_scope,
              context.main.id
            )
          )

        taken = "story #{context.first.number} was released from this copy"

        assert transcript =~ taken,
               "nothing in the agent's own transcript says its story was taken away:\n#{transcript}"

        assert transcript =~ "task #{context.task_id} cancelled",
               "the transcript does not name the task that was cancelled:\n#{transcript}"

        [above, _below] = String.split(transcript, taken, parts: 2)

        refute above =~ "story #{context.second.number}",
               "the new story appears above the reason the old one went:\n#{transcript}"

        {:ok, context}
      end

      then_ "the cancelled task is shown as cancelled, so nobody has to look elsewhere for why",
            context do
        tasks =
          ok!(run("list_tasks", %{status: "cancelled"}, context.team_scope, context.coder.id))

        assert tasks =~ context.task_id,
               "the task on the released story is not cancelled:\n#{tasks}"

        {:ok, context}
      end
    end
  end
end
