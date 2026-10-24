defmodule CodeMySpecSpex.Story1143.Criterion2372Spex do
  @moduledoc """
  Story 1143 — CodeMySpec queues runs, not lock files in my project.
  Criterion 2372 — Sam's second agent asks for the same run.

  A full run under way at the commit Sam is on, with a clean tree, is the
  answer a second request at that commit wants: the second agent waits on it
  rather than starting another. A request against anything else ties to the
  next run (story 1002, criterion 1378).
  """

  # The run is held in the harness's queue by occupying the machine's only
  # analyzer slot (`CmsHarness.AnalysisSlots`, one per node), so it stays under
  # way rather than executing against the template checkout.
  use CodeMySpecSpex.Case, async: false

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.SlotHolder
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Sam's second agent asks for the same run", criterion: 2372 do
    scenario "a second agent asks for the full test run already under way at the same commit" do
      given_ "Sam's checkout is served by a live harness", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "the machine's one analyzer slot is taken", context do
        Application.put_env(:code_my_spec, :analysis_slots, 1)
        on_exit(fn -> Application.delete_env(:code_my_spec, :analysis_slots) end)
        _holder = SlotHolder.occupy()

        {:ok, context}
      end

      given_ "two of Sam's agents are working on it", context do
        first = Fixtures.running_agent(context.scope, role: "coding")
        second = Fixtures.running_agent(context.scope, role: "qa")

        {:ok, Map.merge(context, %{first: first.id, second: second.id})}
      end

      given_ "a full test run is under way at Sam's current commit", context do
        reply = ask_for_tests(context, context.first)
        [_, id] = Regex.run(~r/Run (\d+) admitted/, response_text(reply))
        run_id = String.to_integer(id)

        root = context.harness.root
        disk = Environment.new(:local, root)
        git = &Environments.cmd(disk, "git", &1, cd: root, stderr_to_stdout: true)

        {_, 0} = git.(["add", "-A"])

        {_, 0} =
          git.([
            "-c",
            "user.name=Sam",
            "-c",
            "user.email=sam@example.com",
            "commit",
            "-qm",
            "work"
          ])

        {head, 0} = git.(["rev-parse", "HEAD"])

        :ok =
          HarnessHooks.start_analysis(
            context,
            %{id: run_id, source: "exunit"},
            String.trim(head)
          )

        {:ok, Map.put(context, :run_id, run_id)}
      end

      when_ "the other agent asks for the same run at that commit", context do
        reply = ask_for_tests(context, context.second)
        {:ok, Map.merge(context, %{reply: reply, text: response_text(reply)})}
      end

      then_ "no second run starts and that agent waits on the first", context do
        assert match?({:ok, _}, context.reply), context.text

        assert context.text =~ "Run #{context.run_id} ",
               """
               The second agent's request at the same commit opened a run of its
               own instead of waiting on run #{context.run_id}, which is already
               testing exactly that commit.

               #{context.text}
               """

        {:ok, context}
      end
    end
  end

  defp ask_for_tests(context, agent_id) do
    ToolLibrary.run("start_analysis", %{source: "exunit"}, %{
      scope: context.scope,
      current_scope: context.scope,
      agent_id: agent_id
    })
  end
end
