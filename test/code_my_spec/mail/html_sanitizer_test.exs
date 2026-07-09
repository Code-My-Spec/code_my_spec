defmodule CodeMySpec.Mail.HtmlSanitizerTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Mail.HtmlSanitizer

  describe "sanitize/1" do
    test "drops script tags and their contents" do
      out = HtmlSanitizer.sanitize("<p>hi</p><script>alert(1)</script>")
      assert out =~ "hi"
      refute out =~ "alert"
      refute out =~ "script"
    end

    test "drops style, iframe, object and form chrome" do
      out =
        HtmlSanitizer.sanitize("""
        <style>body{display:none}</style>
        <iframe src="http://evil"></iframe>
        <form><input name="x"></form>
        <p>body</p>
        """)

      assert out =~ "body"
      refute out =~ "iframe"
      refute out =~ "<form"
      refute out =~ "<input"
      refute out =~ "display:none"
    end

    test "strips inline event handlers" do
      out = HtmlSanitizer.sanitize(~s|<a href="http://ok" onclick="steal()">link</a>|)
      assert out =~ "http://ok"
      refute out =~ "onclick"
      refute out =~ "steal"
    end

    test "neutralizes javascript: and vbscript: urls" do
      js = "java" <> "script:alert(1)"
      out = HtmlSanitizer.sanitize(~s|<a href="| <> js <> ~s|">x</a>|)
      refute out =~ "script:alert"
      assert out =~ ~s(href="#")
    end

    test "keeps ordinary formatting, links and images" do
      out =
        HtmlSanitizer.sanitize(
          ~s|<p><b>bold</b> <a href="https://x.test">l</a> <img src="https://x.test/a.png"></p>|
        )

      assert out =~ "<b>bold</b>"
      assert out =~ ~s(href="https://x.test")
      assert out =~ ~s(src="https://x.test/a.png")
    end

    test "returns empty string for non-binary input" do
      assert HtmlSanitizer.sanitize(nil) == ""
    end

    test "rewrites remote img srcs through :rewrite_img, leaving data/cid alone" do
      html =
        ~s|<img src="https://cdn.test/a.png"><img src="data:image/png;base64,AAA"><img src="cid:logo">|

      out = HtmlSanitizer.sanitize(html, rewrite_img: fn url -> "/proxy?u=" <> url end)

      assert out =~ ~s(src="/proxy?u=https://cdn.test/a.png")
      assert out =~ ~s(src="data:image/png;base64,AAA")
      assert out =~ ~s(src="cid:logo")
    end
  end

  describe "to_text/1" do
    test "extracts visible text, dropping tags" do
      assert HtmlSanitizer.to_text("<div>hello <b>world</b></div>") =~ "hello world"
    end

    test "handles the empty-body markup Gmail sends" do
      assert HtmlSanitizer.to_text(~s|<div dir="ltr"><br></div>\n|) |> String.trim() == ""
    end
  end
end
