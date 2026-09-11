defmodule CodeMySpecSpex.Story1043.Criterion3055Spex do
  @moduledoc """
  Story 1043 — The stop decision reaches the agent running inside our own BEAM.
  Criterion 3055 — A clean tree does not excuse an abandoned task.

  Rule: A continuous agent that ends a turn with a task still open is told so,
  whether or not anything else blocked.

  There used to be a second, separate message for this — `nudge_open_task/2`,
  fired on every stop with an open task independently of the decision beside
  it. John: "non-continuous agents shouldn't get the menu or a nudge at all ...
  this is the purpose of the stop hook menu, and the open task nudge is
  duplicative." The two were folded into one: the menu's own `:task` directive
  now carries the whole thing — the requirement, the id, and why it is still
  open — and a non-continuous agent's clean stop is correctly silent (criterion
  3057), the same as one holding nothing at all. What this criterion asserts is
  narrower than it used to be: a *continuous* agent still hears about its open
  task from the menu on an otherwise-clean stop, because closing it is still
  its job and nothing else will.
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

        agent_id = running_agent(context, %{"continuous" => true})

        # `start_task` is what a real agent calls to claim work, and it goes
        # through `TaskOwner.add_task/3` directly on the agent's own row — no
        # session in the middle. `agent_task_fixture/3` stages the same shape.
        {:ok, agent} = Fixtures.fetch_agent(context.scope, agent_id)
        {_agent, task} = Fixtures.agent_task_fixture(context.scope, agent)

        # The premise, asserted — story 988's criterion 8201 does the same and
        # for the same reason. If the agent is not actually holding a task, the
        # scenario proves nothing about being nudged, and a red here would read
        # as the nudge being unbuilt when the setup never held.
        assert task, "the agent holds no open task, so this scenario has nothing to nudge about"

        {:ok,
         context
         |> Map.put(:agent_id, agent_id)
         |> Map.put(:task_id, task.id)}
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
