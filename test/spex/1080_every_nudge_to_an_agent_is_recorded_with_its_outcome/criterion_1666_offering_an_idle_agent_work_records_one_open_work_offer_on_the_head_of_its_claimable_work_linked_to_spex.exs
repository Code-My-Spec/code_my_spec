defmodule CodeMySpecSpex.Story1080.Criterion1666Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1666 — Offering an idle agent work records one open work offer on
  the head of its claimable work, linked to the exact prompt sent, with the
  prompt unchanged.

  A coding agent holds nothing while coding work waits. Switching its copy on
  offers it that work; the offer is what main reads back.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.OfferHelpers

  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  @work_prompt "Eligible work is available. Call get_next_requirement to see it, " <>
                 "then claim it with start_task. No task has been selected or assigned for you."

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport()
    :ok
  end

  spex "An idle agent's work offer is recorded", criterion: 1666 do
    scenario "a copy with coding work waiting is switched on" do
      given_ "coding work is waiting", context do
        # The 1184 premise: everything but the spex run, so coding holds work.
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)
        context = HarnessHooks.ensure_live_harness(context)
        Fixtures.fresh_analysis_runs(context.scope, ["compiler", "credo", "exunit"])
        {:ok, context}
      end

      given_ "a continuous coding agent on a working copy, holding no task", context do
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        context = start_session(context)
        {:ok, Map.put(context, :coder, coder.id)}
      end

      when_ "the copy is switched on", context do
        context = put_to_work(context)

        assert Fixtures.role_queue_size(context.scope, context.coder) > 0,
               "the premise is coding work waiting for this agent"

        id = context.coder
        assert_receive {:work_turn_requested, ^id, _ref, prompt}, 2_000

        {:ok, Map.merge(context, %{head: head_of_work(context, context.coder), prompt: prompt})}
      end

      then_ "the prompt sent is the work prompt, unchanged", context do
        assert context.prompt == @work_prompt
        {:ok, context}
      end

      then_ "one open work offer on the head of its work, linked to that prompt", context do
        assert [offer] = offers(context, context.coder, %{kind: "work"}),
               "expected exactly one work offer:\n" <> listing(context)

        assert offer.status == "open"
        assert offer.attempt == 1

        assert offer.subject =~ ~r/^requirement:.*:#{context.head}$/,
               "the offer is on #{offer.subject}, not the head of its work (#{context.head})"

        assert offer.messages == [excerpt(context.prompt)]
        {:ok, context}
      end
    end
  end

  # What get_next_requirement puts first for this agent: the head of its work.
  defp head_of_work(context, agent_id) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope, agent_id: agent_id}}
    {:reply, response, _} = GetNextRequirement.execute(%{}, frame)
    text = CodeMySpecSpex.TaskResponseHelpers.response_text(response)
    [_, name] = Regex.run(~r/^- (\w+) \(/m, text)
    name
  end
end
