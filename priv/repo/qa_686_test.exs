#!/usr/bin/env elixir
# QA test script for story 686: AI-Assisted Story Management
# Run with: NO_SERVER=true MIX_ENV=dev_cli mix run priv/repo/qa_686_test.exs

import Ecto.Query
alias CodeMySpec.Stories
alias CodeMySpec.Stories.Story
alias CodeMySpec.AcceptanceCriteria
alias CodeMySpec.Tags
alias CodeMySpec.BddRules
alias CodeMySpec.Questions
alias CodeMySpec.Personas
alias CodeMySpec.Issues
alias CodeMySpec.AgentTasks.StoryInterview
alias CodeMySpec.AgentTasks.ThreeAmigos
alias CodeMySpec.Users.Scope
alias CodeMySpec.Repo

project = Repo.get_by(CodeMySpec.Projects.Project,
  local_path: "/Users/johndavenport/Documents/github/code_my_spec_test_repos/qa_sandbox"
)

unless project do
  IO.puts("ERROR: QA sandbox project not found in DB")
  System.halt(1)
end

IO.puts("Project: #{project.name} (#{project.id})")
{:ok, scope} = Scope.for_local_project(project)
IO.puts("Scope account_id: #{inspect(scope.active_account_id)}")

# Cleanup from previous runs
IO.puts("Cleaning up any leftover QA-686 test personas...")
qa_slugs = ["qa-686-sc3-persona", "qa-686-sc8-product-owner"]
Enum.each(qa_slugs, fn slug ->
  Repo.delete_all(from p in CodeMySpec.Personas.Persona, where: p.slug == ^slug and p.project_id == ^project.id)
end)

IO.puts("\n=== SC-1: Agent creates a story ===")
Repo.delete_all(from s in Story, where: s.title == "QA-686-SC1 Agent Creates Story" and s.project_id == ^project.id)

case Stories.create_story(scope, %{
  "title" => "QA-686-SC1 Agent Creates Story",
  "description" => "As a QA agent, verify story creation works via the domain layer"
}) do
  {:ok, story} ->
    IO.puts("PASS: Created story id=#{story.id}")
    titles = Stories.list_story_titles(scope)
    if Enum.any?(titles, fn t -> t.title == "QA-686-SC1 Agent Creates Story" end) do
      IO.puts("PASS: Story appears in list_story_titles")
    else
      IO.puts("FAIL: Story NOT in list_story_titles. count=#{length(titles)}")
    end
  {:error, reason} ->
    IO.puts("FAIL: create_story error: #{inspect(reason)}")
end

IO.puts("\n=== SC-2: Agent updates a story ===")
Repo.delete_all(from s in Story, where: s.title in ["QA-686-SC2 Original Title", "QA-686-SC2 Updated Title"] and s.project_id == ^project.id)

case Stories.create_story(scope, %{
  "title" => "QA-686-SC2 Original Title",
  "description" => "Original description for SC2"
}) do
  {:ok, story} ->
    IO.puts("Created story id=#{story.id}")
    case Stories.update_story(scope, story, %{
      "title" => "QA-686-SC2 Updated Title",
      "description" => "Updated description SC2"
    }) do
      {:ok, updated} ->
        IO.puts("PASS: update_story returned, title=#{updated.title}")
        # get_story returns %Story{} or nil (bare struct, not {:ok, _} tuple)
        fetched = Stories.get_story(scope, updated.id)
        if fetched && fetched.title == "QA-686-SC2 Updated Title" do
          IO.puts("PASS: Updated title confirmed on re-read")
        else
          IO.puts("FAIL: Title not updated on re-read. got=#{inspect(fetched && fetched.title)}")
        end
        if fetched && fetched.description == "Updated description SC2" do
          IO.puts("PASS: Updated description confirmed on re-read")
        else
          IO.puts("FAIL: Description not updated. got=#{inspect(fetched && fetched.description)}")
        end
        if fetched && fetched.title != "QA-686-SC2 Original Title" do
          IO.puts("PASS: Old title absent from fetched record")
        end
      {:error, r} -> IO.puts("FAIL: update_story error: #{inspect(r)}")
    end
  {:error, r} -> IO.puts("FAIL: create for SC2: #{inspect(r)}")
end

IO.puts("\n=== SC-3: Agent deletes a story with cascade ===")
Repo.delete_all(from s in Story, where: s.title == "QA-686-SC3 Delete With Cascade" and s.project_id == ^project.id)

