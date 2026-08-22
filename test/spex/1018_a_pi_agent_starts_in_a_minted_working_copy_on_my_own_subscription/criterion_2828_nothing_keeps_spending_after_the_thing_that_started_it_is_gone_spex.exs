defmodule CodeMySpecSpex.Story1018.Criterion2828Spex do
  @moduledoc """
  Story 1018 — A Pi agent starts in a minted working copy on my own subscription.
  Criterion 2828 — Nothing keeps spending after the thing that started it is gone.

  Rule: A started agent can be listed and stopped, and never outlives the thing
  that started it.

  Not hypothetical — this failure is already shipping, and documented against
  itself. `Workspaces.Runner.Local`'s own moduledoc says at `local.ex:36-44` that
  on macOS a supervisor-tree restart can orphan the process while the database row
  still points at it. Its teardown is `pkill -TERM -P` then `kill -TERM`
  (`local.ex:228-246`), which does not walk past one level of children. Two more of
  the same family sit in `servers/containers.ex:139-143` and
  `code_my_spec_local_web/application.ex:576-580`, where `Task.shutdown(task,
  :brutal_kill)` kills the Elixir task and leaves the OS process running detached.

  An orphaned analyzer wastes CPU. An orphaned *agent* keeps calling a model on
  somebody's subscription, with nothing watching it and nothing able to stop it,
  because the only handle on it died with its parent. That is the case for putting
  this under a supervisor that reaps rather than a pid file that hopes.

  The second assertion is the one that matters most and is easiest to skip:
  reporting must agree with reality. A survivor that is still listed is a bug you
  can chase; a survivor that has been forgotten is one nobody knows to look for.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1, response_field: 2]

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpec.McpServers.Agents.Tools.ListAgents
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent dies with whatever started it" do
    scenario "Nothing keeps spending after the thing that started it is gone" do
      given_ "a Pi agent working on a minted copy", context do
        {:ok, _integration} = Fixtures.connect_provider(context.scope, :openai)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, started, _frame} =
          StartAgent.execute(%{"engine" => "pi", "provider" => "openai-codex"}, frame)

        refute started.isError
        {:ok, Map.put(context, :started, started)}
      end

      when_ "whatever started it goes away", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartAgent.execute(
            %{
              "simulate" => "supervisor_down",
              "agent_id" => response_field(context.started, "Agent")
            },
            frame
          )

        {:ok, Map.put(context, :teardown, response)}
      end

      then_ "the agent is gone, and no orphan is left running against the subscription",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListAgents.execute(%{"reconcile" => true}, frame)

        text = response_text(listing)

        refute text =~ response_field(context.started, "Agent"),
               "the agent survived the thing that started it. An orphaned analyzer " <>
                 "wastes CPU; an orphaned agent keeps calling a model on somebody's " <>
                 "subscription with nothing watching and nothing able to stop it. " <>
                 "This is the failure `Workspaces.Runner.Local` documents against " <>
                 "itself at local.ex:36-44, and its teardown does not walk past one " <>
                 "level of children. ` reconcile` asks the device what is actually " <>
                 "running rather than what we remember starting, because those " <>
                 "disagreeing is the whole failure. Got: #{text}"

        {:ok, context}
      end

      then_ "what is reported as running matches what is running", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListAgents.execute(%{}, frame)

        refute response_text(listing) =~ response_field(context.started, "Agent"),
               "the dead agent is still listed as running. A survivor that is still " <>
                 "listed is a bug someone can chase; one that has been forgotten is " <>
                 "a bug nobody knows to look for. Got: #{response_text(listing)}"

        {:ok, context}
      end
    end
  end
end
