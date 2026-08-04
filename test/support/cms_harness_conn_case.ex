defmodule CmsHarnessTest.ConnCase do
  @moduledoc """
  For tests that drive the hook surface the way Claude Code does: an HTTP POST
  with a working directory and a JSON body.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Phoenix.ConnTest

      import CmsHarnessTest.Projects

      @endpoint CmsHarness.Web.Endpoint

      # Defined here rather than imported: `post/3` is a macro that needs
      # `@endpoint` in the calling module's scope.
      defp post_hook(conn, hook, working_dir, payload \\ %{}) do
        conn
        |> Plug.Conn.put_req_header("x-working-dir", working_dir)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/#{hook}", payload)
      end
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
