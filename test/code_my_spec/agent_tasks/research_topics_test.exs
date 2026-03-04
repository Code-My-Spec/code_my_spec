defmodule CodeMySpec.AgentTasks.ResearchTopicsTest do
  @moduledoc false
  use CodeMySpecTest.DataCase

  import ExUnit.CaptureLog
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.{ResearchTopics, TechnicalStrategy}
  alias CodeMySpec.Environments.Environment

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp create_scope(_context) do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    scope = %{scope | environment: Environment.new(:local, tmp_dir)}
    %{scope: scope, tmp_dir: tmp_dir}
  end

  defp create_session(context) do
    %{scope: scope} = context
    session = %{project: scope.active_project}
    Map.put(context, :session, session)
  end

  defp write_file!(env, relative_path, content) do
    full_path = Path.join(env.cwd, relative_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, content)
  end

  # Write a decision ADR file for the given topic.
  defp write_decision(env, topic, content \\ nil) do
    write_file!(
      env,
      ".code_my_spec/architecture/decisions/#{topic}.md",
      content ||
        """
        # Use #{topic}

        ## Status
        Accepted

        ## Decision
        We decided to use #{topic}.
        """
    )
  end

  # Write all pre-made decision ADR files so they are present as "decided" topics.
  defp write_premade_decisions(env) do
    for d <- TechnicalStrategy.premade_decisions() do
      write_decision(env, d.topic)
    end
  end

  # Write a framework coverage file (simulates a file in .code_my_spec/framework/).
  defp write_framework_file(env, filename) do
    write_file!(env, ".code_my_spec/framework/#{filename}", "# Framework knowledge for #{filename}")
  end

  # Write a framework coverage directory (simulates a sub-directory in .code_my_spec/framework/).
  defp write_framework_dir_entry(env, dirname) do
    write_file!(
      env,
      ".code_my_spec/framework/#{dirname}/overview.md",
      "# Framework knowledge for #{dirname}"
    )
  end

  # Write a knowledge entry to make ResearchTopic.evaluate/3 pass for a topic.
  defp write_knowledge(env, topic) do
    write_file!(
      env,
      ".code_my_spec/knowledge/#{topic}/getting_started.md",
      "# Getting Started with #{topic}\n\nInstall #{topic}..."
    )
  end

  # Returns the list of pre-made topic strings.
  defp premade_topics do
    Enum.map(TechnicalStrategy.premade_decisions(), & &1.topic)
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    setup [:create_scope, :create_session]

    test "returns ok tuple with non-empty prompt string", %{scope: scope, session: session} do
      assert {:ok, prompt} = ResearchTopics.command(scope, session)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "excludes pre-made decision topics from research list", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_premade_decisions(env)
      write_decision(env, "stripe")

      assert {:ok, prompt} = ResearchTopics.command(scope, session)

      for topic <- premade_topics() do
        # Pre-made topics should not appear as topics needing research.
        # They may appear in a skip list, but not as items to research.
        refute prompt =~ ~r/research.*#{topic}/i
      end
    end

    test "excludes topics covered by framework directory", %{scope: scope, session: session} do
      env = scope.environment
      write_decision(env, "boundary")
      write_framework_file(env, "boundary.md")

      assert {:ok, prompt} = ResearchTopics.command(scope, session)

      # boundary is covered by framework, so it should not appear as needing research
      refute prompt =~ ~r/research.*boundary/i
    end

    test "includes ADR content for topics needing research", %{scope: scope, session: session} do
      env = scope.environment

      write_decision(
        env,
        "stripe",
        """
        # Use Stripe for Payments

        ## Status
        Accepted

        ## Decision
        We will use Stripe to process payments.
        """
      )

      assert {:ok, prompt} = ResearchTopics.command(scope, session)
      assert prompt =~ "Stripe for Payments"
      assert prompt =~ "process payments"
    end

    test "instructs to dispatch subagents (does NOT name a specific subagent)", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_decision(env, "stripe")

      assert {:ok, prompt} = ResearchTopics.command(scope, session)

      # Should instruct dispatch of subagents in general
      assert prompt =~ ~r/dispatch|subagent/i

      # Must NOT name a specific subagent using the @"CodeMySpec:" pattern
      refute prompt =~ ~r/@"CodeMySpec:/
    end

    test "lists skipped topics with reason", %{scope: scope, session: session} do
      env = scope.environment
      write_premade_decisions(env)

      assert {:ok, prompt} = ResearchTopics.command(scope, session)

      # Pre-made topics must appear in a skip section with explanation
      assert prompt =~ ~r/skip|pre-made|already covered/i
    end

    test "returns prompt noting no research needed when all topics are covered", %{
      scope: scope,
      session: session
    } do
      env = scope.environment

      # Write a decision for a framework-covered topic only
      write_decision(env, "liveview")
      write_framework_dir_entry(env, "liveview")

      # Also write all pre-made decisions so everything is covered
      write_premade_decisions(env)

      assert {:ok, prompt} = ResearchTopics.command(scope, session)

      # When no topics need research, prompt should note that
      assert prompt =~ ~r/no (topics|research)|all (topics|decisions) (are )?covered/i
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_session]

    test "returns {:ok, :valid} when no topics need research (all pre-made or framework-covered)",
         %{scope: scope, session: session} do
      env = scope.environment

      # Only write pre-made decision topics — all are covered by pre-made list
      write_premade_decisions(env)

      capture_log(fn ->
        assert {:ok, :valid} = ResearchTopics.evaluate(scope, session)
      end)
    end

    test "returns {:ok, :valid} when all qualifying topics pass ResearchTopic.evaluate/3", %{
      scope: scope,
      session: session
    } do
      env = scope.environment
      write_premade_decisions(env)
      write_decision(env, "stripe")

      # Write knowledge so ResearchTopic.evaluate passes for "stripe"
      write_knowledge(env, "stripe")

      capture_log(fn ->
        assert {:ok, :valid} = ResearchTopics.evaluate(scope, session)
      end)
    end

    test "returns {:ok, :invalid, feedback} when qualifying topics fail ResearchTopic.evaluate/3",
         %{scope: scope, session: session} do
      env = scope.environment
      write_premade_decisions(env)

      # Write a qualifying (non-pre-made, non-framework-covered) decision topic
      # but do NOT write knowledge entries — ResearchTopic.evaluate should fail
      write_decision(env, "stripe")

      capture_log(fn ->
        assert {:ok, :invalid, feedback} = ResearchTopics.evaluate(scope, session)
        assert is_binary(feedback)
        assert String.length(feedback) > 0
        assert feedback =~ "stripe"
      end)
    end

    test "reports multiple incomplete topics in feedback", %{scope: scope, session: session} do
      env = scope.environment
      write_premade_decisions(env)

      # Write two qualifying topics with no knowledge entries
      write_decision(env, "stripe")
      write_decision(env, "sendgrid")

      capture_log(fn ->
        assert {:ok, :invalid, feedback} = ResearchTopics.evaluate(scope, session)
        assert feedback =~ "stripe"
        assert feedback =~ "sendgrid"
      end)
    end

    test "does not check pre-made decision topics", %{scope: scope, session: session} do
      env = scope.environment

      # Write only pre-made decisions — no knowledge entries for them
      # This should still return valid because pre-made topics are excluded
      write_premade_decisions(env)

      capture_log(fn ->
        assert {:ok, :valid} = ResearchTopics.evaluate(scope, session)
      end)
    end

    test "does not check framework-covered topics", %{scope: scope, session: session} do
      env = scope.environment

      # Write a decision for a topic covered by the framework directory,
      # but no knowledge entries — should still be valid
      write_decision(env, "boundary")
      write_framework_file(env, "boundary.md")

      capture_log(fn ->
        assert {:ok, :valid} = ResearchTopics.evaluate(scope, session)
      end)
    end

    test "returns {:ok, :valid} when there are no decided topics at all", %{
      scope: scope,
      session: session
    } do
      # No decision files written — nothing to check
      capture_log(fn ->
        assert {:ok, :valid} = ResearchTopics.evaluate(scope, session)
      end)
    end

    test "qualifying topic covered by framework directory as a sub-directory is skipped", %{
      scope: scope,
      session: session
    } do
      env = scope.environment

      # Write a decision for "liveview" and make it framework-covered via directory
      write_decision(env, "liveview")
      write_framework_dir_entry(env, "liveview")

      capture_log(fn ->
        assert {:ok, :valid} = ResearchTopics.evaluate(scope, session)
      end)
    end
  end
end
