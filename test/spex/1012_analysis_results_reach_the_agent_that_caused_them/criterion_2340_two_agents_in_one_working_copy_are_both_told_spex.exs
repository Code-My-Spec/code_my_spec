defmodule CodeMySpecSpex.Story1012.Criterion2340Spex do
  @moduledoc """
  Story 1012 — Analysis results reach the agent that caused them.
  Criterion 2340 — Two agents in one working copy are both told.

  Rule: Results are surfaced for the whole working copy, never narrowed to one
  agent or one file.

  The working copy is the unit — the grain story 1000 established for files and
  problems. Two agents in one checkout share a tree and a `_build`, so a failure
  either of them caused is a fact about the tree both are standing on.

  Narrowing this is the tempting mistake and it has a precedent: attribution
  narrowed the stop gate by edited file and thereby turned `spex: block_all` into
  a no-op for months. Every filter is a place a finding hides, and the hiding is
  invisible.

  Surface: the PostToolUse hook. Two sessions, one harness, one working copy.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The working copy is told, not the author" do
    scenario "Two agents in one working copy are both told" do
      given_ :synced_context_component

      given_ "two agents are working in the same working copy", context do
        # One harness, two sessions. Only the session id distinguishes them,
        # which is the whole claim: the copy is the unit, not the process.
        {:ok,
         context
         |> Map.put(:breaker, "spex-breaker-#{System.unique_integer([:positive])}")
         |> Map.put(:bystander, "spex-bystander-#{System.unique_integer([:positive])}")}
      end

      when_ "one of them changes code that breaks a spec belonging to another story",
            context do
        # A real analyzer result entering the system the way one does.
        use_cmd_cassette "pipeline_exunit_failure", record: :none do
          hook("/api/hooks/stop", context, %{
            "session_id" => context.breaker,
            "test_output_files" => %{
              "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl"),
              "compile" => Path.expand(Path.join(@fixture_dir, "compile.jsonl")),
              "exunit" => Path.expand(Path.join(@fixture_dir, "exunit.json"))
            }
          })
        end

        {:ok, context}
      end

      then_ "both agents are told about the failure", context do
        breaker = hook("/api/hooks/post-tool-use", context, tool_call(context.breaker))
        bystander = hook("/api/hooks/post-tool-use", context, tool_call(context.bystander))

        assert (breaker["systemMessage"] || "") =~ "exunit",
               "the agent whose turn produced the failure was not told on its next " <>
                 "tool call. That is the whole story: the result was two minutes away " <>
                 "and nothing handed it over. Got: #{inspect(breaker)}"

        assert (bystander["systemMessage"] || "") =~ "exunit",
               "the second agent in the same working copy was not told. It shares the " <>
                 "tree and the _build, so this failure is a fact about the copy it is " <>
                 "standing on — its own next `mix test` is red too. Got: #{inspect(bystander)}"

        {:ok, context}
      end

      then_ "neither is told it belongs to somebody else", context do
        bystander = hook("/api/hooks/post-tool-use", context, tool_call(context.bystander))
        rendered = inspect(bystander)

        refute rendered =~ "another agent" or rendered =~ "not yours",
               "the alert disowned the finding on the reader's behalf. Deciding whose a " <>
                 "failure is, is what attribution did to the stop gate before it stopped " <>
                 "blocking anything. Got: #{rendered}"

        {:ok, context}
      end
    end
  end

  # Hooks live on CodeMySpecLocalWeb; `x-harness-id` names the working copy.
  defp hook(path, context, params) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, path, params)
    |> Phoenix.ConnTest.json_response(200)
  end

  defp tool_call(session_id) do
    %{
      "session_id" => session_id,
      "tool_name" => "Read",
      "tool_input" => %{"file_path" => "lib/example_context.ex"}
    }
  end
end
