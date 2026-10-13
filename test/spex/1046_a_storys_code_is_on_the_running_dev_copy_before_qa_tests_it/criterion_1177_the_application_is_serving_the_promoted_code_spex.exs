defmodule CodeMySpecSpex.Story1046.Criterion3170Spex do
  @moduledoc """
  Story 1046 — A queued promotion lands before reporting deployment dispatched.

  The agent receives a queue acknowledgement, then the gate certifies the
  merged tree. Its landing message reports deployment as unconfirmed; the
  harness subsequently answers the actual reload request.
  """

  use CodeMySpecSpex.Case

  import Phoenix.ChannelTest
  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.Fixtures.StoryIssueBag
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The joins go through a real channel, which runs in a process of its own.
  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The promotion is finished when the app serves the merge", criterion: 1177 do
    scenario "a clean promotion reports the revision now being served" do
      given_ "a story branch with work to promote", context do
        context =
          context
          |> a_promotable_project(app_verbs: ["reload_app", "restart_app"])
          |> an_agent_on_the_copy()

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])

        story = a_promotable_story(context, qa: :not_passed)

        :ok =
          StoryIssueBag.certify(
            context.scope,
            story.id,
            head_of(context, context.agent_root)
          )

        {:ok, _} = Fixtures.passed_qa_attempt(context.scope, story_id: story.id)
        {:ok, Map.put(context, :story, story)}
      end

      given_ "main has independent work and both copies' analyzers are current", context do
        commit_work(
          context,
          context.running_root,
          "lib/broken_oaths/diplomacy/treaty.ex",
          treaty()
        )

        {:ok, analyzers_are_current(context)}
      end

      when_ "the agent promotes", context do
        response = promote(context, context.story.number)
        refute response.isError, response_text(response)
        the_gate_answers(context)
        told = what_the_agent_was_told(context)
        assert told =~ "landed on main", told

        {head, 0} = git(context, context.running_root, ["rev-parse", "main"])

        # The deployment is dispatched, never awaited (54aa534c, phase two),
        # so `promote/1` has already answered by the time this runs. It goes
        # over the channel every working copy's app answers to — a reload for
        # this code-only change — and this is the harness answering it.
        answer_deployment(context.running_socket, context.running_root)

        {:ok,
         context
         |> Map.put(:response, response)
         |> Map.put(:told, told)
         |> Map.put(:head, String.trim(head))}
      end

      then_ "the running checkout carries the story's work", context do
        merged = read(context.running_root, "lib/broken_oaths/diplomacy/war.ex")

        assert merged =~ ":from_the_copy",
               "the promotion reported success over a checkout that does not " <>
                 "hold the work"

        {:ok, context}
      end

      then_ "it says the deployment is dispatched rather than claiming a revision", context do
        text = context.told

        assert text =~ ~r/not yet confirmed|not awaited|not waited on|unconfirmed/,
               "the response should say the restart is dispatched and " <>
                 "unconfirmed, not claim a revision it cannot yet know is " <>
                 "actually serving. Got: #{text}"

        {:ok, context}
      end

      then_ "and the deployment the merge triggered actually runs", context do
        eventually(fn ->
          assert exists?(context.running_root, ".deployed"),
                 "the merge landed but nothing ever ran the restart recipe, so " <>
                   ~s(the words "merged" and "running" remain two different ) <>
                   "claims — just not ones the response can settle any more. " <>
                   "Got: #{context.told}"
        end)

        {:ok, context}
      end
    end
  end

  defp answer_deployment(socket, running_root) do
    assert_push("reload_app", %{"ref" => ref}, 5_000)

    write(running_root, ".deployed", DateTime.to_string(DateTime.utc_now()))

    reply_ref =
      Phoenix.ChannelTest.push(socket, "reload_app_result", %{
        "ref" => ref,
        "status" => "ok",
        "app_status" => "serving",
        "app_url" => "http://127.0.0.1:4000",
        "app_commit" => "cafef00d"
      })

    receive do
      %Phoenix.Socket.Reply{ref: ^reply_ref, status: :ok} -> :ok
    after
      1_000 -> flunk("reload_app_result was never acknowledged")
    end
  end
end
