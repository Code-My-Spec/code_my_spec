defmodule CodeMySpecSpex.Story1158.Criterion2462Spex do
  @moduledoc """
  Story 1158 — QA plans and briefs are documents in the database.
  Criterion 2462 — Merging main brings no QA plan conflict.

  A real Git merge exercises the working-copy boundary. The plan change goes
  through the document tool while the branches diverge.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "a plan document change cannot conflict with a working copy's merge", criterion: 2462 do
    scenario "main changes after the copy branches" do
      given_ "a working copy branched from main before the QA plan changed", context do
        root = CodeMySpec.TempFile.owned_dir("qa_plan_merge")
        git!(root, ["init", "-q", "-b", "main"])
        git!(root, ["config", "user.name", "Spex"])
        git!(root, ["config", "user.email", "spex@example.test"])
        File.write!(Path.join(root, "README.md"), "initial project\n")
        git!(root, ["add", "README.md"])
        git!(root, ["commit", "-qm", "base"])
        git!(root, ["checkout", "-qb", "working-copy"])
        File.write!(Path.join(root, "copy.txt"), "work on the copy\n")
        git!(root, ["add", "copy.txt"])
        git!(root, ["commit", "-qm", "copy work"])
        git!(root, ["checkout", "-q", "main"])

        response =
          ToolLibrary.run(
            "write_document",
            %{document_type: "qa_plan", content: changed_plan()},
            %{current_scope: context.scope, scope: context.scope}
          )

        refute response.isError, response_text(response)
        File.write!(Path.join(root, "main.txt"), "later work on main\n")
        git!(root, ["add", "main.txt"])
        git!(root, ["commit", "-qm", "main work"])
        {:ok, Map.put(context, :root, root)}
      end

      when_ "the working copy merges main", context do
        git!(context.root, ["checkout", "-q", "working-copy"])
        merge_output = git!(context.root, ["merge", "--no-edit", "main"])
        {:ok, Map.put(context, :merge_output, merge_output)}
      end

      then_ "the merge succeeds without a QA plan conflict", context do
        assert context.merge_output =~ "Merge made by"
        assert git!(context.root, ["diff", "--name-only", "--diff-filter=U"]) == ""
        assert git!(context.root, ["status", "--porcelain"]) == ""
        assert git!(context.root, ["ls-files", ".code_my_spec/qa/plan.md"]) == ""

        response =
          ToolLibrary.run(
            "read_document",
            %{document_type: "qa_plan"},
            %{current_scope: context.scope, scope: context.scope}
          )

        refute response.isError, response_text(response)
        assert response_text(response) =~ "Sign in before testing."
        {:ok, context}
      end
    end
  end

  defp changed_plan do
    """
    # QA Plan

    ## App Overview

    Sign in before testing.

    ## Tools Registry

    Use a browser to exercise the application.

    ## Seed Strategy

    Seed a QA account.
    """
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{output}"
    String.trim(output)
  end
end