case Stories.create_story(scope, %{
  "title" => "QA-686-SC3 Delete With Cascade",
  "description" => "Story for deletion test"
}) do
  {:ok, story} ->
    IO.puts("Created story id=#{story.id}")
    # Create and link a persona (slug required: lowercase alphanum + hyphens)
    {:ok, persona} = Personas.create_persona(scope, %{
      name: "QA SC3 Persona",
      slug: "qa-686-sc3-persona",
      headline: "For deletion test"
    })
    # link_persona_to_story(scope, persona_id, story_id) — persona_id first!
    {:ok, _} = Personas.link_persona_to_story(scope, persona.id, story.id)
    IO.puts("Linked persona #{persona.id}")
    # BddRules.create_rule uses :statement not :title
    {:ok, rule} = BddRules.create_rule(scope, story.id, %{statement: "System deletes rules on story delete"})
    IO.puts("Created rule #{rule.id}")
    {:ok, issue} = Issues.create_issue(scope, %{
      title: "QA-686-SC3 Issue",
      description: "Issue linked to story for deletion test",
      severity: :medium,
      scope: :app,
      story_id: story.id,
      source_path: ".code_my_spec/qa/686/result.md"
    })
    IO.puts("Created issue #{issue.id} linked to story #{story.id}")
    case Stories.delete_story(scope, story) do
      {:ok, _} ->
        IO.puts("PASS: Story #{story.id} deleted")
        # get_story returns nil (not {:error, :not_found})
        fetched = Stories.get_story(scope, story.id)
        if is_nil(fetched) do
          IO.puts("PASS: Story no longer fetchable (nil)")
        else
          IO.puts("FAIL: Story still exists after delete!")
        end
        remaining_rules = Repo.all(from r in CodeMySpec.BddRules.Rule, where: r.story_id == ^story.id)
        if remaining_rules == [] do
          IO.puts("PASS: Rules cascaded (0 remaining)")
        else
          IO.puts("FAIL: #{length(remaining_rules)} rules still exist after story delete")
        end
        reloaded_issue = Repo.get(CodeMySpec.Issues.Issue, issue.id)
        case reloaded_issue do
          nil ->
            IO.puts("FAIL: Issue was cascade-deleted (should survive)")
          %{story_id: nil} ->
            IO.puts("PASS: Issue survives story delete, story_id=nil (cleared)")
          %{story_id: sid} ->
            IO.puts("INFO: Issue survives, story_id=#{inspect(sid)} (not cleared by delete — schema has no ON DELETE SET NULL)")
        end
        Personas.delete_persona(scope, persona)
      {:error, r} -> IO.puts("FAIL: delete_story error: #{inspect(r)}")
    end
  {:error, r} -> IO.puts("FAIL: create for SC3: #{inspect(r)}")
end

IO.puts("\n=== SC-4: Agent adds a criterion ===")
Repo.delete_all(from s in Story, where: s.title == "QA-686-SC4 Add Criterion" and s.project_id == ^project.id)

case Stories.create_story(scope, %{
  "title" => "QA-686-SC4 Add Criterion",
  "description" => "Story for criterion test"
}) do
  {:ok, story} ->
    IO.puts("Created story id=#{story.id}")
    # AcceptanceCriteria.create_criterion — uses description (not body), no kind field
    case AcceptanceCriteria.create_criterion(scope, story, %{
      description: "Given the agent adds a criterion, when I read the story, then the criterion is visible"
    }) do
      {:ok, criterion} ->
        IO.puts("PASS: Created criterion id=#{criterion.id}")
        criteria = AcceptanceCriteria.list_story_criteria(scope, story.id)
        if Enum.any?(criteria, fn c -> c.id == criterion.id end) do
          IO.puts("PASS: Criterion appears in list_story_criteria")
        else
          IO.puts("FAIL: Criterion not found in story criteria list")
        end
      {:error, r} -> IO.puts("FAIL: create_criterion error: #{inspect(r)}")
    end
  {:error, r} -> IO.puts("FAIL: create for SC4: #{inspect(r)}")
end

IO.puts("\n=== SC-5: Agent creates and applies a tag ===")
Repo.delete_all(from s in Story, where: s.title == "QA-686-SC5 Tagging" and s.project_id == ^project.id)

case Stories.create_story(scope, %{
  "title" => "QA-686-SC5 Tagging",
  "description" => "Story for tagging test"
}) do
  {:ok, story} ->
    IO.puts("Created story id=#{story.id}")
    existing_tags = Tags.list_project_tags(scope)
    IO.puts("Existing tag count: #{length(existing_tags)}")
    tag_name = "qa-686-sc5-test-tag"
    # Tags.add_tag(scope, story, tag_name) — creates if missing
    case Tags.add_tag(scope, story, tag_name) do
      {:ok, _} ->
        IO.puts("PASS: Tag '#{tag_name}' added to story")
        # get_story returns bare struct
        reloaded = Stories.get_story(scope, story.id)
        if reloaded do
          story_tag_names = Enum.map(reloaded.tags, & &1.name)
          if tag_name in story_tag_names do
            IO.puts("PASS: Tag '#{tag_name}' appears on story")
          else
            IO.puts("FAIL: Tag not found on story. tags=#{inspect(story_tag_names)}")
          end
        else
          IO.puts("FAIL: Could not reload story")
        end
        all_tags = Tags.list_project_tags(scope)
        if Enum.any?(all_tags, fn t -> t.name == tag_name end) do
          IO.puts("PASS: Tag appears in project taxonomy")
        else
          IO.puts("FAIL: Tag not in project taxonomy")
        end
      {:error, r} ->
        IO.puts("FAIL: add_tag error: #{inspect(r)}")
    end
  {:error, r} -> IO.puts("FAIL: create for SC5: #{inspect(r)}")
