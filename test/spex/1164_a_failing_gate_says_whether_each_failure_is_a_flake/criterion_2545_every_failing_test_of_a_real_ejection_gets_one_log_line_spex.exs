defmodule CodeMySpecSpex.Story1164.Criterion2545Spex do
  @moduledoc """
  Story 1164, criterion 2545: each failing test in a real gate ejection
  receives exactly one classification log line.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @test_file "test/broken_oaths/diplomacy/war_test.exs"
  @test_names ["test declares war", "test signs peace", "test keeps treaty"]

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Every failing test of a real ejection gets one log line", criterion: 2545 do
    scenario "a promotion gate ejects a candidate with three failing tests" do
      given_ "story 1164 has landed and a promotable candidate has three failing tests",
             context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)
        {:ok, context}
      end

      when_ "the real promotion gate ejects the candidate", context do
        promote(context, context.story.number, fresh: true)
        the_gate_is_running(context)

        log =
          Fixtures.capture_log_at(:info, fn ->
            failures = Enum.map(@test_names, &failure/1)
            the_gate_answers_and_fails_rerun(context, %{"exunit" => failures})
            what_the_agent_was_told(context)
          end)

        {:ok, Map.put(context, :log, log)}
      end

      then_ "John sees exactly one classification line for each failing test", context do
        lines =
          context.log
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.contains?(&1, "evidence="))

        assert length(lines) == 3, context.log

        for name <- @test_names do
          assert Enum.count(lines, &String.contains?(&1, "#{@test_file}: #{name}")) == 1,
                 context.log
        end

        {:ok, context}
      end
    end
  end

  defp failure(name) do
    %{"file" => @test_file, "line" => 3, "name" => name, "message" => "assertion failed"}
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
