defmodule CodeMySpecSpex.Story1013.Criterion916Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 916 — Minting a fresh id reads the project's own deploy key,
  not a copy of it in the environment.

  Title-only criterion; no scenario was recorded against it. Driven per
  product's decisions on the two questions it raised: a user-agent seam
  (commit 2385ba3b9) was built first and found not to reach the read that
  matters -- `ensure_local_credential/1`'s own local-database lookup is a
  plain Ecto query made by the mint subprocess's own, freshly-started
  connection, not an HTTP request, so no sandbox header can carry test
  metadata into it. Product's second decision: commit the project row for
  real, outside the sandbox, so that subprocess's own connection sees it
  exactly as production would, and delete it afterward.

  A real subprocess also needs `MIX_TEST_PARTITION` pinned explicitly to
  this process's own partition (`Fixtures.live_test_partition!/0`):
  `mix cms.spex` assigns each shard its own database by overriding
  `Application.get_env` at runtime, never the OS-level `MIX_TEST_PARTITION`
  variable, so an uncorrected subprocess resolves to whatever ambient
  partition this whole session started with -- a different database than
  the one the committed row actually lives in.

  `ensure_local_credential/1`'s own `cond` answers this criterion
  structurally: its first clause, "this server's own database", wins
  outright whenever the mint target is local -- the environment's
  `CMS_DEPLOY_KEY` is never even inspected in that branch, set or not.
  Both scenarios below exercise that same branch; the point is that a
  wrong value sitting in the environment changes nothing about the
  outcome.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  spex "Minting a fresh id reads the project's own deploy key, not the environment's",
       criterion: 916 do
    scenario "A different deploy key in the environment does not override the database's own" do
      given_ "a committed project with its own deploy key, reachable by a real local listener",
             context do
        {listener, url} = Fixtures.start_live_listener!()
        # Not System.unique_integer/1: it resets near 1 on every fresh VM
        # boot, and each run of this file is one -- a low-entropy key can
        # collide with deploy_key_hash's unique index against a leftover
        # row from an earlier run.
        db_key = "dk_db_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
        project = Fixtures.committed_project_with_deploy_key!(db_key)
        root = Fixtures.scratch_worktree!()
        :ok = Fixtures.warm_scratch_worktree!(root)

        {:ok,
         context
         |> Map.put(:listener, listener)
         |> Map.put(:url, url)
         |> Map.put(:project, project)
         |> Map.put(:root, root)}
      end

      when_ "onboarding mints against it, with a different deploy key named in the environment",
            context do
        env =
          Fixtures.scratch_worktree_env(
            MIX_ENV: "test",
            MIX_TEST_PARTITION: Fixtures.live_test_partition!(),
            CMS_SERVER_URL: context.url,
            CMS_TEST_REAL_DEVICE_CLIENT: "1",
            CMS_DEPLOY_KEY:
              "dk_env_copy_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
          )

        {output, status} =
          Fixtures.run_cmd_bounded(
            "mix",
            ["cms.harness.onboard", "--project", context.project.id],
            [cd: context.root, env: env],
            60_000
          )

        {:ok, context |> Map.put(:output, output) |> Map.put(:status, status)}
      end

      then_ "the mint succeeds, authenticated by the database's key rather than the environment's",
            context do
        assert context.status == 0,
               "onboarding did not succeed against the database's own key: #{context.output}"

        assert context.output =~ "Issued a new harness id",
               "the mint did not report success: #{context.output}"

        {:ok, context}
      end
    end

    scenario "With no deploy key in the environment at all, the database's own still authenticates the mint" do
      given_ "a second committed project with its own deploy key, reachable by a real local listener",
             context do
        {listener, url} = Fixtures.start_live_listener!()
        db_key = "dk_db2_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
        project = Fixtures.committed_project_with_deploy_key!(db_key)
        root = Fixtures.scratch_worktree!()
        :ok = Fixtures.warm_scratch_worktree!(root)

        {:ok,
         context
         |> Map.put(:listener, listener)
         |> Map.put(:url, url)
         |> Map.put(:project, project)
         |> Map.put(:root, root)}
      end

      when_ "onboarding mints against it, with the environment naming no deploy key", context do
        env =
          Fixtures.scratch_worktree_env(
            MIX_ENV: "test",
            MIX_TEST_PARTITION: Fixtures.live_test_partition!(),
            CMS_SERVER_URL: context.url,
            CMS_TEST_REAL_DEVICE_CLIENT: "1"
          )

        {output, status} =
          Fixtures.run_cmd_bounded(
            "mix",
            ["cms.harness.onboard", "--project", context.project.id],
            [cd: context.root, env: env],
            60_000
          )

        {:ok, context |> Map.put(:output, output) |> Map.put(:status, status)}
      end

      then_ "the mint succeeds from the database's own key alone", context do
        assert context.status == 0,
               "onboarding did not succeed from the database's own key with none in the " <>
                 "environment: #{context.output}"

        assert context.output =~ "Issued a new harness id",
               "the mint did not report success: #{context.output}"

        {:ok, context}
      end
    end
  end
end