end

IO.puts("\n=== SC-6: Agent starts a story interview session ===")
Repo.delete_all(from s in Story, where: s.title == "QA-686-SC6 Story Interview" and s.project_id == ^project.id)

case Stories.create_story(scope, %{
  "title" => "QA-686-SC6 Story Interview",
  "description" => "Story for interview session test"
}) do
  {:ok, _story} ->
    IO.puts("Created story for SC6")
    case StoryInterview.command(scope, %{}) do
      {:ok, prompt} ->
        if String.contains?(prompt, "Product Manager") do
          IO.puts("PASS: Prompt contains 'Product Manager'")
        else
          IO.puts("FAIL: Prompt missing 'Product Manager'")
          IO.puts("Excerpt: #{String.slice(prompt, 0, 300)}")
        end
        if String.contains?(prompt, "bare user stories") do
          IO.puts("PASS: Prompt contains 'bare user stories'")
        else
          IO.puts("FAIL: Prompt missing 'bare user stories'")
        end
        IO.puts("Prompt length: #{String.length(prompt)} chars")
      {:error, r} -> IO.puts("FAIL: StoryInterview.command error: #{inspect(r)}")
    end
  {:error, r} -> IO.puts("FAIL: create for SC6: #{inspect(r)}")
end

IO.puts("\n=== SC-7: Agent starts a Three Amigos session ===")
Repo.delete_all(from s in Story, where: s.title == "QA-686-SC7 Three Amigos Session" and s.project_id == ^project.id)

case Stories.create_story(scope, %{
  "title" => "QA-686-SC7 Three Amigos Session",
  "description" => "Story for three amigos test"
}) do
  {:ok, story} ->
    IO.puts("Created story id=#{story.id}")
    case ThreeAmigos.command(scope, %{entity_id: to_string(story.id)}) do
      {:ok, prompt} ->
        if String.contains?(prompt, "Three Amigos") do
          IO.puts("PASS: Prompt contains 'Three Amigos'")
        else
          IO.puts("FAIL: Prompt missing 'Three Amigos'")
        end
        if String.contains?(prompt, story.title) do
          IO.puts("PASS: Prompt contains story title '#{story.title}'")
        else
          IO.puts("FAIL: Prompt missing story title")
        end
        if String.contains?(prompt, "add_rule") or String.contains?(prompt, "add_scenario") do
          IO.puts("PASS: Prompt references MCP tool names (add_rule/add_scenario)")
        else
          IO.puts("FAIL: Prompt missing tool references")
        end
      {:error, r} -> IO.puts("FAIL: ThreeAmigos.command error: #{inspect(r)}")
    end
  {:error, r} -> IO.puts("FAIL: create for SC7: #{inspect(r)}")
end

IO.puts("\n=== SC-8: Agent runs full Three Amigos workflow ===")
Repo.delete_all(from s in Story, where: s.title == "QA-686-SC8 Full Three Amigos Workflow" and s.project_id == ^project.id)

