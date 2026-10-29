defmodule CmsHarness.Web.InitControllerTest do
  use CmsHarnessTest.ConnCase, async: false

  alias CmsHarness.Web.InitController

  @dir "/work/fresh_checkout"

  defp refuse_mint(_root), do: flunk("minted before sign-in")

  describe "respond/3" do
    test "pending sign-in shows the code to approve and writes nothing" do
      status = %{
        phase: :pending,
        verification_uri: "https://cms.test/oauth/device",
        user_code: "ABCD-1234"
      }

      prompt = InitController.respond({:not_onboarded, @dir}, status, &refuse_mint/1)

      assert prompt =~ "https://cms.test/oauth/device"
      assert prompt =~ "ABCD-1234"
      assert prompt =~ "Nothing has been written to #{@dir}"
    end

    test "once signed in it mints for the directory and names the id" do
      mint = fn @dir -> {:ok, "c5a90488"} end

      prompt = InitController.respond({:not_onboarded, @dir}, %{phase: :authorized}, mint)

      assert prompt =~ "Onboarded #{@dir} as harness c5a90488"
    end

    test "a refused mint passes its reason through" do
      mint = fn @dir -> {:error, "Token exchange refused: invalid_token\n"} end

      prompt = InitController.respond({:not_onboarded, @dir}, %{phase: :authorized}, mint)

      assert prompt =~ "Onboarding #{@dir} failed: Token exchange refused: invalid_token\n"
      assert prompt =~ "/codemyspec:init <project_id>"
    end

    test "a stopped authorization does not mint" do
      prompt = InitController.respond({:not_onboarded, @dir}, %{phase: :stopped}, &refuse_mint/1)

      assert prompt =~ "until it is signed in (authorization stopped)"
    end

    test "outside a project it says where to run it" do
      prompt = InitController.respond(:no_harness, %{phase: :authorized}, &refuse_mint/1)

      assert prompt =~ ".code_my_spec/config.yml"
    end
  end

  test "the route answers a project with no config with a prompt", %{conn: conn} do
    bare = Path.join(System.tmp_dir!(), "init_bare_#{System.unique_integer([:positive])}")
    File.mkdir_p!(bare)
    File.write!(Path.join(bare, "mix.exs"), "defmodule X do end")
    on_exit(fn -> File.rm_rf!(bare) end)

    body =
      conn
      |> Plug.Conn.put_req_header("x-working-dir", bare)
      |> post("/api/skills/init", %{"skill" => "init"})
      |> json_response(200)

    assert is_binary(body["prompt"])
    refute body["prompt"] =~ "already onboarded"
  end
end
