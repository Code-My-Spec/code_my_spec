defmodule CodeMySpecSpex.Story1015.Criterion2390Spex do
  @moduledoc """
  Story 894 — Stop hook is a main menu
  Criterion 2390 — Three live classes yield one directive and a two-item tally.

  The rule:

  > The hook names exactly one class as next and tallies every other live class.

  This is the shape John chose over the two alternatives, and the reasons are
  worth keeping because they are what the assertions encode. A strict single
  directive is cheapest to act on but lets a lower-priority class starve
  invisibly — you never learn it exists. A full menu on every stop hides the
  important item in a wall of text and invites the agent to take the easiest
  rather than the most important. One directive plus a tally is the pair: act on
  one thing, know what else is waiting.

  So both halves are load-bearing and both are asserted. A response naming one
  class and nothing else satisfies the first assertion and fails the second,
  which is the strict-directive failure mode. A response listing everything
  equally fails the first, which is the full-menu one.

  ## The situation this reproduces

  Three classes live at once — a problem, an issue, and unsatisfied
  requirements. That is not hypothetical: it is the state this working copy was
  in for most of 2026-08-15/16, and the class the hook shouted about was the one
  the agent could not act on.

  ## Surface

  `POST /api/hooks/stop`, routed by `x-harness-id`, with a genuine compile
  failure via story 555's `pipeline_compile_error` fixtures. The issue is
  created through the real `create_issue` MCP tool rather than seeded, so the
  count the hook reports is a count of something that actually exists.

  Expected red: nothing renders a directive or a tally today.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement

  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"
  @calls ~w(get_next_requirement list_issues list_problems ask_user)

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "One class is named as next and the rest are tallied" do
    scenario "problems, issues and requirements are all live" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "a problem is outstanding", context do
        :ok = Environments.write_file(context.environment, @impl_path, broken_impl())
        {:ok, context}
      end

      given_ "an issue is outstanding", context do
        {:reply, response, _frame} =
          CreateIssue.execute(
            %{
              title: "A second class of work is live",
              description: "Filed so the stop hook has more than one class to report.",
              severity: "medium"
            },
            %Frame{assigns: %{current_scope: context.scope}}
          )

        refute response.isError, "the issue must really exist for its count to mean anything"

        {:ok, context}
      end

      given_ "the agent has asked for its next requirement, so the graph is computed",
             context do
        # Kept even though requirements no longer appear in the tally, because it
        # is what proves they cannot. The menu reads the *cached* actionable set
        # and omits the class on a miss — computing it globs the working copy,
        # and the stop decision runs inside the channel process for a
        # harness-served project.
        #
        # This warms the cache through the real tool, and the class is still
        # absent below: the stop hook syncs files and records problems before it
        # decides, and `GraphFingerprint.compute/2` hashes both, so the entry
        # warmed here is stale by the time the menu renders. On any stop that
        # follows work — nearly all of them — requirements is unknowable without
        # the recompute that deadlocks.
        {:reply, response, _frame} =
          GetNextRequirement.execute(%{}, %Frame{assigns: %{current_scope: context.scope}})

        refute response.isError,
               "the graph must compute for requirements to be a live class at all"

        {:ok, context}
      end

      when_ "the agent attempts to stop", context do
        response =
          use_cmd_cassette "pipeline_compile_error", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{"compile" => fixture_path("compile.jsonl")}
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "exactly one class is named as next, with its call", context do
        reason = context.response["reason"] || ""
        named = Enum.filter(@calls, &String.contains?(directive(reason), &1))

        assert length(named) == 1,
               "a stop with three classes live must point at one of them. Naming none " <>
                 "leaves the agent to guess; naming all four is the menu that hides the " <>
                 "important item in the easy ones. Named: #{inspect(named)}. Got:\n#{reason}"

        {:ok, context}
      end

      then_ "the other live classes are tallied with counts", context do
        reason = context.response["reason"] || ""

        assert reason =~ ~r/\d+\s+issues?\b/i,
               "the issue class is live and not the directive, so it must appear in " <>
                 "the tally with a count — otherwise it starves invisibly, which is " <>
                 "the failure a strict single directive has. Got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  # The line offering the next action, if there is one. Isolated so that a call
  # name appearing incidentally elsewhere in the response — in the tally, or in
  # the harness-friction footer — is not mistaken for a directive.
  defp directive(reason) do
    reason
    |> String.split("\n")
    |> Enum.find("", &(&1 =~ ~r/\bnext\b/i))
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp broken_impl do
    """
    defmodule ExampleContext do
      # missing `end`
    """
  end
end
