defmodule CodeMySpecSpex.Story1046.Criterion3175Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1182 — A promote reloads the running app by default, and restarts
  it when the change needs a restart, the reload fails, or a restart is asked
  for.

  Rule: The running application must be serving the code that was promoted.

  John (2026-10-02) reversed "always restart": a restart killed every agent
  turn and analysis run on the box for a change the app's own code reloader
  picks up. So a reload is the default, and the paths a reload cannot take —
  deps, config, application.ex, releases, asset deps, the toolchain, MCP tool
  registrations — are one list (`BootVersion.restart_paths/0`) that sends the
  app a restart instead. A reload that fails is not left there: the same
  promote restarts.
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

  spex "A code-only change is reloaded, not restarted", criterion: 1182 do
    scenario "the story changes a module and nothing a reload cannot take" do
      given_ "a story branch that changes only a module", context do
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
        answer_app(context.running_socket, "reload_app", "ok")
        {:ok, context |> Map.put(:response, response) |> Map.put(:told, told)}
      end

      then_ "the app is reloaded, and the promote says so", context do
        assert context.told =~ "application reload (",
               "expected a reload: #{context.told}"

        refute_push("restart_app", _, 200)
        {:ok, context}
      end
    end
  end

  spex "A change a reload cannot take restarts the app", criterion: 1182 do
    scenario "the story changes compile-time config" do
      given_ "a story branch that changes config", context do
        context =
          context
          |> a_promotable_project(app_verbs: ["reload_app", "restart_app"])
          |> an_agent_on_the_copy()

        write(
          context.agent_root,
          "config/config.exs",
          "import Config\nconfig :broken_oaths, war: true\n"
        )

        {_, 0} = git(context, context.agent_root, ["add", "-A"])
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-m", "the story's config"])
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
        answer_app(context.running_socket, "restart_app", "ok")
        {:ok, context |> Map.put(:response, response) |> Map.put(:told, told)}
      end

      then_ "the app is restarted, and the promote names the reason", context do
        text = context.told
        assert text =~ "application restart (", "expected a restart: #{text}"

        assert text =~ "config/config.exs",
               "the restart does not say which change needed it: #{text}"

        {:ok, context}
      end
    end
  end

  spex "A reload that fails is followed by a restart", criterion: 1182 do
    scenario "the app does not come back from the reload" do
      given_ "a story branch that changes only a module", context do
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

      when_ "the agent promotes and the reload fails", context do
        response = promote(context, context.story.number)
        refute response.isError, response_text(response)
        the_gate_answers(context)
        assert what_the_agent_was_told(context) =~ "landed on main"
        answer_app(context.running_socket, "reload_app", "error")
        {:ok, context}
      end

      then_ "the same promote restarts the app", context do
        answer_app(context.running_socket, "restart_app", "ok")
        {:ok, context}
      end
    end
  end

  defp answer_app(socket, verb, status) do
    assert_push(^verb, %{"ref" => ref}, 5_000)

    reply_ref =
      Phoenix.ChannelTest.push(socket, verb <> "_result", %{
        "ref" => ref,
        "status" => status,
        "app_status" => "serving",
        "app_url" => "http://127.0.0.1:4000",
        "app_commit" => "cafef00d",
        "error" => "the app did not answer /health"
      })

    receive do
      %Phoenix.Socket.Reply{ref: ^reply_ref, status: :ok} -> :ok
    after
      1_000 -> flunk("#{verb}_result was never acknowledged")
    end
  end
end
