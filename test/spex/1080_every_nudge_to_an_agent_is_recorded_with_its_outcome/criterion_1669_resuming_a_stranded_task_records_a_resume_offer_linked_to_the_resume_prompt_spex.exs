defmodule CodeMySpecSpex.Story1080.Criterion1669Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1669 — Resuming a stranded task records a resume offer linked to
  the resume prompt.

  A harness that comes back reports the agents it is running. One holding a
  task with no turn in flight is stranded, and is told to carry on with it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A resumed task is recorded as an offer", criterion: 1669 do
    scenario "a harness comes back with a coder holding a task" do
      given_ "a harness serving a copy with coding work waiting", context do
        {reply, socket} =
          join_working_copy_socket(context, "/tmp/spex-1669-#{System.unique_integer()}", "c1669")

        scope = Fixtures.in_memory_copy(context, reply[:working_copy_id])
        context = Map.merge(context, %{scope: scope, socket: socket})
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)
        Fixtures.fresh_analysis_runs(context.scope, ["compiler", "credo", "exunit"])
        {:ok, put_to_work(context)}
      end

      given_ "a continuous coder on it holding a task, with no turn in flight", context do
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        context = start_agent_task(context, coder.id, next_task(context, coder.id))
        {:ok, Map.put(context, :coder, coder.id)}
      end

      when_ "the harness reports the agents it is running", context do
        ref =
          Phoenix.ChannelTest.push(context.socket, "agents_present", %{
            "agent_ids" => [context.coder]
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok)

        id = context.coder
        assert_receive {:work_turn_requested, ^id, _ref, prompt}, 2_000
        {:ok, Map.put(context, :prompt, prompt)}
      end

      then_ "the coder was told to carry on with its task", context do
        assert context.prompt =~ "restarted"
        {:ok, context}
      end

      then_ "a resume offer on that task is recorded, linked to that prompt", context do
        assert [offer] = offers(context, context.coder, %{kind: "resume"}),
               "expected one resume offer:\n" <> listing(context)

        assert offer.subject =~ ~r/^task:/
        assert offer.messages == [excerpt(context.prompt)]
        {:ok, context}
      end
    end
  end
end
