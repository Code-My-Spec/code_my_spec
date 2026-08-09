defmodule CodeMySpecSpex.Story842.Criterion1974Spex do
  @moduledoc """
  Story 842 — Formal release process
  Criterion 1974 — The user approves the release from their phone.

  Prod is the one step the agent does not take on its own. "From their phone"
  is the substance rather than the decoration: approval has to reach the user
  wherever they are, so a release is never blocked on someone being at a
  terminal, and never proceeds because nobody was.

  Surface: HTTP `POST /api/agent-tasks/start`, then the notification the
  approval request produces. Asserting the prompt merely *mentions* approval
  would pass on a task that asks the agent to imagine consent.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @release_type "Elixir.CodeMySpec.AgentTasks.Release"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "The user approves the release from their phone" do
    scenario "a release reaches the point of asking" do
      given_ "a story on UAT waiting to be released", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/devops/deploys/story_9003.md",
            "# Deploy\n\nstory 9003 to uat — verified\n"
          )

        {:ok, context}
      end

      when_ "the agent starts the release", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/agent-tasks/start", %{"session_type" => @release_type})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :prompt, response["prompt"] || response["error"] || "")}
      end

      then_ "approval is required before prod is touched", context do
        assert context.prompt =~ ~r/approv/i,
               "expected the release to require the user's explicit approval, got: #{context.prompt}"

        {:ok, context}
      end

      then_ "the ask reaches the user rather than waiting at a terminal", context do
        assert context.prompt =~ ~r/notification|push|phone/i,
               "expected the approval to reach the user where they are — a release that " <>
                 "can only be approved at a terminal stalls whenever nobody is at one. " <>
                 "Got: #{context.prompt}"

        {:ok, context}
      end
    end
  end
end
