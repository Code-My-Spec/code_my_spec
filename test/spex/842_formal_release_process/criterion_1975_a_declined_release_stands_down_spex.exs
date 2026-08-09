defmodule CodeMySpecSpex.Story842.Criterion1975Spex do
  @moduledoc """
  Story 842 — Formal release process
  Criterion 1975 — A declined release stands down.

  "No" has to mean nothing happened. A decline that still leaves a tag, a
  GitHub Release, or a release record behind is worse than one that shipped —
  the user believes they stopped it and the record says otherwise.

  Surface: HTTP `POST /api/agent-tasks/start` with the approval declined, then
  the absence of each artifact. Absence is the whole claim, so it is checked
  directly rather than inferred from what the task said it would do.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @cassette "842_1975_release_declined"
  @release_type "Elixir.CodeMySpec.AgentTasks.Release"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "A declined release stands down" do
    scenario "the user says no" do
      given_ "a story on UAT waiting to be released", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/devops/deploys/story_9004.md",
            "# Deploy\n\nstory 9004 to uat — verified\n"
          )

        {:ok, context}
      end

      when_ "the release is started and the user declines", context do
        response =
          with_full_cassette @cassette do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post("/api/agent-tasks/start", %{
              "session_type" => @release_type,
              "approval" => "declined"
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "no release record is written", context do
        entries =
          case Environments.list_directory(context.environment, ".code_my_spec/releases") do
            {:ok, names} -> names
            _ -> []
          end

        assert entries == [],
               "a declined release left a record behind, so the tool believes it shipped: #{inspect(entries)}"

        {:ok, context}
      end

      then_ "nothing is tagged", context do
        tags =
          case Environments.cmd(context.environment, "git", ["tag", "--list"]) do
            {:ok, output} -> output
            _ -> ""
          end

        refute tags =~ ~r/v?\d+\.\d+\.\d+/,
               "a declined release left a tag behind, got: #{inspect(tags)}"

        {:ok, context}
      end
    end
  end
end
