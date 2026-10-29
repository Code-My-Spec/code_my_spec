defmodule CodeMySpecSpex.Story1165.Criterion2575Spex do
  @moduledoc """
  Story 1165, criterion 2575: another confirmed flake for the same test adds
  its evidence to the open issue instead of creating another issue.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @test_file "test/broken_oaths/diplomacy/war_test.exs"
  @test_name "test declares war"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A repeat confirmation is added to the test's open flake issue", criterion: 2575 do
    scenario "two landed promotions confirm the same flaky test" do
      given_ "the first confirmed flake has an open issue", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace(1))
        story = a_promotable_story(context, title: "First promotion")
        analyzers_are_current(context)
        promote(context, story.number, fresh: true)
        the_gate_is_running(context)
        the_gate_answers_and_passes_rerun(context, %{"exunit" => [failure("first confirmation")]})
        assert what_the_agent_was_told(context) =~ "landed on main"

        listing = list_open_flakes(context)
        assert listing =~ "1 issues", listing
        [_, issue_id] = Regex.run(~r/ID: ([0-9a-f-]{36})/, listing)
        first_issue = get_issue(context, issue_id)
        assert first_issue =~ "first confirmation", first_issue
        {:ok, Map.put(context, :issue_id, issue_id)}
      end

      when_ "a later landed promotion confirms the same test again", context do
        context = another_candidate(context, :second)
        second = context.second

        second_context = %{
          context
          | agent_root: second.root,
            scope: second.scope,
            agent_id: second.agent_id,
            agent: Map.put(context.agent, :working_copy_id, second.working_copy_id)
        }

        commit_work(second_context, second.root, "lib/broken_oaths/diplomacy/peace.ex", peace(2))
        story = a_promotable_story(second_context, title: "Second promotion")
        analyzers_are_current(second_context)
        promote(second_context, story.number, fresh: true)
        the_gate_is_running(second_context)

        the_gate_answers_and_passes_rerun(second_context, %{
          "exunit" => [failure("second confirmation")]
        })

        assert what_the_agent_was_told(second_context) =~ "landed on main"
        {:ok, context}
      end

      then_ "the same open issue includes the new confirmation and no duplicate exists",
            context do
        listing = list_open_flakes(context)
        assert listing =~ "1 issues", listing
        assert listing =~ context.issue_id, listing

        issue = get_issue(context, context.issue_id)
        assert issue =~ "Status:** accepted", issue
        assert issue =~ @test_file, issue
        assert issue =~ @test_name, issue
        assert issue =~ "first confirmation", issue
        assert issue =~ "second confirmation", issue
        {:ok, context}
      end
    end
  end

  defp list_open_flakes(context) do
    frame = %{current_scope: context.scope, scope: context.scope}

    reply =
      ToolLibrary.run(
        "list_issues",
        %{status: "accepted", query: @test_file},
        frame
      )

    assert match?({:ok, _}, reply), response_text(reply)
    response_text(reply)
  end

  defp get_issue(context, issue_id) do
    frame = %{current_scope: context.scope, scope: context.scope}
    reply = ToolLibrary.run("get_issue", %{issue_id: issue_id}, frame)
    assert match?({:ok, _}, reply), response_text(reply)
    response_text(reply)
  end

  defp failure(message) do
    %{"file" => @test_file, "line" => 3, "name" => @test_name, "message" => message}
  end

  defp peace(version) do
    "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: #{version}\nend\n"
  end
end
