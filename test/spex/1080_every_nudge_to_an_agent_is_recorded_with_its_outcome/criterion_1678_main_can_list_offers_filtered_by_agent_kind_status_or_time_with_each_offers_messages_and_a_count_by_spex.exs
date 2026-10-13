defmodule CodeMySpecSpex.Story1080.Criterion1678Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1678 — Main can list offers, filtered by agent, kind, status or
  time, with each offer's messages and a count by kind and status.

  `list_offers` is how claim rates are read: the count table answers "how
  often do agents take what they are offered", and the blocks underneath say
  what was actually sent.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.OfferHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "Main lists offers with counts and messages", criterion: 1678 do
    scenario "a coder ignored one work offer and holds a second" do
      given_ "a coder offered work, which ended a turn without it and was offered it again",
             context do
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)
        context = HarnessHooks.ensure_live_harness(context)
        Fixtures.fresh_analysis_runs(context.scope, ["compiler", "credo", "exunit"])
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        qa = Fixtures.running_agent(context.scope, role: "qa", continuous: false)
        context = context |> start_session() |> put_to_work()
        id = coder.id
        assert_receive {:work_turn_requested, ^id, _ref, prompt}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        :ok = Fixtures.end_turn(context.scope, id)
        assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000
        {:ok, Map.merge(context, %{coder: id, qa: qa.id, prompt: prompt})}
      end

      when_ "main lists offers, then narrows by agent, kind, status and time", context do
        {:ok,
         Map.merge(context, %{
           all: listing(context),
           by_agent: listing(context, %{agent_id: context.coder}),
           other_agent: listing(context, %{agent_id: context.qa}),
           ignored: listing(context, %{status: "ignored"}),
           menus: listing(context, %{kind: "menu"}),
           later:
             listing(context, %{
               since: DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()
             })
         })}
      end

      then_ "the count table shows one ignored and one open work offer", context do
        assert context.all =~ "2 offers match"
        assert context.all =~ ~r/^kind\s+open\s+ignored\s+total$/m, context.all
        assert context.all =~ ~r/^work\s+1\s+1\s+2$/m, context.all
        {:ok, context}
      end

      then_ "each offer shows the message it was sent", context do
        assert [newest, oldest] = parse(context.all)
        assert oldest.messages == [excerpt(context.prompt)]
        assert newest.messages != []
        {:ok, context}
      end

      then_ "the filters narrow it", context do
        assert length(parse(context.by_agent)) == 2
        assert context.other_agent == "No offers match."
        assert [%{status: "ignored"}] = parse(context.ignored)
        assert context.menus == "No offers match."
        assert context.later == "No offers match."
        {:ok, context}
      end
    end
  end
end
