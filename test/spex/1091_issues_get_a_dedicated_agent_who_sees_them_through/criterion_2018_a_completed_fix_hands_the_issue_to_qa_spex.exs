defmodule CodeMySpecSpex.Story1091.Criterion2018Spex do
  @moduledoc "A completed fix hands the issue to QA without permitting a duplicate coding task."
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A completed fix is offered to QA alone", criterion: 2018 do
    scenario "The coder cannot claim the submitted fix again" do
      given_ "a coder has claimed an accepted issue assigned to its team", context do
        context = context |> Slice.main_copy() |> Slice.staff() |> Slice.git_backed()
        coder = Enum.find(context.team, &(&1.role == :coding))
        qa = Enum.find(context.team, &(&1.role == :qa))

        main_frame = %Frame{
          assigns: %{current_scope: context.main_scope, agent_id: context.main.id}
        }

        coder_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}
        qa_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: qa.id}}

        created =
          ToolLibrary.run(
            "create_issue",
            %{
              title: "A notification is lost",
              description: "Restore notification delivery.",
              severity: "high",
              scope: "framework"
            },
            Map.put(main_frame.assigns, :scope, main_frame.assigns[:current_scope])
          )

        {:ok, _} = created
        issue_id = extract_issue_id!(created)

        accepted =
          ToolLibrary.run(
            "accept_issue",
            %{issue_id: issue_id},
            Map.put(main_frame.assigns, :scope, main_frame.assigns[:current_scope])
          )

        {:ok, _} = accepted

        assigned =
          ToolLibrary.run(
            "assign_issue_to_working_copy",
            %{issue_id: issue_id, working_copy_id: context.scope.active_working_copy_id},
            Map.put(main_frame.assigns, :scope, main_frame.assigns[:current_scope])
          )

        {:ok, _} = assigned

        offered =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(coder_frame.assigns, :scope, coder_frame.assigns[:current_scope])
          )

        {:ok, _} = offered
        true = response_text(offered) =~ "requirement_name=`fix_issue`"
        params = %{requirement_name: "fix_issue", entity_type: "issue", entity_id: issue_id}

        started =
          ToolLibrary.run(
            "start_task",
            params,
            Map.put(coder_frame.assigns, :scope, coder_frame.assigns[:current_scope])
          )

        {:ok, _} = started

        {:ok,
         Map.merge(context, %{
           coder_frame: coder_frame,
           qa_frame: qa_frame,
           params: params,
           task_id: extract_task_id!(started),
           issue_id: issue_id
         })}
      end

      when_ "the coder evaluates its fix successfully", context do
        Fixtures.fresh_analysis_runs(context.scope, ~w(compiler credo exunit spex), at_head: true)

        evaluated =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id},
            Map.put(
              context.coder_frame.assigns,
              :scope,
              context.coder_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, evaluated), response_text(evaluated)
        {:ok, context}
      end

      then_ "the coder has no fix offer and a repeated claim is refused", context do
        offered =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(
              context.coder_frame.assigns,
              :scope,
              context.coder_frame.assigns.current_scope
            )
          )

        assert match?({:ok, _}, offered), response_text(offered)
        refute response_text(offered) =~ "requirement_name=`fix_issue`"

        duplicate =
          ToolLibrary.run(
            "start_task",
            context.params,
            Map.put(
              context.coder_frame.assigns,
              :scope,
              context.coder_frame.assigns[:current_scope]
            )
          )

        assert match?({:error, _}, duplicate), response_text(duplicate)
        {:ok, context}
      end

      then_ "QA is offered and can claim the submitted issue", context do
        offered =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(context.qa_frame.assigns, :scope, context.qa_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, offered), response_text(offered)
        assert response_text(offered) =~ "requirement_name=`qa_complete`"
        assert response_text(offered) =~ "entity_id=`#{context.issue_id}`"

        started =
          ToolLibrary.run(
            "start_task",
            %{requirement_name: "qa_complete", entity_type: "issue", entity_id: context.issue_id},
            Map.put(context.qa_frame.assigns, :scope, context.qa_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, started), response_text(started)
        {:ok, context}
      end
    end
  end
end
