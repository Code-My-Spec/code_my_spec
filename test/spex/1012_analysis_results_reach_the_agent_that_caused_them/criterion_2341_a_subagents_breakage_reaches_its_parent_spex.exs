defmodule CodeMySpecSpex.Story1012.Criterion2341Spex do
  @moduledoc """
  Story 1012 — Analysis results reach the agent that caused them.
  Criterion 2341 — A subagent's breakage reaches its parent.

  Rule: Results are surfaced for the whole working copy, never narrowed to one
  agent or one file.

  Criterion 738 already settled that a subagent is a lane inside its parent's
  working copy rather than a second one. Delivery inherits that for free — which
  is the point of choosing the harness as the grain. Anything keyed on
  `agent_id` would have to special-case it, and the special case is where the
  parent stops hearing about a tree its own subagent has moved past.

  Surface: the PostToolUse hook, with the subagent's own `agent_id` on the edit
  and the parent's session asking afterwards.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A subagent is inside its parent, not beside it" do
    scenario "A subagent's breakage reaches its parent" do
      given_ :synced_context_component

      given_ "an agent has started a subagent in its working copy", context do
        {:ok,
         context
         |> Map.put(:parent, "spex-parent-#{System.unique_integer([:positive])}")
         |> Map.put(:subagent_id, "a-sub-#{System.unique_integer([:positive])}")}
      end

      when_ "the subagent's edit breaks a spec", context do
        hook("/api/hooks/post-tool-use", context, %{
          "session_id" => context.parent,
          "agent_id" => context.subagent_id,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => "lib/example_context.ex"}
        })

        use_cmd_cassette "pipeline_exunit_failure", record: :none do
          hook("/api/hooks/stop", context, %{
            "session_id" => context.parent,
            "test_output_files" => %{
              "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl"),
              "compile" => Path.expand(Path.join(@fixture_dir, "compile.jsonl")),
              "exunit" => Path.expand(Path.join(@fixture_dir, "exunit.json"))
            }
          })
        end

        {:ok, context}
      end

      then_ "the parent is told about the failure", context do
        parent =
          hook("/api/hooks/post-tool-use", context, %{
            "session_id" => context.parent,
            "tool_name" => "Read",
            "tool_input" => %{"file_path" => "lib/example_context.ex"}
          })

        assert (parent["systemMessage"] || "") =~ "exunit",
               "a subagent's breakage did not reach its parent. The parent is left " <>
                 "working against a tree its own subagent has already moved past, and " <>
                 "nothing in its turn says so. Got: #{inspect(parent)}"

        {:ok, context}
      end
    end
  end

  defp hook(path, context, params) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, path, params)
    |> Phoenix.ConnTest.json_response(200)
  end
end
