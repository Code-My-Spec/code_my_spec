defmodule CodeMySpecSpex.Story1080.Criterion2163Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2163 — A declined offer stays on the agent until main acts.

  Per product: not built as of this writing -- `Offers.supersede_queued/1`
  and the normal re-offer path only ever touch `:open` records, never
  `:declined` (confirmed by reading `offers.ex`). Written prescriptive
  against `AssignIssueToWorkingCopy` (`CodeMySpec.Agents.assign_issue_to_working_copy/4`,
  the mechanism story 1091's criteria 1876/1882 already use for main
  assigning or moving work) for the two closing triggers that are main
  actions, and against the real re-offer path for the third. Expected to
  fail until each one actually closes a declined record.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers, only: [put_to_work: 1]
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_issue_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.AssignIssueToWorkingCopy
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  defp a_copy(context, label) do
    {:ok, copy} =
      WorkingCopies.issue(context.scope, nil,
        label: label,
        device: Fixtures.device_fixture(context.scope)
      )

    %{context.scope | active_working_copy_id: copy.id}
  end

  defp an_accepted_issue(context, title) do
    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, created, _} =
      CreateIssue.execute(%{title: title, description: "seen in QA", severity: "high"}, frame)

    refute created.isError, response_text(created)
    issue_id = extract_issue_id!(created)
    {:reply, accepted, _} = AcceptIssue.execute(%{issue_id: issue_id}, frame)
    refute accepted.isError, response_text(accepted)
    issue_id
  end

  # Team A holds a declined offer on an accepted issue. Shared by every
  # scenario below, each starting fresh from this state.
  defp declined_offer(context) do
    copy_a = a_copy(context, "team-a")
    coder_a = Fixtures.running_agent(copy_a, role: "coding", continuous: true)
    _qa_a = Fixtures.running_agent(copy_a, role: "qa", continuous: false)

    issue_id = an_accepted_issue(context, "The export button does nothing")
    main_frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, assigned, _} =
      AssignIssueToWorkingCopy.execute(
        %{issue_id: issue_id, working_copy_id: copy_a.active_working_copy_id},
        main_frame
      )

    refute assigned.isError, response_text(assigned)

    _ = put_to_work(%{scope: copy_a})
    id = coder_a.id
    assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000

    :ok =
      Fixtures.agent_tool_call(copy_a, %{id: id}, "r1", "reject_offer", %{
        "reason" => "not able to reproduce"
      })

    {:reply, rejected, _} =
      CodeMySpec.McpServers.LocalServer.handle_tool_call(
        "reject_offer",
        %{reason: "not able to reproduce"},
        %Frame{assigns: %{current_scope: copy_a, agent_id: id}}
      )

    refute rejected.isError, response_text(rejected)
    assert [%{status: "declined"}] = offers(context, id, %{kind: "work"})

    Map.merge(context, %{issue_id: issue_id, copy_a: copy_a, coder_a: id, main_frame: main_frame})
  end

  spex "Nothing but main's own action closes a declined offer", criterion: 2163 do
    scenario "re-offering the same work closes it" do
      given_ "a coder declined an offer on an accepted issue", context do
        {:ok, declined_offer(context)}
      end

      when_ "the same work is offered to it again", context do
        _ = put_to_work(%{scope: context.copy_a})
        id = context.coder_a
        assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000
        {:ok, context}
      end

      then_ "the declined offer is closed, recording that the re-offer closed it", context do
        assert [newest, old | _] = offers(context, context.coder_a, %{kind: "work"})
        refute old.status == "declined", "re-offering did not close the earlier decline"
        assert newest.status == "open"
        {:ok, context}
      end
    end

    scenario "main reassigning the work to another team closes it" do
      given_ "a coder declined an offer on an accepted issue, and an idle team B", context do
        context = declined_offer(context)
        copy_b = a_copy(context, "team-b")
        _coder_b = Fixtures.running_agent(copy_b, role: "coding", continuous: false)
        _qa_b = Fixtures.running_agent(copy_b, role: "qa", continuous: false)
        {:ok, Map.put(context, :copy_b, copy_b)}
      end

      when_ "main assigns the issue to team B instead", context do
        {:reply, reassigned, _} =
          AssignIssueToWorkingCopy.execute(
            %{
              issue_id: context.issue_id,
              working_copy_id: context.copy_b.active_working_copy_id,
              reason: "Team A could not reproduce it; team B will look."
            },
            context.main_frame
          )

        refute reassigned.isError, response_text(reassigned)
        {:ok, context}
      end

      then_ "the declined offer on team A's coder closes, recording that reassignment closed it",
            context do
        assert [closed | _] = offers(context, context.coder_a, %{kind: "work"})
        refute closed.status == "declined", "reassigning the work did not close the decline"
        {:ok, context}
      end
    end

    scenario "main giving the agent other work closes its declined offer" do
      given_ "a coder declined an offer on an accepted issue, and a second accepted issue",
             context do
        context = declined_offer(context)
        other_issue_id = an_accepted_issue(context, "The receipt total is wrong")
        {:ok, Map.put(context, :other_issue_id, other_issue_id)}
      end

      when_ "main assigns the coder's team the other issue instead", context do
        {:reply, redirected, _} =
          AssignIssueToWorkingCopy.execute(
            %{
              issue_id: context.other_issue_id,
              working_copy_id: context.copy_a.active_working_copy_id
            },
            context.main_frame
          )

        refute redirected.isError, response_text(redirected)
        {:ok, context}
      end

      then_ "the declined offer on the old issue closes, recording that main redirected the agent",
            context do
        assert [closed | _] = offers(context, context.coder_a, %{kind: "work"})
        refute closed.status == "declined", "giving the agent other work did not close the decline"
        {:ok, context}
      end
    end

    # Restart is left to criteria 1801/1802/1808, which already cover what a
    # harness restart does and does not do to an open offer; it is not
    # re-derived here for this specific declined record.
    scenario "nothing else closes it: not time passing, not a tap-out" do
      given_ "a coder declined an offer on an accepted issue", context do
        {:ok, declined_offer(context)}
      end

      when_ "time passes and it taps out instead of main acting", context do
        {:reply, tapped, _} =
          TapOut.execute(
            %{reason: "Already handled elsewhere"},
            %Frame{assigns: %{current_scope: context.copy_a, agent_id: context.coder_a}}
          )

        refute tapped.isError, response_text(tapped)
        {:ok, context}
      end

      then_ "the offer is still declined", context do
        assert [%{status: "declined"}] = offers(context, context.coder_a, %{kind: "work"}),
               listing(context)

        {:ok, context}
      end
    end
  end
end
