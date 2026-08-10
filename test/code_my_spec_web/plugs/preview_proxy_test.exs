defmodule CodeMySpecWeb.Plugs.PreviewProxyTest do
  use CodeMySpecTest.ConnCase, async: true

  alias CodeMySpecWeb.Plugs.PreviewProxy

  describe "deciding whether a request is a preview at all" do
    test "an ordinary host is left alone", %{conn: conn} do
      conn = %{conn | host: "codemyspec.com"} |> PreviewProxy.call([])

      refute conn.halted, "the proxy must not touch requests for our own site"
      assert conn.status == nil
    end

    test "a preview-shaped host that is not a project id is left alone", %{conn: conn} do
      # The label has to be a UUID. Anything else in that position belongs to
      # whoever owns that name, not to us — and guessing would let a typo take
      # over a hostname.
      conn = %{conn | host: "preview-marketing.codemyspec.com"} |> PreviewProxy.call([])

      refute conn.halted
    end

    test "a preview host for a project with no workspace says so", %{conn: conn} do
      host = PreviewProxy.host_for(Ecto.UUID.generate(), "codemyspec.com")

      conn = %{conn | host: host} |> PreviewProxy.call([])

      assert conn.halted
      assert conn.status == 404
    end
  end

  describe "the address a preview lives at" do
    test "is the same for a project every time" do
      id = Ecto.UUID.generate()

      assert PreviewProxy.host_for(id, "codemyspec.com") ==
               PreviewProxy.host_for(id, "codemyspec.com")
    end

    test "is one label deep, because that is what a wildcard certificate covers" do
      host = PreviewProxy.host_for(Ecto.UUID.generate(), "codemyspec.com")

      assert length(String.split(host, ".")) == 3,
             "preview-{id}.codemyspec.com is covered by *.codemyspec.com; " <>
               "another level down needs a paid certificate"
    end
  end

  describe "telling a socket from a page" do
    test "an upgrade request for a project with no workspace still 404s", %{conn: conn} do
      # The upgrade branch must resolve the workspace like any other request.
      # Upgrading first and discovering there is nothing upstream leaves the
      # browser holding a socket nobody serves, which LiveView retries forever.
      host = PreviewProxy.host_for(Ecto.UUID.generate(), "codemyspec.com")

      conn =
        %{conn | host: host}
        |> Plug.Conn.put_req_header("connection", "Upgrade")
        |> Plug.Conn.put_req_header("upgrade", "websocket")
        |> PreviewProxy.call([])

      assert conn.halted
      assert conn.status == 404
    end

    test "an ordinary request is not mistaken for an upgrade", %{conn: conn} do
      host = PreviewProxy.host_for(Ecto.UUID.generate(), "codemyspec.com")

      conn =
        %{conn | host: host}
        |> Plug.Conn.put_req_header("connection", "keep-alive")
        |> PreviewProxy.call([])

      assert conn.status == 404
    end
  end

  describe "framing" do
    test "even a refusal says who may frame it", %{conn: conn} do
      # The pane shows this response in an iframe. A 404 that cannot be framed
      # is a blank box where an explanation should be.
      host = PreviewProxy.host_for(Ecto.UUID.generate(), "codemyspec.com")

      conn = %{conn | host: host} |> PreviewProxy.call([])

      assert [policy] = Plug.Conn.get_resp_header(conn, "content-security-policy")
      assert policy =~ "frame-ancestors"
      assert Plug.Conn.get_resp_header(conn, "x-frame-options") == []
    end
  end
end
