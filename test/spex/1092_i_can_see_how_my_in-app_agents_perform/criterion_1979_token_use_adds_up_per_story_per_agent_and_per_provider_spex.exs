defmodule CodeMySpecSpex.Story1092.Criterion1979Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 1979 -- Token use adds up per story, per agent and per provider.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.AgentPerformanceHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A story worked by two providers shows tokens in total and by provider", criterion: 1979 do
    scenario "agents on two providers worked one story" do
      given_ "a released story with a coding agent on one provider and a QA agent on another",
             context do
        # A lone checkout is the project's only one and auto-promotes itself to
        # main (`report_root`'s `only_checkout?/2`) -- and `assign_team` refuses
        # a story to the main copy's team. A main copy registered first, with no
        # root of its own, keeps this join a genuine feature copy.
        {:ok, main_copy} =
          WorkingCopies.issue(context.scope, nil,
            label: "the main checkout",
            device: Fixtures.device_fixture(context.scope)
          )

        {:ok, _} = WorkingCopies.designate_main(context.scope, main_copy.id)

        reply = join_working_copy(context, "/tmp/spex-1979", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        story =
          StoryHelpers.create_story(scope,
            title: "Two-provider story",
            description: "As a user, I want this story done.",
            acceptance_criteria: ["It works"]
          )

        coder =
          Fixtures.running_agent(scope,
            role: "coding",
            provider: "anthropic",
            working_copy: "/tmp/spex-1979"
          )

        qa =
          Fixtures.running_agent(scope,
            role: "qa",
            provider: "openai",
            working_copy: "/tmp/spex-1979"
          )

        # The team must already be on the copy for `assign_team` to find and
        # stamp it -- it refuses with no team to assign when none is there yet.
        frame = %Frame{assigns: %{current_scope: scope}}
        {:reply, resp, _frame} = SetActiveStory.execute(%{story_number: story.number}, frame)
        refute resp.isError, inspect(resp)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:story, story)
         |> Map.put(:coder, coder)
         |> Map.put(:qa, qa)}
      end

      when_ "each records a finished turn", context do
        :ok =
          Fixtures.record_turn(
            context.scope,
            %{"model" => "claude-sonnet-5-5", "messages" => []},
            %{
              "model" => "claude-sonnet-5-5",
              "content" => [%{"type" => "text", "text" => "done"}],
              "usage" => %{"input_tokens" => 100, "output_tokens" => 200}
            },
            session_id: "spex-1979-coder",
            agent_role: "coding"
          )

        :ok =
          Fixtures.record_turn(
            context.scope,
            %{"model" => "gpt-5-codex", "messages" => []},
            %{
              "model" => "gpt-5-codex",
              "content" => [%{"type" => "text", "text" => "probed"}],
              "usage" => %{"input_tokens" => 50, "output_tokens" => 70}
            },
            session_id: "spex-1979-qa",
            agent_role: "qa"
          )

        {:ok, context}
      end

      then_ "I see the story's tokens in total, per agent and per provider", context do
        {:ok, _index, html} = live(context.conn, index_path(context))

        assert html =~ "420", "the story's total tokens (300 + 120) are not shown"
        assert html =~ "anthropic", "the story's per-provider breakdown omits anthropic"
        assert html =~ "openai", "the story's per-provider breakdown omits openai"

        {:ok, context}
      end
    end
  end
end
