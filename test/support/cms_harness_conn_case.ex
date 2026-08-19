defmodule CmsHarnessTest.ConnCase do
  @moduledoc """
  For tests that drive the hook surface the way Claude Code does: an HTTP POST
  addressed to a harness id, with a JSON body.

  The id is the whole address. Nothing here sends a working directory, because
  nothing in the harness reads one — a hook says which working copy it is about
  or it is refused.
  """

  use ExUnit.CaseTemplate

  # This case cannot be used asynchronously, and says so rather than letting a
  # caller find out from a neighbour.
  #
  # `setup` below clears `CMS_TOKEN` and friends and restores them on exit. OS
  # environment variables belong to the BEAM node, not to a test process, so
  # that window is open to every other test running at the same time — and at
  # least one asserts on their *absence*: `working_copies_test` expects
  # `{:unreachable, _}` because this environment has no credential. Under the
  # analyzer, which runs with `CMS_TOKEN` exported, that test passed alone and
  # failed in the suite.
  #
  # Guarding here rather than in each file because the mutation is here. Three
  # files were moved to async on the reasoning "no app env, no filesystem, no
  # spawn, no named process" — a list that did not name OS env, and could not
  # have caught this by reading the test files, since nothing in them mentions
  # it.
  using opts do
    if Keyword.get(opts, :async, false) do
      raise ArgumentError, """
      CmsHarnessTest.ConnCase cannot be async.

      Its setup deletes and restores CMS_TOKEN, CMS_DEPLOY_KEY, CMS_SERVER_URL,
      CMS_PROJECT_ID, CMS_PROJECT_DIR and CMS_HARNESS_ID. Those are node-global,
      so the window is visible to every concurrently running test — including
      ones that assert on a credential being absent.

      Use `async: false`.
      """
    end

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

      defp post_skill(conn, working_dir, payload \\ %{}) do
        post_skill_as(conn, harness_id_at(working_dir), payload)
      end

      defp post_skill_as(conn, harness_id, payload \\ %{}) do
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/harnesses/#{harness_id}/skills/start", payload)
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
  #
  # `CMS_HARNESS_ID` joined the list when `HarnessConfig.read/1` started
  # honouring it — the environment is checked *before* the file, so one exported
  # value makes every working copy in the suite resolve to the same harness. The
  # plugin's hook config interpolates `${CMS_HARNESS_ID}`, so agent shells do
  # carry it.
  @environment_vars ~w(
    CMS_TOKEN CMS_DEPLOY_KEY CMS_SERVER_URL CMS_PROJECT_ID CMS_PROJECT_DIR CMS_HARNESS_ID
  )

  setup _tags do
    saved = Enum.map(@environment_vars, &{&1, System.get_env(&1)})
    Enum.each(@environment_vars, &System.delete_env/1)

    on_exit(fn -> Enum.each(saved, &restore/1) end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp restore({name, nil}), do: System.delete_env(name)
  defp restore({name, value}), do: System.put_env(name, value)
end
