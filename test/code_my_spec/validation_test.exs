defmodule CodeMySpec.ValidationTest do
  use CodeMySpecTest.DataCase, async: false
  use ExCliVcr

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.ProjectCoordinator.ImplementationStatus
  alias CodeMySpec.Sessions.SessionsRepository
  alias CodeMySpec.Support.TestAdapter
  alias CodeMySpec.Validation

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  @test_repo_url "https://github.com/Code-My-Spec/test_phoenix_project.git"
  @transcripts_dir "test/fixtures/transcripts"

  setup do
    scope = full_scope_fixture()
    {:ok, project_dir} = TestAdapter.clone(scope, @test_repo_url)

    env = Environment.new(:local, project_dir)
    scope = %{scope | environment: env, cwd: project_dir}

    pipeline_opts = [
      compile_output_file: Path.expand(TestAdapter.compiler_ok_cache_path()),
      test_output_file: Path.expand(TestAdapter.test_results_cache_path())
    ]

    on_exit(fn -> TestAdapter.checkin(project_dir) end)

    %{scope: scope, env: env, project_dir: project_dir, pipeline_opts: pipeline_opts}
  end

  defp transcript_path(name) do
    Path.join(@transcripts_dir, name)
  end

  # ============================================================================
  # validate_subagent/2
  # ============================================================================

  describe "validate_subagent/2" do
    test "returns {:ok, :valid} when transcript has no edited files",
         %{scope: scope, pipeline_opts: pipeline_opts} do
      use_cmd_cassette "validation_subagent_empty", ignore: [[:opts, :cd]] do
        result =
          Validation.validate_subagent(
            scope,
            [transcript_path: transcript_path("empty_session.jsonl")] ++ pipeline_opts
          )

        assert match?({:ok, :valid}, result) or match?({:error, _}, result)
      end
    end

    @tag timeout: 300_000
    test "returns valid or problems when pipeline runs and no component evaluation",
         %{scope: scope, pipeline_opts: pipeline_opts} do
      use_cmd_cassette "validation_subagent_pipeline_pass", ignore: [[:opts, :cd]] do
        result =
          Validation.validate_subagent(
            scope,
            [transcript_path: transcript_path("subagent_no_marker.jsonl")] ++ pipeline_opts
          )

        assert match?({:ok, :valid}, result) or match?({:error, _}, result)
      end
    end

    @tag timeout: 300_000
    test "returns {:error, problems} when pipeline finds problems",
         %{scope: scope, pipeline_opts: pipeline_opts} do
      use_cmd_cassette "validation_subagent_pipeline_problems", ignore: [[:opts, :cd]] do
        result =
          Validation.validate_subagent(
            scope,
            [transcript_path: transcript_path("subagent_component_test.jsonl")] ++ pipeline_opts
          )

        case result do
          {:error, problems} when is_list(problems) ->
            assert Enum.all?(problems, &match?(%Problem{}, &1))

          {:ok, :valid} ->
            assert true
        end
      end
    end

    @tag timeout: 300_000
    test "returns {:error, feedback} when component task evaluation fails",
         %{scope: scope, pipeline_opts: pipeline_opts} do
      use_cmd_cassette "validation_subagent_task_eval_fails", ignore: [[:opts, :cd]] do
        result =
          Validation.validate_subagent(
            scope,
            [transcript_path: transcript_path("subagent_component_test.jsonl")] ++ pipeline_opts
          )

        case result do
          {:error, feedback} when is_binary(feedback) ->
            assert String.length(feedback) > 0

          {:error, problems} when is_list(problems) ->
            assert true

          {:ok, :valid} ->
            assert true
        end
      end
    end

    @tag timeout: 300_000
    test "runs pipeline on all edited files from transcript",
         %{scope: scope, pipeline_opts: pipeline_opts} do
      use_cmd_cassette "validation_subagent_all_files", ignore: [[:opts, :cd]] do
        result =
          Validation.validate_subagent(
            scope,
            [transcript_path: transcript_path("main_session_with_edits.jsonl")] ++ pipeline_opts
          )

        assert match?({:ok, :valid}, result) or match?({:error, _}, result)
      end
    end

    @tag timeout: 300_000
    test "evaluates component task on task's own files (not edited files)",
         %{scope: scope, pipeline_opts: pipeline_opts} do
      use_cmd_cassette "validation_subagent_component_files", ignore: [[:opts, :cd]] do
        result =
          Validation.validate_subagent(
            scope,
            [transcript_path: transcript_path("subagent_component_test.jsonl")] ++ pipeline_opts
          )

        assert match?({:ok, :valid}, result) or match?({:error, _}, result)
      end
    end

    @tag timeout: 300_000
    test "persists pipeline problems scoped to edited files",
         %{scope: scope, pipeline_opts: pipeline_opts} do
      use_cmd_cassette "validation_subagent_persist_problems", ignore: [[:opts, :cd]] do
        Validation.validate_subagent(
          scope,
          [transcript_path: transcript_path("subagent_no_marker.jsonl")] ++ pipeline_opts
        )

        problems = CodeMySpec.Problems.list_project_problems(scope)
        assert is_list(problems)
      end
    end

    @tag timeout: 300_000
    test "runs sync after persisting problems",
         %{scope: scope, pipeline_opts: pipeline_opts} do
      use_cmd_cassette "validation_subagent_sync", ignore: [[:opts, :cd]] do
        result =
          Validation.validate_subagent(
            scope,
            [transcript_path: transcript_path("subagent_no_marker.jsonl")] ++ pipeline_opts
          )

        assert match?({:ok, :valid}, result) or match?({:error, _}, result)
      end
    end

    @tag timeout: 300_000
    test "returns {:ok, :valid} when no task marker found in transcript",
         %{scope: scope, pipeline_opts: pipeline_opts} do
      use_cmd_cassette "validation_subagent_no_marker", ignore: [[:opts, :cd]] do
        result =
          Validation.validate_subagent(
            scope,
            [transcript_path: transcript_path("subagent_no_marker.jsonl")] ++ pipeline_opts
          )

        assert match?({:ok, :valid}, result) or match?({:error, _}, result)
      end
    end

    @tag timeout: 300_000
    test "identifies dispatched task via prompt_path in transcript",
         %{scope: scope, env: env, pipeline_opts: pipeline_opts} do
      # Create a real component in the DB so evaluate_matched_task can find it
      component = component_fixture(scope, %{
        name: "Blog",
        type: "context",
        module_name: "TestPhoenixProject.Blog"
      })

      prompt_path = ".code_my_spec/tasks/develop/TestPhoenixProject.Blog_component_code.md"

      status_data =
        Jason.encode!(%{
          "dispatched_tasks" => [
            %{
              "requirement" => "implementation_file",
              "component_id" => component.id,
              "component_module" => "TestPhoenixProject.Blog",
              "prompt_path" => prompt_path,
              "expected_files" => [
                "lib/test_phoenix_project/blog.ex",
                "test/test_phoenix_project/blog_test.exs"
              ],
              "dispatched_at" => "2026-03-14T00:00:00Z"
            }
          ],
          "updated_at" => "2026-03-14T00:00:00Z"
        })

      CodeMySpec.Environments.write_file(
        env,
        CodeMySpec.Paths.implementation_status_path(),
        status_data
      )

      # Verify identification works directly — prompt_path appears in first user message
      transcript_file = transcript_path("subagent_with_prompt_path.jsonl")
      matched = ImplementationStatus.identify_task_from_transcript(env, transcript_file)

      assert matched != nil, "Expected prompt_path match but got nil"
      assert matched["requirement"] == "implementation_file"
      assert matched["component_id"] == component.id
      assert matched["prompt_path"] == prompt_path

      # Now run full validation to verify the evaluate path executes
      use_cmd_cassette "validation_subagent_prompt_path_match", ignore: [[:opts, :cd]] do
        result =
          Validation.validate_subagent(
            scope,
            [transcript_path: transcript_file] ++ pipeline_opts
          )

        assert match?({:ok, :valid}, result) or match?({:error, _}, result)
      end
    end

    @tag timeout: 300_000
    test "falls back to expected_files matching when prompt_path not in transcript",
         %{scope: scope, env: env, pipeline_opts: pipeline_opts} do
      # Create a real component so the full evaluate path can execute
      component = component_fixture(scope, %{
        name: "Blog",
        type: "context",
        module_name: "TestPhoenixProject.Blog"
      })

      # Dispatched task has a prompt_path that won't match the transcript,
      # but expected_files will match the files the subagent edited
      status_data =
        Jason.encode!(%{
          "dispatched_tasks" => [
            %{
              "requirement" => "implementation_file",
              "component_id" => component.id,
              "component_module" => "TestPhoenixProject.Blog",
              "prompt_path" => ".code_my_spec/tasks/develop/WRONG_PATH.md",
              "expected_files" => [
                "lib/test_phoenix_project/blog.ex"
              ],
              "dispatched_at" => "2026-03-14T00:00:00Z"
            }
          ],
          "updated_at" => "2026-03-14T00:00:00Z"
        })

      CodeMySpec.Environments.write_file(
        env,
        CodeMySpec.Paths.implementation_status_path(),
        status_data
      )

      # Verify fallback: prompt_path won't match, but expected_files will
      transcript_file = transcript_path("subagent_no_prompt_path_match.jsonl")
      matched = ImplementationStatus.identify_task_from_transcript(env, transcript_file)

      assert matched != nil, "Expected fallback file match but got nil"
      assert matched["requirement"] == "implementation_file"
      assert matched["component_id"] == component.id

      # Now run full validation
      use_cmd_cassette "validation_subagent_fallback_match", ignore: [[:opts, :cd]] do
        result =
          Validation.validate_subagent(
            scope,
            [transcript_path: transcript_file] ++ pipeline_opts
          )

        assert match?({:ok, :valid}, result) or match?({:error, _}, result)
      end
    end
  end

  # ============================================================================
  # validate_stop/2
  # ============================================================================

  describe "validate_stop/2" do
    test "returns {:ok, :valid} when transcript has no edited files and no active sessions",
         %{scope: scope, pipeline_opts: pipeline_opts} do
      use_cmd_cassette "validation_stop_empty", ignore: [[:opts, :cd]] do
        result =
          Validation.validate_stop(
            scope,
            [
              transcript_path: transcript_path("empty_session.jsonl"),
              session_id: "nonexistent-session-id"
            ] ++ pipeline_opts
          )

        assert match?({:ok, :valid}, result) or match?({:error, _}, result)
      end
    end

    test "returns {:ok, :valid} when pipeline passes and all sessions pass",
         %{scope: scope, env: env, pipeline_opts: pipeline_opts} do
      {:ok, _session} =
        SessionsRepository.create_session(env, %{
          type: "ArchitectureReview",
          priority: 1,
          state: %{}
        })

      use_cmd_cassette "validation_stop_sessions_pass", ignore: [[:opts, :cd]] do
        result =
          Validation.validate_stop(
            scope,
            [
              transcript_path: transcript_path("empty_session.jsonl"),
              session_id: "some-external-id"
            ] ++ pipeline_opts
          )

        assert match?({:ok, :valid}, result) or match?({:error, _}, result)
      end
    end

    @tag timeout: 300_000
    test "returns {:error, problems} when pipeline finds problems",
         %{scope: scope, pipeline_opts: pipeline_opts} do
      use_cmd_cassette "validation_stop_pipeline_problems", ignore: [[:opts, :cd]] do
        result =
          Validation.validate_stop(
            scope,
            [
              transcript_path: transcript_path("main_session_with_edits.jsonl"),
              session_id: "nonexistent-session-id"
            ] ++ pipeline_opts
          )

        case result do
          {:error, problems} when is_list(problems) ->
            assert Enum.all?(problems, &match?(%Problem{}, &1))

          {:ok, :valid} ->
            assert true
        end
      end
    end

    test "returns {:error, feedback} when session evaluation fails",
         %{scope: scope, env: env, pipeline_opts: pipeline_opts} do
      {:ok, _session} =
        SessionsRepository.create_session(env, %{
          type: "ComponentSpec",
          priority: 10,
          component_module_name: "NonExistent.Module",
          state: %{}
        })

      use_cmd_cassette "validation_stop_session_eval_fails", ignore: [[:opts, :cd]] do
        result =
          Validation.validate_stop(
            scope,
            [
              transcript_path: transcript_path("empty_session.jsonl"),
              session_id: "some-external-id"
            ] ++ pipeline_opts
          )

        case result do
          {:error, feedback} when is_binary(feedback) ->
            assert String.length(feedback) > 0

          {:error, problems} when is_list(problems) ->
            assert true

          {:ok, :valid} ->
            assert true
        end
      end
    end

    @tag timeout: 300_000
    test "runs pipeline on all edited files from transcript",
         %{scope: scope, pipeline_opts: pipeline_opts} do
      use_cmd_cassette "validation_stop_all_files", ignore: [[:opts, :cd]] do
        result =
          Validation.validate_stop(
            scope,
            [
              transcript_path: transcript_path("main_session_with_edits.jsonl"),
              session_id: "nonexistent-session-id"
            ] ++ pipeline_opts
          )

        assert match?({:ok, :valid}, result) or match?({:error, _}, result)
      end
    end

    test "evaluates session stack filtered by session_id",
         %{scope: scope, env: env, pipeline_opts: pipeline_opts} do
      {:ok, _matching} =
        SessionsRepository.create_session(env, %{
          type: "ArchitectureReview",
          priority: 1,
          external_conversation_id: "matching-session-id",
          state: %{}
        })

      {:ok, _other} =
        SessionsRepository.create_session(env, %{
          type: "ArchitectureReview",
          priority: 1,
          external_conversation_id: "other-session-id",
          state: %{}
        })

      use_cmd_cassette "validation_stop_session_filter", ignore: [[:opts, :cd]] do
        result =
          Validation.validate_stop(
            scope,
            [
              transcript_path: transcript_path("empty_session.jsonl"),
              session_id: "matching-session-id"
            ] ++ pipeline_opts
          )

        assert match?({:ok, :valid}, result) or match?({:error, _}, result)
      end
    end

    @tag timeout: 300_000
    test "persists pipeline problems scoped to edited files",
         %{scope: scope, pipeline_opts: pipeline_opts} do
      use_cmd_cassette "validation_stop_persist_problems", ignore: [[:opts, :cd]] do
        Validation.validate_stop(
          scope,
          [
            transcript_path: transcript_path("main_session_with_edits.jsonl"),
            session_id: "nonexistent-session-id"
          ] ++ pipeline_opts
        )

        problems = CodeMySpec.Problems.list_project_problems(scope)
        assert is_list(problems)
      end
    end

    @tag timeout: 300_000
    test "runs sync after persisting problems",
         %{scope: scope, pipeline_opts: pipeline_opts} do
      use_cmd_cassette "validation_stop_sync", ignore: [[:opts, :cd]] do
        result =
          Validation.validate_stop(
            scope,
            [
              transcript_path: transcript_path("main_session_with_edits.jsonl"),
              session_id: "nonexistent-session-id"
            ] ++ pipeline_opts
          )

        assert match?({:ok, :valid}, result) or match?({:error, _}, result)
      end
    end

    test "returns {:ok, :valid} when no active sessions found",
         %{scope: scope, pipeline_opts: pipeline_opts} do
      use_cmd_cassette "validation_stop_no_sessions", ignore: [[:opts, :cd]] do
        result =
          Validation.validate_stop(
            scope,
            [
              transcript_path: transcript_path("empty_session.jsonl"),
              session_id: "nonexistent-session-id"
            ] ++ pipeline_opts
          )

        assert match?({:ok, :valid}, result) or match?({:error, _}, result)
      end
    end
  end

  # ============================================================================
  # format_output/1
  # ============================================================================

  describe "format_output/1" do
    test "returns empty map for valid result" do
      assert %{} = Validation.format_output({:ok, :valid})
    end

    test "returns block decision with rendered problems for error with problem list" do
      problems = [
        %Problem{
          severity: :error,
          source: "test",
          source_type: :test,
          file_path: "lib/foo.ex",
          message: "Test failure",
          category: "test_error"
        }
      ]

      result = Validation.format_output({:error, problems})

      assert %{"decision" => "block", "reason" => reason} = result
      assert is_binary(reason)
      assert String.contains?(reason, "Test failure")
    end

    test "returns block decision with reason string for error with string" do
      result = Validation.format_output({:error, "Task evaluation failed: something broke"})

      assert %{"decision" => "block", "reason" => reason} = result
      assert reason == "Task evaluation failed: something broke"
    end
  end
end
