defmodule CodeMySpecSpex.Story1051.Criterion2206Spex do
  @moduledoc """
  Story 1051 — Harness startup and restart leave the agent working.
  Criterion 2206 — Resolving a restart fault suppresses the same agent/reason
  until a new restart is recorded; continued silence is not a new incident.

  Restart, observation, and issue lifecycle use the real tool surface. The
  transcript-aging fixture represents elapsed silence without a wall-clock
  wait. No fault or resolved issue is seeded: the first fleet observation
  must produce the fault before the issue tools can accept and resolve it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  import CodeMySpecSpex.HarnessLifecycleHelpers,
    only: [given_a_feature_checkout: 2, start_agent: 1]

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A resolved restart fault needs a new restart before it is raised again",
    criterion: 2206 do
    scenario "Repeated observations of continued silence do not re-file the resolved fault" do
      given_ "a silent agent whose restart fault has been raised and resolved", context do
        context = raised_restart_fault(context)

        {:ok, _} =
          ToolLibrary.run(
            "resolve_issue",
            %{
              issue_id: context.issue_id,
              resolution: "The reported restart incident has been handled."
            },
            %{scope: context.scope}
          )

        {:ok, context}
      end

      when_ "main repeatedly observes the agent without another restart", context do
        observations =
          for _ <- 1..3 do
            {:ok, view} = call(context, "list_agent_work", %{})
            view
          end

        {:ok, Map.put(context, :observations, observations)}
      end

      then_ "the agent remains visible and only the original resolved fault exists", context do
        for view <- context.observations do
          assert response_text({:ok, view}) =~ context.agent_id
        end

        listing = faults(context, "all")
        assert listing["truncated"] == false
        assert listing["matched"] == 1
        assert [%{"id" => id, "status" => "resolved"}] = listing["issues"]
        assert id == context.issue_id
        assert faults(context, "open")["matched"] == 0
        {:ok, context}
      end
    end

    scenario "A new restart permits a new report for the same agent and reason" do
      given_ "a silent agent with a resolved restart fault and a subsequent restart", context do
        context = raised_restart_fault(context)

        {:ok, _} =
          ToolLibrary.run(
            "resolve_issue",
            %{
              issue_id: context.issue_id,
              resolution: "The reported restart incident has been handled."
            },
            %{scope: context.scope}
          )

        {:ok, _} =
          call(context, "restart_agent", %{
            agent_id: context.agent_id,
            reason: context.reason
          })

        {:ok, context}
      end

      when_ "main observes that the new restart has also left the agent silent", context do
        {:ok, view} = call(context, "list_agent_work", %{})
        {:ok, Map.put(context, :observation, view)}
      end

      then_ "the new fault is open and the previous issue stays resolved", context do
        assert response_text({:ok, context.observation}) =~ context.agent_id
        listing = faults(context, "all")
        assert listing["truncated"] == false
        assert listing["matched"] == 2

        original = Enum.find(listing["issues"], &(&1["id"] == context.issue_id))
        assert original["status"] == "resolved"

        open = faults(context, "open")
        assert open["matched"] == 1
        assert [new_fault] = open["issues"]
        refute new_fault["id"] == context.issue_id
        assert new_fault["title"] =~ context.reason
        {:ok, context}
      end
    end
  end

  defp raised_restart_fault(context) do
    context = given_a_feature_checkout(context, "spex_2206")
    agent_id = start_agent(context)
    reason = "agent #{agent_id} stopped answering after its last turn"
    context = Map.merge(context, %{agent_id: agent_id, reason: reason})

    :ok = Fixtures.agent_said(context.scope, %{id: agent_id, role: "coding"}, "starting on it")
    :ok = Fixtures.age_agent_messages(context.scope, %{id: agent_id}, 3 * 60 * 60)
    {:ok, _} = call(context, "restart_agent", %{agent_id: agent_id, reason: reason})
    {:ok, _} = call(context, "list_agent_work", %{})

    %{"matched" => 1, "issues" => [%{"id" => issue_id}]} = faults(context, "open")

    # These are simulated actors in the isolated scenario: product accepts
    # the report and the fixing agent resolves it through their public tools.
    {:ok, _} = call(context, "accept_issue", %{issue_id: issue_id, category: "bug"})

    Map.put(context, :issue_id, issue_id)
  end

  defp faults(context, status) do
    {:ok, listing} =
      ToolLibrary.data(
        "list_issues",
        %{scope: "framework", status: status, query: context.reason},
        %{scope: context.scope}
      )

    listing
  end

  defp call(context, name, params) do
    ToolLibrary.run(name, params, %{scope: context.scope})
  end
end
