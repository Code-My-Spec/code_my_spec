defmodule CodeMySpec.Mail.ImageProxyTest do
  use ExUnit.Case, async: false

  alias CodeMySpec.Mail.ImageProxy

  setup do
    prev = Application.get_env(:code_my_spec, ImageProxy, [])
    Application.put_env(:code_my_spec, ImageProxy, plug: {Req.Test, ImageProxy})
    on_exit(fn -> Application.put_env(:code_my_spec, ImageProxy, prev) end)
    :ok
  end

  describe "signed_path/1 + verify/1" do
    test "round-trips a url through a signed same-origin path" do
      path = ImageProxy.signed_path("https://cdn.example.com/a.png")
      assert path =~ "/app/mail/image?u="

      token = path |> String.split("u=") |> List.last() |> URI.decode_www_form()
      assert {:ok, "https://cdn.example.com/a.png"} = ImageProxy.verify(token)
    end

    test "rejects a tampered/garbage token" do
      assert :error = ImageProxy.verify("not-a-real-token")
    end
  end

  describe "fetch/1 guards" do
    test "rejects non-http schemes" do
      assert {:error, :bad_scheme} = ImageProxy.fetch("ftp://example.com/a.png")
    end

    test "rejects loopback and private IP literals" do
      assert {:error, :private_host} = ImageProxy.fetch("http://127.0.0.1/a.png")
      assert {:error, :private_host} = ImageProxy.fetch("http://10.0.0.5/a.png")
      assert {:error, :private_host} = ImageProxy.fetch("http://169.254.169.254/latest/meta-data")
      assert {:error, :private_host} = ImageProxy.fetch("http://localhost/a.png")
    end

    test "serves an image body from a public host" do
      Req.Test.stub(ImageProxy, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.send_resp(200, "PNGBYTES")
      end)

      assert {:ok, "image/png", "PNGBYTES"} = ImageProxy.fetch("https://cdn.example.com/a.png")
    end

    test "refuses a non-image response (e.g. an HTML error page)" do
      Req.Test.stub(ImageProxy, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, "<html>nope</html>")
      end)

      assert {:error, :not_an_image} = ImageProxy.fetch("https://cdn.example.com/evil")
    end

    test "refuses a non-2xx status" do
      Req.Test.stub(ImageProxy, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
      assert {:error, {:status, 404}} = ImageProxy.fetch("https://cdn.example.com/missing.png")
    end
  end
end
