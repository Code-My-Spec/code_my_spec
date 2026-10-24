defmodule CodeMySpecSpex.Story1143.Criterion2373Spex do
  @moduledoc """
  Story 1143 — CodeMySpec queues runs, not lock files in my project.
  Criterion 2373 — Both of Sam's agents hear the result.

  One agent started the run and the other waits on it; when the harness
  reports the result, each is told, not only the one that asked first.
  """

  # The run is held in the harness's queue by occupying the machine's only
  # analyzer slot (`CmsHarness.AnalysisSlots`, one per node), so it stays under
  # way rather than executing against the template checkout.
  use CodeMySpecSpex.Case, async: false

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.LiveHarness
  alias CmsHarnessTest.SlotHolder
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.HarnessReports
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Both of Sam's agents hear the result", criterion: 2373 do
    scenario "the run two agents wait on ends" do
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
        Fixtures.use_recording_transport(context.scope)
        first = Fixtures.running_agent(context.scope, role: "coding")
        second = Fixtures.running_agent(context.scope, role: "qa")
        Fixtures.mark_present(first)
        Fixtures.mark_present(second)

        {:ok, Map.merge(context, %{first: first.id, second: second.id})}
      end

      given_ "both are waiting on one test run", context do
        reply = ask_for_tests(context, context.first)
        [_, id] = Regex.run(~r/Run (\d+) admitted/, response_text(reply))
        run_id = String.to_integer(id)

        root = context.harness.root
        disk = ExecutionContext.new(:local, root)
        git = &ExecutionContexts.cmd(disk, "git", &1, cd: root, stderr_to_stdout: true)

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

        {:ok, _} = ask_for_tests(context, context.second)

        {:ok, Map.put(context, :run_id, run_id)}
      end

      when_ "the run ends", context do
        root = context.harness.root

        :ok =
          LiveHarness.deliver_analysis_result(
            root,
            context.run_id,
            "exunit",
            HarnessReports.result(root, "exunit", nil)
          )

        {:ok, context}
      end

      then_ "both are told its result", context do
        agents = %{
          context.first => "the agent that started it",
          context.second => "the agent waiting on it"
        }

        told =
          for {agent, who} <- agents do
            receive do
              {:agent_dispatch, ^agent, _ref, message} -> {who, message =~ "exunit"}
            after
              30_000 -> {who, false}
            end
          end

        refute Enum.any?(told, &(not elem(&1, 1))),
               "Run #{context.run_id} ended and not everyone waiting on it was told its result: " <>
                 inspect(told)

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