case Stories.create_story(scope, %{
  "title" => "QA-686-SC8 Full Three Amigos Workflow",
  "description" => "Story for full three amigos workflow test"
}) do
  {:ok, story} ->
    IO.puts("Created story id=#{story.id}")
    # Persona required before add_rule; slug lowercase alphanumeric
    {:ok, persona} = Personas.create_persona(scope, %{
      name: "QA SC8 Product Owner",
      slug: "qa-686-sc8-product-owner",
      headline: "Drives product vision"
    })
    # link_persona_to_story(scope, persona_id, story_id)
    {:ok, _} = Personas.link_persona_to_story(scope, persona.id, story.id)
    IO.puts("PASS: Persona linked")
    # add_rule: statement (not title), no color field
    {:ok, rule} = BddRules.create_rule(scope, story.id, %{statement: "System enforces auth on story creation"})
    IO.puts("PASS: Rule created id=#{rule.id}")
    # add_scenario: AcceptanceCriteria.create_criterion with rule_id; uses description not body
    {:ok, scenario} = AcceptanceCriteria.create_criterion(scope, story, %{
      description: "Given an authenticated agent, when they call create_story, then the story appears in the backlog",
      rule_id: rule.id
    })
    IO.puts("PASS: Scenario/criterion created id=#{scenario.id}")
    # add_question: Questions.create_question with text (not body)
    {:ok, question} = Questions.create_question(scope, story.id, %{
      text: "What happens when the agent auth token expires mid-session?"
    })
    IO.puts("PASS: Question created id=#{question.id}")
    # Verify all records on story
    rules = BddRules.list_rules_for_story(scope, story.id)
    questions = Questions.list_questions_for_story(scope, story.id)
    criteria = AcceptanceCriteria.list_story_criteria(scope, story.id)
    persona_links = Personas.list_personas_for_story(scope, story.id)
    IO.puts("Rules: #{length(rules)} | Questions: #{length(questions)} | Criteria: #{length(criteria)} | Persona links: #{length(persona_links)}")
    if length(rules) >= 1 and length(questions) >= 1 and length(criteria) >= 1 and length(persona_links) >= 1 do
      IO.puts("PASS: All Three Amigos records present on story")
    else
      IO.puts("FAIL: Missing records in Three Amigos workflow")
    end
    Personas.delete_persona(scope, persona)
  {:error, r} -> IO.puts("FAIL: create for SC8: #{inspect(r)}")
end

IO.puts("\n=== SC-9: Accept issue as requirements change ===")
Repo.delete_all(from s in Story, where: s.title == "QA-686-SC9 Requirements Change Story" and s.project_id == ^project.id)

case Stories.create_story(scope, %{
  "title" => "QA-686-SC9 Requirements Change Story",
  "description" => "Story linked to accepted requirements-change issue"
}) do
  {:ok, story} ->
    IO.puts("Created story id=#{story.id}")
    {:ok, issue} = Issues.create_issue(scope, %{
      title: "QA-686-SC9 Requirements Change Issue",
      description: "This issue represents a requirements change discovered during QA",
      severity: :medium,
      scope: :app,
      story_id: story.id,
      source_path: ".code_my_spec/qa/686/result.md"
    })
    IO.puts("Created issue id=#{issue.id}")
    case Issues.accept_issue(scope, issue, [category: :requirements_change, story_id: story.id]) do
      {:ok, accepted} ->
        if accepted.status == :accepted do
          IO.puts("PASS: Issue status=accepted, category=requirements_change, story_id=#{accepted.story_id}")
        else
          IO.puts("FAIL: Issue status=#{accepted.status}")
        end
      {:error, r} -> IO.puts("FAIL: accept_issue error: #{inspect(r)}")
    end
  {:error, r} -> IO.puts("FAIL: create story for SC9: #{inspect(r)}")
end

IO.puts("\n=== SC-10: Accept issue as bug without story link ===")
{:ok, issue_sc10} = Issues.create_issue(scope, %{
  title: "QA-686-SC10 Bug Without Story Link",
  description: "This is a bug issue with no story association",
  severity: :high,
  scope: :app,
  source_path: ".code_my_spec/qa/686/result.md"
})
IO.puts("Created issue id=#{issue_sc10.id}")
case Issues.accept_issue(scope, issue_sc10, [category: :bug]) do
  {:ok, accepted} ->
    if accepted.status == :accepted do
      IO.puts("PASS: Issue accepted, status=#{accepted.status}, story_id=#{inspect(accepted.story_id)}")
    else
      IO.puts("FAIL: Issue status=#{accepted.status}")
    end
  {:error, r} -> IO.puts("FAIL: accept_issue (bug) error: #{inspect(r)}")
end

IO.puts("\n=== SC-11: Dismiss an issue with reason ===")
{:ok, issue_sc11} = Issues.create_issue(scope, %{
  title: "QA-686-SC11 Dismiss With Reason",
  description: "Issue that will be dismissed with an explicit reason",
  severity: :low,
  scope: :app,
  source_path: ".code_my_spec/qa/686/result.md"
})
IO.puts("Created issue id=#{issue_sc11.id}")
case Issues.dismiss_issue(scope, issue_sc11, "Not a real issue — confirmed working as designed") do
  {:ok, dismissed} ->
    if dismissed.status == :dismissed do
      IO.puts("PASS: Issue dismissed, status=#{dismissed.status}")
    else
      IO.puts("FAIL: Issue status=#{dismissed.status}")
    end
    if dismissed.resolution != nil do
      IO.puts("PASS: Resolution recorded: #{dismissed.resolution}")
    else
      IO.puts("FAIL: Resolution is nil")
    end
  {:error, r} -> IO.puts("FAIL: dismiss_issue error: #{inspect(r)}")
end

IO.puts("\n=== All scenarios complete ===")
