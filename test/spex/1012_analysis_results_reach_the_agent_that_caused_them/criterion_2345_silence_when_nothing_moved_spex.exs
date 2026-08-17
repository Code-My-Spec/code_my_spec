defmodule CodeMySpecSpex.Story1012.Criterion2345Spex do
  @moduledoc """
  Story 1012 — Analysis results reach the agent that caused them.
  Criterion 2345 — Silence when nothing moved.

  Rule: An agent is told once, and again only when new problems appear.

  A turn makes dozens of tool calls. Repeating the same alert on each of them is
  how a signal becomes wallpaper — and a channel the model has learned to skip
  is worse than one that never existed, because it looks like it is working.

  The distinction that keeps this honest: this is deduplication of
  *notification*, not filtering of *content*. Nothing is withheld, and a
  different session in the same working copy is told independently — see
  criterion 2340. No finding can hide behind "somebody was already notified".

  Surface: the PostToolUse hook, called twice with nothing landing in between.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Told once, not on every call" do
    scenario "Silence when nothing moved" do
      given_ :synced_context_component

      given_ "an agent has already been told about the current findings", context do
        session = "spex-quiet-#{System.unique_integer([:positive])}"

        use_cmd_cassette "pipeline_exunit_failure", record: :none do
          post_hook(context, "/api/hooks/stop", %{
            "session_id" => "spex-seed-#{System.unique_integer([:positive])}",
            "test_output_files" => %{
              "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl"),
              "compile" => Path.expand(Path.join(@fixture_dir, "compile.jsonl")),
              "exunit" => Path.expand(Path.join(@fixture_dir, "exunit.json"))
            }
          })
        end

        first = post_hook(context, "/api/hooks/post-tool-use", tool_call(session))

        assert (first["systemMessage"] || "") =~ "exunit",
               "the premise failed: this agent was never told in the first place, so " <>
                 "the silence below would prove nothing"

        {:ok, Map.put(context, :session, session)}
      end

      when_ "it makes further tool calls and nothing new has landed", context do
        second = post_hook(context, "/api/hooks/post-tool-use", tool_call(context.session))
        third = post_hook(context, "/api/hooks/post-tool-use", tool_call(context.session))

        {:ok, context |> Map.put(:second, second) |> Map.put(:third, third)}
      end

      then_ "it is not told again", context do
        refute (context.second["systemMessage"] || "") =~ "exunit",
               "the same alert arrived a second time with nothing having changed. " <>
                 "Repeated on every call in a turn, this is how the line becomes " <>
                 "wallpaper. Got: #{inspect(context.second)}"

        refute (context.third["systemMessage"] || "") =~ "exunit",
               "and a third time. Got: #{inspect(context.third)}"

        {:ok, context}
      end
    end
  end

  defp tool_call(session_id) do
    %{
      "session_id" => session_id,
      "tool_name" => "Read",
      "tool_input" => %{"file_path" => "lib/example_context.ex"}
    }
  end
end
