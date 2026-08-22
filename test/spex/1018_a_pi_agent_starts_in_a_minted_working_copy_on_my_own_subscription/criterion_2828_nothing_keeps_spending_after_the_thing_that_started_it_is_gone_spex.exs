defmodule CodeMySpecSpex.Story1018.Criterion2828Spex do
  @moduledoc """
  Story 1018 — A Pi agent starts in a minted working copy on my own subscription.
  Criterion 2828 — Nothing keeps spending after the thing that started it is gone.

  Rule: A started agent can be listed and stopped, and never outlives the thing
  that started it.

  Not hypothetical — this failure is already shipping, and documented against
  itself. `Workspaces.Runner.Local`'s moduledoc says at `local.ex:36-44` that on
  macOS a supervisor-tree restart can orphan the process while the database row
  still points at it. Its teardown is `pkill -TERM -P` then `kill -TERM`
  (`local.ex:228-246`), which does not walk past one level of children. Two more
  of the same family sit in `servers/containers.ex:139-143` and
  `code_my_spec_local_web/application.ex:576-580`, where `Task.shutdown(task,
  :brutal_kill)` kills the Elixir task and leaves the OS process detached.

  An orphaned analyzer wastes CPU. An orphaned *agent* keeps calling a model on
  somebody's subscription with nothing watching it.

  ## The absence is the event

  Nothing here simulates a death. The harness reports the set of agents it is
  actually running — a projection of Presence on the lane topics, where a lane
  is joined for exactly as long as it is alive — and an agent whose process died
  is simply missing from the next report. Story 704 replaced a polled
  subagent-TTL registry with Presence for exactly this reason: a liveness record
  kept by hand drifts from the processes it claims to describe, and the drift is
  invisible.

  So the second report omitting the agent *is* the thing going away, and what is
  asserted is that the server stops claiming it runs.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecWeb.HarnessChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent dies with whatever started it" do
    scenario "Nothing keeps spending after the thing that started it is gone" do
      given_ "a harness reporting an agent it is running", context do
        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_spex_2828", %{scope: context.scope})
          |> subscribe_and_join(
            HarnessChannel,
            "harness:#{context.scope.active_account_id}",
            %{}
          )

        first_reply =
          report(socket, [
            %{"working_copy" => context.scope.cwd, "provider" => "openai-codex", "os_pid" => 4242}
          ])

        assert Enum.any?(first_reply["running"], &(&1["working_copy"] == context.scope.cwd)),
               "the harness reported an agent and the server did not take it up. " <>
                 "Got: #{inspect(first_reply)}"

        {:ok, Map.put(context, :socket, socket)}
      end

      when_ "whatever started it goes away, so the next report omits it", context do
        {:ok, Map.put(context, :reply, report(context.socket, []))}
      end

      then_ "the server stops claiming it is running", context do
        refute Enum.any?(context.reply["running"], &(&1["working_copy"] == context.scope.cwd)),
               "the agent is still reported as running after the harness stopped " <>
                 "reporting it. An orphaned analyzer wastes CPU; an orphaned agent " <>
                 "keeps calling a model on somebody's subscription with nothing " <>
                 "watching and nothing able to stop it. Got: #{inspect(context.reply)}"

        {:ok, context}
      end

      then_ "and what it reports matches what the harness said", context do
        assert context.reply["running"] == [],
               "the harness reported nothing running and the server disagreed. A " <>
                 "survivor that is still listed is a bug someone can chase; one that " <>
                 "has been forgotten is a bug nobody knows to look for. " <>
                 "Got: #{inspect(context.reply)}"

        {:ok, context}
      end
    end
  end

  #  binds its payload through a macro pattern, and that binding
  # does not survive the DSL's block. Matching the reply directly binds cleanly
  # and says the same thing.
  defp report(socket, agent_ids) do
    ref = Phoenix.ChannelTest.push(socket, "agents_running", %{"agent_ids" => agent_ids})

    receive do
      %Phoenix.Socket.Reply{ref: ^ref, status: :ok, payload: payload} -> payload
    after
      1_000 -> flunk("the harness channel never replied to agents_running")
    end
  end
end
