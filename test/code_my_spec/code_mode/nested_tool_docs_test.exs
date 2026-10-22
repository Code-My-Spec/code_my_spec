defmodule CodeMySpec.CodeMode.NestedToolDocsTest do
  use ExUnit.Case, async: true
  alias CodeMySpec.{CodeMode, ToolLibrary, Tools}

  defp docs(tool) do
    catalog =
      CodeMode.Catalog.from([%{ToolLibrary.registration(tool) | name: "schema_example"}], fn _ ->
        fn _ -> {:ok, "ok"} end
      end)

    CodeMode.docs(catalog, name: "schema_example")
  end

  test "question schemas expose required nested questions and options" do
    tool = CodeMySpec.Agents.Tools.AskQuestion
    text = docs(tool)
    assert text =~ "questions[].question (string, required)"
    assert text =~ "questions[].options[].label (string, required)"
    assert text =~ "questions[].multiSelect (boolean)"
    assert text =~ ~s|options = { { label = "…" } }|

    assert {:ok, _} =
             Tools.validate(tool, %{
               questions: [%{question: "Choose", options: [%{label: "A", description: "First"}]}]
             })

    assert {:error, _} =
             Tools.validate(tool, %{
               questions: [%{question: "Choose", options: [%{description: "Missing label"}]}]
             })
  end

  test "QA scenario schemas and docs expose required fields and allowed statuses" do
    for tool <- [CodeMySpec.Qa.Tools.SubmitQaResult, CodeMySpec.Qa.Tools.SubmitIssueQaResult] do
      text = docs(tool)
      assert text =~ "scenarios[].name (string, required)"
      assert text =~ "scenarios[].observation (string, required)"

      assert text =~
               ~s|scenarios[].status (string, required) — allowed: "pass", "partial", "fail", "blocked"|

      assert text =~ "scenarios[].blocker_issue_id"

      base = %{
        task_id: "task",
        status: "pass",
        scenarios: [%{name: "Check", status: "pass", observation: "Worked"}]
      }

      base =
        if tool == CodeMySpec.Qa.Tools.SubmitIssueQaResult,
          do: Map.put(base, :issue_id, "issue"),
          else: base

      assert {:ok, _} = Tools.validate(tool, base)

      assert {:error, _} =
               Tools.validate(tool, %{
                 base
                 | scenarios: [%{name: "Check", status: "invalid", observation: "No"}]
               })

      assert {:error, _} =
               Tools.validate(tool, %{base | scenarios: [%{name: "Check", status: "pass"}]})
    end
  end

  test "batch source docs show fields, enums, and scalar onboarding choices" do
    text = docs(CodeMySpec.Projects.Tools.UpdateProjectOnboarding)
    assert text =~ "sources[].repository_url (string)"
    assert text =~ ~s|sources[].kind (string) — allowed: "github", "local"|
    assert text =~ ~s|destination (string) — allowed: "local", "cloud", "external"|
    refute text =~ "onboarding (object)"
  end
end
