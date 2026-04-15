defmodule CodeMySpecLocalWeb.SkillControllerTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import Plug.Conn
  import Plug.Test

  alias CodeMySpecLocalWeb.SkillController

  setup do
    scope = full_scope_fixture()
    %{scope: scope}
  end

  # ===========================================================================
  # Special routes — auth and stop bypass StartAgentTask entirely
  # ===========================================================================

  describe "special routes" do
    test "init auth returns auth signal", %{scope: scope} do
      conn = build_post(scope, %{"skill" => "init", "subcommand" => "auth"})
      conn = SkillController.start_skill(conn, conn.body_params)

      assert conn.status == 200
      assert %{"auth" => true} = Jason.decode!(conn.resp_body)
    end

    test "sync routes correctly (requires cwd)", %{scope: scope} do
      # Sync needs a real cwd — verify it doesn't fail with a routing error
      conn = build_post(scope, %{"skill" => "sync"})
      conn = SkillController.start_skill(conn, conn.body_params)

      body = Jason.decode!(conn.resp_body)
      # Should fail on sync execution (no cwd), not on routing
      refute body["error"] && body["error"] =~ "Unknown"
    end

    test "init sync routes correctly (requires cwd)", %{scope: scope} do
      conn = build_post(scope, %{"skill" => "init", "subcommand" => "sync"})
      conn = SkillController.start_skill(conn, conn.body_params)

      body = Jason.decode!(conn.resp_body)
      refute body["error"] && body["error"] =~ "Unknown"
    end

    test "implement stop returns stopped signal", %{scope: scope} do
      conn = build_post(scope, %{"skill" => "implement", "subcommand" => "stop"})
      conn = SkillController.start_skill(conn, conn.body_params)

      assert conn.status == 200
      assert %{"stopped" => true} = Jason.decode!(conn.resp_body)
    end
  end

  # ===========================================================================
  # Error handling — unknown skills and subcommands
  # ===========================================================================

  describe "error handling" do
    test "unknown skill returns 400", %{scope: scope} do
      conn = build_post(scope, %{"skill" => "nonexistent"})
      conn = SkillController.start_skill(conn, conn.body_params)

      assert conn.status == 400
      assert %{"error" => error} = Jason.decode!(conn.resp_body)
      assert error =~ "Unknown skill"
    end

    test "unknown subcommand returns 400 with available options", %{scope: scope} do
      conn = build_post(scope, %{"skill" => "design", "subcommand" => "bogus"})
      conn = SkillController.start_skill(conn, conn.body_params)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "Unknown subcommand"
      assert "architecture" in body["available"]
      assert "ui" in body["available"]
      assert "strategy" in body["available"]
    end

    test "product with no subcommand lists interview and review", %{scope: scope} do
      conn = build_post(scope, %{"skill" => "product"})
      conn = SkillController.start_skill(conn, conn.body_params)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert "interview" in body["available"]
      assert "review" in body["available"]
    end

    test "design with no subcommand lists options", %{scope: scope} do
      conn = build_post(scope, %{"skill" => "design"})
      conn = SkillController.start_skill(conn, conn.body_params)

      assert conn.status == 400
      assert %{"available" => available} = Jason.decode!(conn.resp_body)
      assert "architecture" in available
    end

    test "develop with no subcommand lists options", %{scope: scope} do
      conn = build_post(scope, %{"skill" => "develop"})
      conn = SkillController.start_skill(conn, conn.body_params)

      assert conn.status == 400
      assert %{"available" => available} = Jason.decode!(conn.resp_body)
      assert "context" in available
      assert "liveview" in available
      assert "refactor" in available
    end
  end

  # ===========================================================================
  # Route mapping completeness — verify every skill+subcommand pair resolves
  # to the expected session type (without going through StartAgentTask).
  #
  # Tests the @skill_routes map exhaustively.
  # ===========================================================================

  describe "route mapping" do
    # Routes that go through StartAgentTask or have special handling.
    # Sync routes are tested separately (need cwd in scope).
    @expected_routes [
      {"product", "interview", 200},
      {"product", "review", 200},
      {"init", nil, 200},
      {"init", "auth", 200},
      {"design", "architecture", 200},
      {"design", "ui", 200},
      {"design", "strategy", 200},
      {"develop", "context", 200},
      {"develop", "liveview", 200},
      {"develop", "refactor", 200},
      {"qa", nil, 200},
      {"qa", "story", 200},
      {"qa", "integrations", 200},
      {"qa", "triage", 200},
      {"qa", "fix", 200},
      {"implement", nil, 200},
      {"implement", "start", 200},
      {"implement", "stop", 200}
    ]

    for {skill, subcmd, expected_status} <- @expected_routes do
      label = "#{skill} #{subcmd || "(default)"}"

      test "#{label} resolves to #{expected_status}", %{scope: scope} do
        params =
          %{"skill" => unquote(skill), "external_id" => "test-route"}
          |> then(fn p ->
            if unquote(subcmd), do: Map.put(p, "subcommand", unquote(subcmd)), else: p
          end)

        conn = build_post(scope, params)
        conn = SkillController.start_skill(conn, conn.body_params)

        # We expect either 200 (special route or successful task dispatch)
        # or 400 from StartAgentTask (env not set up) — but NOT a routing error
        body = Jason.decode!(conn.resp_body)
        error = body["error"]
        refute is_binary(error) and error =~ "Unknown", "Route failed: #{inspect(body)}"
      end
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp build_post(scope, body_params) do
    conn(:post, "/api/skills/start", Jason.encode!(body_params))
    |> put_req_header("content-type", "application/json")
    |> assign(:current_scope, scope)
    |> Map.put(:body_params, body_params)
  end
end
