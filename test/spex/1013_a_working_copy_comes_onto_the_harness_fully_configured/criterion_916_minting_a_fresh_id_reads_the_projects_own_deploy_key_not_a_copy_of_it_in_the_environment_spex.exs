defmodule CodeMySpecSpex.Story1013.Criterion916Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 916 — Minting a fresh id reads the project's own deploy key,
  not a copy of it in the environment.

  Was driven as a real, separate OS process against a scratch git worktree,
  with a real local listener standing in for the server. Main's call
  (2026-10-22, issue 99c05f98): a full `mix` compile in a fresh worktree is
  too heavy for a spex on this shared machine. Driven in-process instead,
  against `Mix.Tasks.Cms.Harness.Onboard.mint/2` directly -- public,
  precisely so it can be exercised this way -- with `Req.Test` standing in
  for the server both requests reach (the mint POST, already wired in
  `config/test.exs`; the token exchange, wired here for the duration of the
  call).

  Driving `mint/2` in-process rather than `run/1` or `onboard/4`: those also
  provision a preview tunnel and configure git, neither of which this
  criterion is about, and neither of which a stub should have to pretend to
  answer for.

  `ensure_local_credential/1`'s own `cond` answers this criterion
  structurally: its first clause, "this server's own database", wins
  outright whenever the mint target is local -- the environment's
  `CMS_DEPLOY_KEY` is never even inspected in that branch, set or not.
  Both scenarios below exercise that same branch; the point is that a
  wrong value sitting in the environment changes nothing about the
  outcome. `:harness_server_url_override` is what makes the target local
  for the duration of each scenario -- `local_server?/1` reads the host,
  and "localhost" is what it checks for.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures
  alias CmsHarness.Token
  alias Mix.Tasks.Cms.Harness.Onboard

  setup do
    original_server_url = Application.get_env(:code_my_spec, :harness_server_url_override)
    original_token_config = Application.get_env(:code_my_spec, Token, [])

    Application.put_env(:code_my_spec, :harness_server_url_override, "http://localhost:9999")

    Application.put_env(
      :code_my_spec,
      Token,
      Keyword.put(original_token_config, :plug, {Req.Test, Token})
    )

    Req.Test.stub(Onboard, fn conn ->
      Req.Test.json(conn, %{"harness_id" => "harness-" <> Ecto.UUID.generate()})
    end)

    Req.Test.stub(Token, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "spex-token-" <> Ecto.UUID.generate(),
        "expires_in" => 3600
      })
    end)

    # `CmsHarness.Token` is a long-lived named GenServer the app supervisor
    # already started, not a process this test owns -- its own request runs
    # on that pid, not this test's, and Req.Test's stub lookup is per-owner.
    # `allow_stub/1` grants that pid this test's stub without starting a
    # second Token server (which `Token.start_link/1` would refuse: already
    # named).
    Fixtures.allow_stub(Token)

    on_exit(fn ->
      Application.put_env(:code_my_spec, :harness_server_url_override, original_server_url)
      Application.put_env(:code_my_spec, Token, original_token_config)
    end)

    :ok
  end

  spex "Minting a fresh id reads the project's own deploy key, not the environment's",
       criterion: 916 do
    scenario "A different deploy key in the environment does not override the database's own" do
      given_ "a committed project with its own deploy key, with a different key named in " <>
               "the environment",
             context do
        db_key = "dk_db_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
        project = Fixtures.committed_project_with_deploy_key!(db_key)
        root = Fixtures.spex_tmp_dir!("onboard")

        env_key = "dk_env_copy_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
        :ok = Fixtures.set_env_var!("CMS_DEPLOY_KEY", env_key)

        {:ok, context |> Map.put(:project, project) |> Map.put(:root, root)}
      end

      when_ "onboarding mints against it", context do
        result = Fixtures.onboard_mint(context.root, context.project.id)

        {:ok, Map.put(context, :result, result)}
      end

      then_ "the mint succeeds, authenticated by the database's key rather than the environment's",
            context do
        assert {:ok, _id} = context.result,
               "onboarding did not succeed against the database's own key: #{inspect(context.result)}"

        {:ok, context}
      end
    end

    scenario "With no deploy key in the environment at all, the database's own still authenticates the mint" do
      given_ "a second committed project with its own deploy key, with no deploy key in the environment",
             context do
        db_key = "dk_db2_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
        project = Fixtures.committed_project_with_deploy_key!(db_key)
        root = Fixtures.spex_tmp_dir!("onboard")

        :ok = Fixtures.ensure_env_var_unset!("CMS_DEPLOY_KEY")

        {:ok, context |> Map.put(:project, project) |> Map.put(:root, root)}
      end

      when_ "onboarding mints against it", context do
        result = Fixtures.onboard_mint(context.root, context.project.id)

        {:ok, Map.put(context, :result, result)}
      end

      then_ "the mint succeeds from the database's own key alone", context do
        assert {:ok, _id} = context.result,
               "onboarding did not succeed from the database's own key with none in the " <>
                 "environment: #{inspect(context.result)}"

        {:ok, context}
      end
    end
  end
end
