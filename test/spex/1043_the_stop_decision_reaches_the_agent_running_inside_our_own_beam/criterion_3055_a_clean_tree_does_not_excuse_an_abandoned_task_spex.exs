defmodule CodeMySpecSpex.Story1043.Criterion3055Spex do
  @moduledoc """
  Story 1043 — The stop decision reaches the agent running inside our own BEAM.
  Criterion 3055 — A clean tree does not excuse an abandoned task.

  Rule: An agent that ends a turn with a task still open is told so, whether or
  not anything else blocked.

  The nudge, and it is not the else-branch of the decision. On the external path
  `nudge_open_task/2` fires via `tap/2` on **every** stop that has an open task,
  independently of whether anything blocked, and it is recorded against the
  task's own agent rather than the project's. An agent that stops with a failing
  compile *and* an open task gets both, because they are different things to act
  on.

  John, on why the orchestrator must not simply close it: "the agent should be
  nudged to complete its own task ... it should always be at the agent's
  discretion." So the nudge carries the whole call, task id included — being
  told to make a call and being told to go read about one are different
  instructions, and QA of 985 found the second reads as somewhere to go looking.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  # See criterion 3059's note: `end_turn` re-triggers a full, real analyzer
  # pass, including a real recursive `mix spex` that has nothing to do with
  # this scenario.
  @end_turn_opts [
    compile_output_file: Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl"),
    spex_output_file: Path.expand("test/fixtures/validation/spex_green.jsonl")
  ]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent that ends a turn with a task still open is told so, whether or not anything else blocked" do
    scenario "A clean tree does not excuse an abandoned task" do
      given_ "an agent running under Alloy holding an open task, on a clean tree", context do
        # The manifest is delivered and no finding is: a clean tree is the
        # absence of findings rather than a state to seed, and it is the half of
        # this criterion that makes it distinct. With problems present the agent
        # would be told anyway and the nudge would prove nothing.
        #
        # Said here rather than in a `given_` of its own, because a step that
        # states a precondition and does nothing to establish it is a claim the
        # scenario has not earned — `SpexGivensTest` refuses exactly that, and
        # was right to.
        Fixtures.deliver_manifest(context.scope)

        agent_id = running_agent(context)

        # The task names this agent and lives on somebody else's session, which
        # is the only shape available: a task is embedded in a session, an agent
        # under Alloy has none, and an orchestrator assigning work to one
        # produces exactly this.
        {_story, task_id, _session} =
          Fixtures.qa_story_task_fixture(context.scope, agent_id: agent_id)

        # The premise, asserted — story 988's criterion 8201 does the same and
        # for the same reason. If the agent is not actually holding a task, the
        # scenario proves nothing about being nudged, and a red here would read
        # as the nudge being unbuilt when the setup never held.
        assert Fixtures.open_task_for_agent(context.scope, agent_id),
               "the agent holds no open task, so this scenario has nothing to nudge about"

        {:ok,
         context
         |> Map.put(:agent_id, agent_id)
         |> Map.put(:task_id, task_id)}
      end

      when_ "its turn ends", context do
        :ok =
          use_cmd_cassette "clean", record: :none do
            Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
          end

        {:ok,
         Map.put(context, :told, Fixtures.orchestrator_actions(context.scope, context.agent_id))}
      end

      then_ "it is told the task is still open", context do
        assert context.told != [], """
        The agent ended a turn with work open on a clean tree and heard nothing.
        Nothing blocked, so the decision had nothing to say — and that is
        precisely the case this criterion exists for: an abandoned task is not
        excused by the tree being fine.
        """

        {:ok, context}
      end

      then_ "and it is told which call closes it", context do
        assert Enum.any?(context.told, &(&1 =~ "evaluate_task")), """
        The agent was told its task is open and not how to close it. The nudge
        carries the whole call on purpose — "run evaluate_task for the detail"
        described the agent's own next act as somewhere to go reading, which is
        what QA of story 985 found.

        Got: #{inspect(context.told)}
        """

        {:ok, context}
      end
    end
  end
end
