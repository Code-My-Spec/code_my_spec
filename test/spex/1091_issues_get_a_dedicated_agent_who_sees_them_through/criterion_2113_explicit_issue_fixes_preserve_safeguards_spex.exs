defmodule CodeMySpecSpex.Story1091.Criterion2113Spex do
  @moduledoc "Explicit issue fixes retain scope, reviewable evidence and regression guidance."
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Project issue fixes retain the useful safeguards from story 608", criterion: 2113 do
    scenario "Coding submits reviewable evidence for a scope-aware fix" do
      given_ "an explicit bag contains app, QA and documentation issues", context do
        context = context |> Slice.main_copy() |> Slice.staff()
        coder = Enum.find(context.team, &(&1.role == :coding))
        main_context = %{context | scope: context.main_scope}

        issues =
          for scope <- [:app, :qa, :docs] do
            issue =
              Fixtures.issue_fixture(context.scope, %{
                status: :accepted,
                scope: scope,
                severity: :high
              })

            Slice.call(
              main_context,
              "assign_issue_to_working_copy",
              %{issue_id: issue.id, working_copy_id: context.scope.active_working_copy_id},
              %{agent_id: context.main.id}
            )

            issue
          end

        [issue | _] = issues

        prompt =
          Slice.call(
            context,
            "start_task",
            %{requirement_name: "fix_issue", entity_type: "issue", entity_id: issue.id},
            %{agent_id: coder.id}
          )

        {:ok,
         Map.merge(context, %{
           issues: issues,
           issue: issue,
           coder: coder,
           prompt: prompt,
           task_id: extract_task_id!(prompt)
         })}
      end

      then_ "the fix instructions preserve regression and evidence safeguards", context do
        assert context.prompt =~ ~r/regression/i
        assert context.prompt =~ ~r/skip|silenc|pending/i
        assert context.prompt =~ ~r/files/i
        assert context.prompt =~ ~r/verif/i

        for issue <- context.issues do
          text =
            Slice.call(context, "get_issue", %{issue_id: issue.id}, %{agent_id: context.coder.id})

          assert text =~ "**Scope:** #{issue.scope}"
        end

        {:ok, context}
      end

      when_ "coding records the fix and submits it to QA", context do
        evidence =
          "Fixed missing delivery. Files: lib/example.ex. Verification: mix test passes, including regression coverage."

        Slice.call(context, "update_issue", %{issue_id: context.issue.id, append: evidence}, %{
          agent_id: context.coder.id
        })

        Slice.call(context, "evaluate_task", %{task_id: context.task_id}, %{
          agent_id: context.coder.id
        })

        {:ok, Map.put(context, :evidence, evidence)}
      end

      then_ "QA can read the change files and verification without a premature resolution",
            context do
        text =
          Slice.call(context, "get_issue", %{issue_id: context.issue.id}, %{
            agent_id: context.coder.id
          })

        assert text =~ context.evidence
        assert text =~ "**Status:** accepted"
        {:ok, context}
      end
    end
  end
end
