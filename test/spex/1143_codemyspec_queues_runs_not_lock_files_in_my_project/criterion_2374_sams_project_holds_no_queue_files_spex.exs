defmodule CodeMySpecSpex.Story1143.Criterion2374Spex do
  @moduledoc """
  Story 1143 — CodeMySpec queues runs, not lock files in my project.
  Criterion 2374 — Sam's project holds no queue files.

  Queuing is CodeMySpec's. After several requested runs, Sam's checkout holds
  none of what the old in-project queue left behind: a lock file, caller
  files, or a cache of every run's events.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.LiveHarness
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

  # `fail_on_error_logs: false`: the live harness really runs what is requested,
  # and this checkout has no test tooling, so each run is refused and its late
  # answer rejected (the result was already delivered). Those logs are the
  # harness working; this criterion is about the files left behind.
  spex "Sam's project holds no queue files", criterion: 2374, fail_on_error_logs: false do
    scenario "after several runs, nothing in the checkout queues them" do
      given_ "Sam's checkout is served by a live harness", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "Sam's agents have requested several runs", context do
        root = context.harness.root

        for {role, source} <- [{"coding", "exunit"}, {"qa", "exunit"}, {"coding", "spex"}] do
          agent = Fixtures.running_agent(context.scope, role: role)

          reply =
            ToolLibrary.run("start_analysis", %{source: source}, %{
              scope: context.scope,
              current_scope: context.scope,
              agent_id: agent.id
            })

          [_, id] = Regex.run(~r/Run (\d+) admitted/, response_text(reply))

          :ok =
            LiveHarness.deliver_analysis_result(
              root,
              String.to_integer(id),
              source,
              HarnessReports.result(root, source, nil)
            )
        end

        {:ok, context}
      end

      when_ "Sam looks in his project", context do
        root = context.harness.root

        found =
          [
            ".code_my_spec/internal/agent_test.lock.json",
            ".code_my_spec/internal/callers",
            ".code_my_spec/internal/agent_test_events.json"
          ]
          |> Enum.filter(&ExecutionContexts.file_exists?(ExecutionContext.new(:local, root), &1))

        {:ok, Map.put(context, :found, found)}
      end

      then_ "there are no lock or caller files queuing runs", context do
        assert context.found == [],
               "Sam's checkout holds in-project queue files: #{inspect(context.found)}"

        {:ok, context}
      end
    end
  end
end
