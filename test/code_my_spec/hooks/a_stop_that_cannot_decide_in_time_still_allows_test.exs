defmodule CodeMySpec.Hooks.AStopThatCannotDecideInTimeStillAllowsTest do
  @moduledoc """
  ed5baac4. The harness's own curl against this hook has a fixed wait; a
  decision that takes longer -- `Work.actionable/3` for `role: :main`
  recomputes the whole project's graph, and can queue behind
  `IncrementalGraph`'s post-reload reseed (e3c09c4d) or ordinary load -- used
  to leave the harness to time out with no answer at all, silently.

  Nothing in a spec can make a real read slow on demand (the same problem
  `CodeMode.Sandbox`'s own moduledoc names), so this proves the bound from the
  other side: lower the clock below what even a fast, ordinary decision takes,
  and confirm the stop still answers -- allowed, with a reason -- rather than
  hanging past it.
  """
  use ExUnit.Case, async: false

  import CodeMySpec.Integration.WorkflowHelpers

  alias CodeMySpec.Hooks.Stop
  alias CodeMySpec.Requirements
  alias CodeMySpec.TaskOwner
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  setup do
    previous = Application.fetch_env(:code_my_spec, :stop_decide_timeout_ms)

    # Put back exactly: an unset key restored as `nil` is a `receive ... after
    # nil` for the next test.
    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:code_my_spec, :stop_decide_timeout_ms, value)
        :error -> Application.delete_env(:code_my_spec, :stop_decide_timeout_ms)
      end
    end)
  end

  test "a decision bound at 0ms still answers, allowed, not a hang" do
    %{scope: scope, agent: agent, external_session_id: session_id} = setup_workflow_scenario()

    {:ok, _} = TaskOwner.set_continuous(agent, true)
    Requirements.recompute(scope)

    Application.put_env(:code_my_spec, :stop_decide_timeout_ms, 0)

    response = Stop.decide(scope, %{"session_id" => session_id})

    refute response["decision"] == "block",
           "a decision that could not finish in time was blocked rather than allowed: " <>
             inspect(response)

    assert response["systemMessage"] =~ "could not finish checking for more work",
           "a 0ms budget did not even reach the fallback path: #{inspect(response)}"
  end

  test "with its ordinary budget, the same scenario decides normally" do
    %{scope: scope, agent: agent, external_session_id: session_id} = setup_workflow_scenario()

    {:ok, _} = TaskOwner.set_continuous(agent, true)
    Requirements.recompute(scope)

    response = Stop.decide(scope, %{"session_id" => session_id})

    refute (response["systemMessage"] || "") =~ "could not finish checking for more work",
           "the bound fired on an ordinary, unthrottled decision: #{inspect(response)}"
  end
end
