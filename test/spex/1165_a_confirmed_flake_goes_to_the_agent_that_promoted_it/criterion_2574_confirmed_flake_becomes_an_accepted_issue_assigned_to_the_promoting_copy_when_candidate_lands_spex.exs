defmodule CodeMySpecSpex.Story1165.Criterion2574Spex do
  @moduledoc """
  Story 1165, criterion 2574: a confirmed gate flake becomes an accepted issue
  on the promoting working copy as soon as the candidate lands.
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

  spex "A landed candidate assigns its confirmed flake to the promoting copy as an accepted issue",
    criterion: 2574 do
    scenario "the gate failure passes its rerun and the candidate lands" do
      given_ "a promotable candidate with a test that will fail at the gate", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)
        {:ok, context}
      end

      when_ "the failed gate test passes its rerun and the candidate lands", context do
        promote(context, context.story.number, fresh: true)
        the_gate_is_running(context)
        the_gate_answers_and_passes_rerun(context, %{"exunit" => [failure()]})
        outcome = what_the_agent_was_told(context)
        assert outcome =~ "landed on main", outcome
        {:ok, Map.put(context, :outcome, outcome)}
      end

      then_ "the promoting copy immediately has an accepted issue with the flake evidence",
            context do
        frame = %{current_scope: context.scope, scope: context.scope}

        listed =
          ToolLibrary.run(
            "list_issues",
            %{
              status: "accepted",
              working_copy_id: context.agent.working_copy_id
            },
            frame
          )

        assert match?({:ok, _}, listed), response_text(listed)
        listing = response_text(listed)
        assert listing =~ "1 issues", listing

        [_, issue_id] = Regex.run(~r/ID: ([0-9a-f-]{36})/, listing)
        detail = ToolLibrary.run("get_issue", %{issue_id: issue_id}, frame)
        assert match?({:ok, _}, detail), response_text(detail)
        issue = response_text(detail)
        assert issue =~ "Status:** accepted", issue
        assert issue =~ @test_file, issue
        assert issue =~ @test_name, issue
        {:ok, context}
      end
    end
  end

  defp failure do
    %{"file" => @test_file, "line" => 3, "name" => @test_name, "message" => "assertion failed"}
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
