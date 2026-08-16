defmodule CmsHarness.McpRefusalMessageTest do
  @moduledoc """
  A 503 from the server is not "the server is unreachable".

  `7d1bde0e`. `Phoenix.Ecto.CheckRepoStatus` refuses **every** request with
  `PendingMigrationError` while the dev database is behind. :4000 serves the MCP
  endpoint, so every agent on the machine loses every tool at the same moment,
  and what they were told was:

      The harness could not reach http://localhost:4000 to find out where
      6bc4851f-… is: {:error, {:refused, 503}}. Nothing is wrong with the id and
      re-onboarding will not help — the server is down or unreachable from here.

  Every clause of that is true and it points nowhere. The reason was visible only
  in `web.log`, behind the 4KB `conn` dump Bandit prints on every error line.

  How it arises is entirely ordinary: an agent commits a migration from a
  worktree, runs it against its own partitioned *test* database because that is
  what its suite needs, and pushes. Nothing runs it on dev. Measured by doing
  exactly that.

  A hint, not a diagnosis — the harness never sees the body, so this says what to
  check first. The distinction that earns it is that a 503 means the server
  *answered*: it is up and refusing, which is a different fact from unreachable
  and has a different first move.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Web.McpController

  @harness "6bc4851f-f735-4590-bb1c-c660619b4019"

  describe "a 503" do
    test "is named as the server being up and refusing, with the usual cause" do
      message = McpController.message({:server_unreachable, @harness, {:error, {:refused, 503}}})

      assert message =~ "503 means the server is up and refusing every request"
      assert message =~ "pending migration"
      assert message =~ "mix ecto.migrate"

      assert message =~ "web.log",
             "the reason is only ever in that file, and finding it is the step " <>
               "nobody manages from the harness's own message"
    end

    test "still says the id is fine, because it is" do
      message = McpController.message({:server_unreachable, @harness, {:error, {:refused, 503}}})

      assert message =~ @harness
      assert message =~ "Nothing is wrong with the id"
    end

    test "reaches the hint through a bare refusal too" do
      assert McpController.message({:refused, 503}) =~ "pending migration"
    end
  end

  describe "everything else keeps its own answer" do
    # The hint must not attach itself to a credential problem: 401 and 403 are
    # what the deploy-key sentence is for, and adding a migration paragraph to
    # them would send the reader somewhere useless.
    test "a credential refusal is not given a migration hint" do
      for status <- [401, 403, 500] do
        message = McpController.message({:refused, status})

        assert message =~ "refused this harness's deploy key with #{status}"
        refute message =~ "pending migration"
      end
    end

    test "a genuine transport failure is not given one either" do
      message = McpController.message({:server_unreachable, @harness, :econnrefused})

      assert message =~ "down or unreachable"
      refute message =~ "pending migration"
    end

    test "the unrelated clauses are untouched" do
      assert McpController.message(:no_harness) =~ "does not say which working copy"
      assert McpController.message(:no_project_id) =~ "does not say which project"
      assert McpController.message({:unknown_harness, @harness}) =~ "not serving the working copy"
    end
  end
end
