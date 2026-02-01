defmodule CodeMySpec.Documents.Parsers.ContextParserTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Documents.Parsers.ContextParser

  defp parse_markdown(markdown) do
    {:ok, ast, _} = Earmark.Parser.as_ast(markdown)
    # Strip the H2 header to get just the context content
    ast
    |> Enum.drop_while(fn
      {"h2", _, _, _} -> true
      _ -> false
    end)
    |> ContextParser.from_ast()
  end

  describe "from_ast/1" do
    test "parses context with list-style fields" do
      markdown = """
      ## Contexts

      ### MetricFlow.Dashboards

      - **Type:** context
      - **Description:** Dashboard management
      - **Stories:** 1, 2

      #### Children

      - MetricFlow.Dashboards.Dashboard (schema) [Stories: 1]: Dashboard entity
      """

      [context] = parse_markdown(markdown)

      assert context.name == "MetricFlow.Dashboards"
      assert context.description == "Dashboard management"
      assert context.story_ids == [1, 2]
      assert length(context.children) == 1

      [child] = context.children
      assert child.name == "MetricFlow.Dashboards.Dashboard"
      assert child.type == "schema"
      assert child.description == "Dashboard entity"
      assert child.story_ids == [1]
    end

    test "parses context with paragraph-style description" do
      markdown = """
      ## Contexts

      ### MetricFlow.Agencies
      Agency-specific features: team management, white-labeling.

      **Type:** context

      **Stories:** 427, 453

      **Children:**
      - MetricFlow.Agencies.AutoEnrollmentRule (schema) - Domain-based auto-enrollment
      """

      [context] = parse_markdown(markdown)

      assert context.name == "MetricFlow.Agencies"
      assert context.description == "Agency-specific features: team management, white-labeling."
      assert context.story_ids == [427, 453]
    end

    test "parses children with dash separator for description" do
      markdown = """
      ## Contexts

      ### MetricFlow.DataSync
      Sync context.

      **Type:** context

      **Children:**
      - MetricFlow.DataSync.SyncJob (schema) - Scheduled job record
      - MetricFlow.DataSync.SyncWorker (module) - Oban worker for sync

      **Stories:** 1
      """

      [context] = parse_markdown(markdown)

      assert length(context.children) == 2

      job = Enum.find(context.children, &(&1.name == "MetricFlow.DataSync.SyncJob"))
      assert job.type == "schema"
      assert job.description == "Scheduled job record"

      worker = Enum.find(context.children, &(&1.name == "MetricFlow.DataSync.SyncWorker"))
      assert worker.type == "module"
      assert worker.description == "Oban worker for sync"
    end

    test "parses children with colon separator for description" do
      markdown = """
      ## Contexts

      ### MetricFlow.Accounts
      User accounts.

      **Type:** context

      **Children:**
      - MetricFlow.Accounts.User (schema): User account entity

      **Stories:** 1
      """

      [context] = parse_markdown(markdown)

      [child] = context.children
      assert child.name == "MetricFlow.Accounts.User"
      assert child.description == "User account entity"
    end

    test "handles children without descriptions" do
      markdown = """
      ## Contexts

      ### MetricFlow.Core
      Core context.

      **Type:** context

      **Children:**
      - MetricFlow.Core.Config (schema)

      **Stories:** 1
      """

      [context] = parse_markdown(markdown)

      [child] = context.children
      assert child.name == "MetricFlow.Core.Config"
      assert child.type == "schema"
      assert child.description == nil
    end

    test "parses multiple contexts" do
      markdown = """
      ## Contexts

      ### MetricFlow.Accounts
      Account management.

      **Type:** context

      **Children:**
      - MetricFlow.Accounts.User (schema) - User entity

      **Stories:** 1

      ---

      ### MetricFlow.Billing
      Billing management.

      **Type:** context

      **Children:**
      - MetricFlow.Billing.Invoice (schema) - Invoice entity

      **Stories:** 2
      """

      contexts = parse_markdown(markdown)

      assert length(contexts) == 2
      assert Enum.any?(contexts, &(&1.name == "MetricFlow.Accounts"))
      assert Enum.any?(contexts, &(&1.name == "MetricFlow.Billing"))
    end

    test "prefers explicit **Description:** over paragraph" do
      markdown = """
      ## Contexts

      ### MetricFlow.Test
      This paragraph should be ignored.

      - **Description:** This is the real description
      - **Type:** context

      **Children:**
      - MetricFlow.Test.Item (schema) - Item

      **Stories:** 1
      """

      [context] = parse_markdown(markdown)

      # Should use the explicit **Description:** field
      assert context.description == "This is the real description"
    end
  end
end
