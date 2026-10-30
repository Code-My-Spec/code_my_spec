defmodule CodeMySpecSpex.TreeCertificationHelpers do
  @moduledoc """
  The coding agent certifying its copy through `start_analysis`, with the
  scenario playing the copy's harness: it reports the commit, tree and
  cleanliness each run started on, and what the run found (story 1174).

  Needs `a_promotable_project(agent_socket: true)` and `an_agent_on_the_copy/1`.
  """

  import ExUnit.Assertions
  import Phoenix.ChannelTest, only: [push: 3, assert_reply: 4]
  import CodeMySpecSpex.PromotionHelpers, only: [git: 3, head_of: 2]

  alias CodeMySpec.ToolLibrary

  @doc "What `start_analysis` answered the agent."
  def start_analysis(context, source, params \\ %{}) do
    {_status, text} =
      ToolLibrary.run(
        "start_analysis",
        Map.put(params, :source, source),
        %{scope: context.scope, agent_id: context.agent_id}
      )

    text
  end

  @doc "The run the copy's harness was asked for next, as dispatched."
  def the_copy_is_asked_to_run(%{agent_socket: %{join_ref: join_ref}}) do
    receive do
      %Phoenix.Socket.Message{
        event: "run_analysis",
        join_ref: ^join_ref,
        payload: %{"runs" => [run]}
      } ->
        run
    after
      10_000 -> flunk("the copy's harness was never asked to run anything")
    end
  end

  @doc "No run reached the copy's harness."
  def the_copy_is_asked_to_run_nothing(%{agent_socket: %{join_ref: join_ref}}) do
    refute_receive %Phoenix.Socket.Message{event: "run_analysis", join_ref: ^join_ref}, 500
  end

  @doc """
  The copy's harness answers `run` from the checkout as it is now: started and
  finished at its HEAD, with its tree unless `dirty: true` (a harness reports
  no tree for a dirty start), finding `findings` (none by default).
  """
  def the_harness_answers(context, %{"run_id" => id, "source" => source}, opts \\ []) do
    head = head_of(context, context.agent_root)
    dirty = Keyword.get(opts, :dirty, false)

    push(context.agent_socket, "analysis_started", %{
      "run_id" => id,
      "source" => source,
      "start_commit" => head,
      "start_tree_dirty" => dirty,
      "start_tree" => if(dirty, do: nil, else: tree_of(context, context.agent_root))
    })

    ref =
      push(context.agent_socket, "analysis_result", %{
        "run_id" => id,
        "source" => source,
        "status" => "ok",
        "completed_commit" => head,
        "result" => raw_result(source, Keyword.get(opts, :findings, []))
      })

    assert_reply(ref, :ok, _, 10_000)
    the_agent_reads_its_result(context, id)
    id
  end

  # The result is delivered to the agent that asked, as a turn; it reads it and
  # ends the turn, so the next delivery (a promotion's outcome) reaches it.
  defp the_agent_reads_its_result(%{agent_id: agent_id} = context, run_id) do
    receive do
      {:agent_dispatch, ^agent_id, ref, message} ->
        assert message =~ "run #{run_id} ", message
        CodeMySpecSpex.Fixtures.deliver_agent_message(context.scope, agent_id, ref)
        :ok = CodeMySpecSpex.Fixtures.end_turn(context.scope, agent_id)
    after
      10_000 -> flunk("the agent was never told run #{run_id} finished")
    end
  end

  @doc "Each of `sources` run in full on the copy through `start_analysis`, and passed."
  def the_copy_passes(context, sources) do
    Map.new(sources, fn source ->
      start_analysis(context, source)
      {source, the_harness_answers(context, the_copy_is_asked_to_run(context))}
    end)
  end

  @doc """
  What the queue told the promoting agent once it decided, past the answers
  to the agent's own certifying runs.
  """
  def the_promotion_outcome(context),
    do: CodeMySpecSpex.PromotionHelpers.what_the_agent_was_told(context)

  @doc "The git tree of the checkout's HEAD."
  def tree_of(context, root) do
    {out, 0} = git(context, root, ["rev-parse", "HEAD^{tree}"])
    String.trim(out)
  end

  @doc "No run reached the gate's harness."
  def the_gate_is_asked_to_run_nothing(%{gate_socket: %{join_ref: join_ref}}) do
    refute_received %Phoenix.Socket.Message{event: "run_analysis", join_ref: ^join_ref}
  end

  @doc "A test failure, as the harness reports one."
  def a_failing_test(file) do
    %{"file" => file, "line" => 4, "severity" => "error", "message" => "assertion failed"}
  end

  defp raw_result("exunit", diagnostics),
    do: %{
      "execution_status" => if(diagnostics == [], do: "success", else: "failure"),
      "exit_status" => if(diagnostics == [], do: 0, else: 2),
      "stats" => %{"tests" => 12 + length(diagnostics), "failures" => length(diagnostics)},
      "diagnostics" => diagnostics
    }

  defp raw_result(_source, diagnostics),
    do: %{"exit_status" => if(diagnostics == [], do: 0, else: 1), "diagnostics" => diagnostics}
end
