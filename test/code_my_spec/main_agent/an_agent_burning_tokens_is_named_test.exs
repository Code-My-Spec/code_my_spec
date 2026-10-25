defmodule CodeMySpec.Agents.Main.AnAgentBurningTokensIsNamedTest do
  @moduledoc """
  Main's check-in reports each agent's token use over the last hour, and an
  agent spending past the threshold needs main. A Codex QA agent used 363M
  input and output tokens in one hour, one turn alone 60M, and no check-in
  said so (2026-10-25).
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentPerformance.AgentTurn
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main.{AgentWork, CheckInReport, Digest, Machinery, TokenBurn}

  defp turn(scope, agent_id, input, output, minutes_ago, cache \\ nil, fresh \\ nil) do
    at = DateTime.add(DateTime.utc_now(), -minutes_ago * 60, :second)

    %AgentTurn{}
    |> AgentTurn.changeset(%{
      account_id: scope.active_account_id,
      project_id: scope.active_project_id,
      agent_id: agent_id,
      input_tokens: input,
      output_tokens: output,
      cache_read_tokens: cache,
      fresh_thread: fresh
    })
    |> Ecto.Changeset.force_change(:inserted_at, at)
    |> Repo.insert!()
  end

  defp agent(scope) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "openai-codex",
        engine: :alloy,
        role: "qa",
        status: :running,
        working_copy: "/tmp/token-burn-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    agent.id
  end

  describe "the hour's roll-up" do
    setup do
      %{scope: full_scope_fixture()}
    end

    test "sums the hour's turns per agent, biggest spender first, and skips older ones", ctx do
      big = agent(ctx.scope)
      small = agent(ctx.scope)
      turn(ctx.scope, big, 30_000_000, 1_000_000, 10, 500)
      turn(ctx.scope, big, 20_000_000, 2_000_000, 30)
      turn(ctx.scope, big, 99_000_000, 0, 90)
      turn(ctx.scope, small, 1_000, 200, 5)

      assert [
               %{agent_id: ^big, turns: 2, tokens: 53_000_000, largest_turn: 31_000_000},
               %{agent_id: ^small, turns: 1, tokens: 1_200}
             ] = TokenBurn.last_hour(ctx.scope)
    end

    # Each sent the whole transcript uncached, which is where a burn comes from.
    test "counts the turns that started a new Codex thread", ctx do
      codex = agent(ctx.scope)
      turn(ctx.scope, codex, 9_000_000, 1_000, 5, nil, "history_or_config_changed")
      turn(ctx.scope, codex, 200_000, 1_000, 3)

      assert [%{fresh_threads: 1, turns: 2}] = TokenBurn.last_hour(ctx.scope)
    end

    test "a turn with no reported usage is unknown, not zero", ctx do
      silent = agent(ctx.scope)
      turn(ctx.scope, silent, nil, nil, 5)

      assert [%{tokens: :unknown, largest_turn: :unknown, cache_read: :unknown, turns: 1}] =
               TokenBurn.last_hour(ctx.scope)
    end
  end

  describe "the check-in" do
    defp burn(tokens, largest),
      do: %{
        agent_id: "b0c75bbd-0000-0000-0000-000000000000",
        turns: 27,
        tokens: tokens,
        largest_turn: largest,
        cache_read: :unknown,
        fresh_threads: 0
      }

    defp digest(tokens) do
      %Digest{
        questions: [],
        machinery: %Machinery{tool_fault: :none},
        work: [
          %AgentWork{
            agent_id: "b0c75bbd-0000-0000-0000-000000000000",
            role: :qa,
            agent_status: :running,
            task_status: :active,
            machine_tools: ["promote"]
          }
        ],
        tokens: tokens
      }
    end

    test "names the top spenders on a quiet check-in" do
      report = CheckInReport.render(digest([burn(4_200_000, 900_000)]))

      assert report =~ "tokens (1h): b0c75bbd qa 4.2M/27t"
      assert Digest.quiet?(digest([burn(4_200_000, 900_000)]))
    end

    test "an agent over the hourly threshold needs main, with the remedy" do
      digest = digest([burn(363_000_000, 9_000_000)])

      assert CheckInReport.needs_attention?(digest)
      refute Digest.quiet?(digest)

      report = CheckInReport.render(digest)
      assert report =~ "burning tokens — 363.0M in the last hour over 27 turns"
      assert report =~ "turn_off_agent"
    end

    test "says how many turns started a new Codex thread" do
      entry = %{burn(363_000_000, 9_000_000) | fresh_threads: 3}
      report = CheckInReport.render(digest([entry]))

      assert report =~ "b0c75bbd qa 363.0M/27t 3 new thread(s)"
      assert report =~ "3 of its turns started a new Codex thread"
    end

    test "one turn over the per-turn threshold needs main too" do
      assert CheckInReport.needs_attention?(digest([burn(20_000_000, 60_000_000)]))
    end

    test "unknown usage never trips the threshold" do
      refute CheckInReport.needs_attention?(digest([burn(:unknown, :unknown)]))
    end
  end
end
