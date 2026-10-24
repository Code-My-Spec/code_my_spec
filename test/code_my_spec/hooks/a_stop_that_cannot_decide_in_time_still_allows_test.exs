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
    # `put_env(key, nil)` is not the same as never having set `key` --
    # `get_env(key, default)` only falls back to `default` when the key is
    # genuinely absent, so restoring a never-set key with `nil` broke the
    # very next test in this module, which relies on the default.
    restore_timeout_env(Application.fetch_env(:code_my_spec, :stop_decide_timeout_ms))
  end

  defp restore_timeout_env({:ok, previous}) do
    on_exit(fn -> Application.put_env(:code_my_spec, :stop_decide_timeout_ms, previous) end)
  end

  defp restore_timeout_env(:error) do
    on_exit(fn -> Application.delete_env(:code_my_spec, :stop_decide_timeout_ms) end)
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

  # c93e5fdc: a fixed 25s bound never fired, because the harness stops waiting
  # for a hook decision after 10s and the answer arrived after that. The bound
  # is the harness's own wait, sent with the request, less transit.
  describe "the bound is sized against the harness's wait" do
    test "the wait the harness names, less what the channel spends" do
      assert Stop.bound_for(10_000) == 7_500
      assert Stop.bound_for(30_000) == 27_500
    end

    test "never so small that an ordinary decision cannot finish" do
      assert Stop.bound_for(2_000) == 1_000
      assert Stop.bound_for(1) == 1_000
    end

    test "a request that names no wait gets the wait the harness has always had" do
      assert Stop.bound_for(nil) == 7_500
      assert Stop.bound_for("soon") == 7_500
    end

    test "the wait a request names is the bound its decision runs against" do
      %{scope: scope, agent: agent, external_session_id: session_id} = setup_workflow_scenario()

      {:ok, _} = TaskOwner.set_continuous(agent, true)
      Requirements.recompute(scope)

      # Named and ordinary: decided normally, not bounded out.
      response = Stop.decide(scope, %{"session_id" => session_id, "harness_budget_ms" => 10_000})

      refute (response["systemMessage"] || "") =~ "could not finish checking for more work"
    end
  end
end
