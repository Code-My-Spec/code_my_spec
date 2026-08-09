defmodule CmsHarnessTest.ConnCase do
  @moduledoc """
  For tests that drive the hook surface the way Claude Code does: an HTTP POST
  addressed to a harness id, with a JSON body.

  The id is the whole address. Nothing here sends a working directory, because
  nothing in the harness reads one — a hook says which working copy it is about
  or it is refused.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Phoenix.ConnTest

      import CmsHarnessTest.Projects

      @endpoint CmsHarness.Web.Endpoint

      # Defined here rather than imported: `post/3` is a macro that needs
      # `@endpoint` in the calling module's scope.
      #
      # Takes the root for the call sites' convenience and reads the id out of
      # it, the way onboarding does when it generates a plugin.
      defp post_hook(conn, hook, working_dir, payload \\ %{}) do
        post_hook_as(conn, hook, harness_id_at(working_dir), payload)
      end

      defp post_hook_as(conn, hook, harness_id, payload \\ %{}) do
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/harnesses/#{harness_id}/hooks/#{hook}", payload)
      end

      defp harness_id_at(root) do
        case CmsHarness.HarnessConfig.read(root) do
          {:ok, %{harness_id: id}} -> id
          _ -> "no-harness-id-at-#{root}"
        end
      end
    end
  end

  # `CmsHarness.Config` and `ProjectIdentity` read these straight from the OS
  # environment, so a test's premise depends on the environment of whatever
  # started the suite — and under the harness, that process has all of them.
  # `just harness` exports `CMS_DEPLOY_KEY`, and the analyzer runs `mix test` as
  # a child, which inherits it.
  #
  # The test asserting "with no credential it names the credential, not the
  # network" therefore passed on every developer's machine and failed only under
  # the harness. It failed as a product bug — the wording of a refusal — which is
  # about the last place anyone would look for an environment leak.
  #
  # Cleared for every test rather than the ones that obviously care, because
  # which ones care is not obvious: this suite is about what the harness does
  # when it cannot reach a server, and a credential it did not know it had
  # changes that answer.
  @environment_vars ~w(CMS_TOKEN CMS_DEPLOY_KEY CMS_SERVER_URL CMS_PROJECT_ID CMS_PROJECT_DIR)

  setup _tags do
    saved = Enum.map(@environment_vars, &{&1, System.get_env(&1)})
    Enum.each(@environment_vars, &System.delete_env/1)

    on_exit(fn -> Enum.each(saved, &restore/1) end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp restore({name, nil}), do: System.delete_env(name)
  defp restore({name, value}), do: System.put_env(name, value)
end
