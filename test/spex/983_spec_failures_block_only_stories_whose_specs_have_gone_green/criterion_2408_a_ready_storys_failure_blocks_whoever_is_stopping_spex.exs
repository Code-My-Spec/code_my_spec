defmodule CodeMySpecSpex.Story983.Criterion2408Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 2408 — A ready story's failure blocks whoever is stopping.

  Rule: a spec failure on a ready story blocks any agent in the working copy,
  not only the one that wrote it.

  Layer 2. The other fourteen criteria here are layer 1 — *which stories* a
  failure blocks, via the `specs_ready` latch. None says *which agent*, and that
  question has had a load-bearing answer since `ae0a8537` exempted spex from
  attribution demotion, pinned only by
  `test/code_my_spec/validation/demotion_wiring_test.exs`. A unit test is the
  wrong home for an outcome an agent meets at every stop.

  ## Why this is not criterion 8163 again

  8163 asserts the block on a ready story, and writes the failing spec through
  `Environments.write_file/3` without ever posting to `/api/hooks/post-tool-use`.
  So that session has **no recorded edits at all**, and the stop takes a
  different path — "This session has no recorded edits, so none of these could be
  checked against your work and nothing was demoted". Demotion never runs, so the
  block proves nothing about whether spex survives it.

  This makes the session demonstrably an editor: it writes an unrelated
  implementation file *and records that edit*, so the attributed set is
  non-empty and demotion is live. The failing spec is outside it. Only then does
  a block mean "spex is exempt" rather than "there was nothing to exempt it
  from".

  The last assertion is the guard on exactly that — if the response falls back
  to the no-recorded-edits wording, the scenario has not tested what it claims,
  and it should fail rather than pass for the wrong reason.

  ## Expected green

  Unlike story 894's spex, this describes shipped behaviour that nothing
  asserted. It should pass on the first run. A red here would mean `ae0a8537`
  has regressed.

  Surface: LiveView (engineer enables spex), the PostToolUse hook (what the
  session is on record as having edited), the filesystem (the regression), and
  the stop hook (the decision).
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @spex_path "test/spex/example_context_spex.exs"
  @unrelated_impl_path "lib/example_context.ex"
  @green_fixture_dir "test/fixtures/validation/pipeline_clean_credo"
  @red_fixture_dir "test/fixtures/validation/pipeline_spex_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Enforcement is not scoped to the agent that caused it" do
    scenario "a ready story regresses in a file this session did not edit" do
      given_ :synced_context_component
      given_ :story_linked_to_component
      given_ :bdd_task_started
      given_ :on_configuration_page

      given_ "spex enforcement is enabled on the project", context do
        context.config_live
        |> form("[data-test='configuration-form']", configuration: %{spex: "block_all"})
        |> render_submit()

        {:ok, context}
      end

      given_ "the story's BDD spec exists and is green", context do
        :ok = Environments.write_file(context.environment, @spex_path, passing_spex())
        {:ok, context}
      end

      given_ "a fresh green run has flipped the story to specs-ready", context do
        use_cmd_cassette "clean", record: :none do
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{
            "session_id" => context.session_id,
            "test_output_files" => %{
              "compile" => green_fixture("compile.jsonl"),
              "exunit" => green_fixture("exunit.json"),
              "spex" => green_fixture("spex.jsonl")
            }
          })
          |> Phoenix.ConnTest.json_response(200)
        end

        {:ok, context}
      end

      given_ "this session edits something else, and is on record as having done so",
             context do
        # The point of the scenario. Without a recorded edit the attributed set
        # is empty, demotion never runs, and a block would prove nothing.
        :ok = Environments.write_file(context.environment, @unrelated_impl_path, impl())

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/post-tool-use", %{
          "session_id" => context.session_id,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => @unrelated_impl_path}
        })
        |> Phoenix.ConnTest.json_response(200)

        {:ok, context}
      end

      given_ "the story's spec regresses, with no edit recorded against it", context do
        # No PostToolUse for this path — it stands in for a rebase, another
        # worktree, or an agent that has since gone away.
        :ok = Environments.write_file(context.environment, @spex_path, failing_spex())
        {:ok, context}
      end

      when_ "the agent attempts to stop", context do
        response =
          use_cmd_cassette "pipeline_spex_failure", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "compile" => red_fixture("compile.jsonl"),
                "spex" => red_fixture("spex.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is refused even though this session did not touch the spec", context do
        assert context.response["decision"] == "block",
               "spex is the one source attribution does not demote, because its " <>
                 "mandate test is the earned latch rather than who typed the file. " <>
                 "Got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "the refusal names the failing spec", context do
        reason = context.response["reason"] || ""

        assert reason =~ @spex_path,
               "a finding the agent did not cause is only actionable if it says " <>
                 "which one. Got:\n#{reason}"

        {:ok, context}
      end

      then_ "demotion was actually live, so the block means something", context do
        # The guard. If the response falls back to the no-recorded-edits wording,
        # the attributed set was empty, nothing was ever a candidate for
        # demotion, and this scenario proved nothing about spex being exempt.
        reason = context.response["reason"] || ""

        refute reason =~ "no recorded edits",
               "this session recorded an edit, so demotion should have run and spex " <>
                 "survived it. Falling back to the empty-attribution path means the " <>
                 "block above is not evidence for the rule. Got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp green_fixture(name), do: Path.expand(Path.join(@green_fixture_dir, name))
  defp red_fixture(name), do: Path.expand(Path.join(@red_fixture_dir, name))

  defp impl do
    """
    defmodule ExampleContext do
      @moduledoc false
      def noop, do: :ok
    end
    """
  end

  defp passing_spex do
    """
    defmodule ExampleContextSpex do
      use SexySpex

      spex "example context behaves" do
        scenario "the happy path holds" do
          then_ "it succeeds", context do
            assert 1 == 1
            {:ok, context}
          end
        end
      end
    end
    """
  end

  defp failing_spex do
    """
    defmodule ExampleContextSpex do
      use SexySpex

      spex "intentional failure" do
        scenario "asserts false" do
          then_ "fails", context do
            assert 1 == 2, "spex failure fixture"
            {:ok, context}
          end
        end
      end
    end
    """
  end
end
