defmodule CodeMySpecSpex.Story1018.Criterion2827Spex do
  @moduledoc """
  Story 1018 — A Pi agent starts in a minted working copy on my own subscription.
  Criterion 2827 — Started, seen, stopped.

  Rule: A started agent can be listed and stopped, and never outlives the thing
  that started it.

  Today none of this is answerable from the application. An agent is started by a
  human typing `docker exec -d -u agent … devbox-agent` and supervised by a bash
  loop; CodeMySpec cannot say what is running, cannot stop one, and learns a run
  ended by noticing it stopped reporting. The one Elixir precedent,
  `Workspaces.Runner.Local`, tracks its process by writing a pid to a JSON file and
  asking `kill -0` about it.

  The third assertion is the one that catches a lazy implementation: stopping is
  only useful if it stops the right one. A stop that reaps the whole tree, or that
  kills by name and catches a sibling, passes the first two assertions and is
  worse than no stop at all.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1, response_field: 2]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.ListAgents
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpec.McpServers.Agents.Tools.StopAgent

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "What is running is answerable, and stoppable" do
    scenario "Started, seen, stopped" do
      given_ "Pi agents started on two minted working copies", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, first, _frame} =
          StartAgent.execute(
            %{"engine" => "pi", "provider" => "openai-codex", "working_copy" => "copy-a"},
            frame
          )

        {:reply, second, _frame} =
          StartAgent.execute(
            %{"engine" => "pi", "provider" => "openai-codex", "working_copy" => "copy-b"},
            frame
          )

        refute first.isError
        refute second.isError

        {:ok, context |> Map.put(:first, first) |> Map.put(:second, second)}
      end

      when_ "an engineer asks what is running and stops one of them", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, listing, _frame} = ListAgents.execute(%{}, frame)

        {:reply, stopped, _frame} =
          StopAgent.execute(
            %{"agent_id" => response_field(context.first, "Agent")},
            frame
          )

        {:reply, after_stop, _frame} = ListAgents.execute(%{}, frame)

        {:ok,
         context
         |> Map.put(:listing, listing)
         |> Map.put(:stopped, stopped)
         |> Map.put(:after_stop, after_stop)}
      end

      then_ "both were listed, each against the copy it is working", context do
        text = response_text(context.listing)

        assert text =~ "copy-a" and text =~ "copy-b",
               "asking what is running did not name both agents and their working " <>
                 "copies. This is the question nothing can answer today: an agent is " <>
                 "started by hand and CodeMySpec finds out a run ended by noticing " <>
                 "it stopped reporting. Got: #{text}"

        {:ok, context}
      end

      then_ "the one that was stopped is gone", context do
        refute context.stopped.isError, response_text(context.stopped)

        refute response_text(context.after_stop) =~ "copy-a",
               "the stopped agent is still listed as running. Got: " <>
                 response_text(context.after_stop)

        {:ok, context}
      end

      then_ "the other is still working", context do
        assert response_text(context.after_stop) =~ "copy-b",
               "stopping one agent took the other with it. A stop that reaps the " <>
                 "whole tree, or kills by name and catches a sibling, satisfies " <>
                 "every assertion above and is worse than having no stop at all — " <>
                 "the survivor is the point. Got: #{response_text(context.after_stop)}"

        {:ok, context}
      end
    end
  end
end
