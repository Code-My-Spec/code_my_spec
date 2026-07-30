defmodule CodeMySpec.ContentPublishing.CtasTest do
  @moduledoc """
  The load-bearing test here is `describe "Earmark compatibility"`.

  Earmark identifies an HTML block by matching an opening tag at the start of a
  line against a closing tag at the start of a later line. HEEx renders indented
  multi-line output, and dev builds prepend a debug comment. Either one defeats
  that match, and the failure is not local: Earmark warns "Failed to find closing
  <aside>" and then **stops parsing markdown for the rest of the document**, so
  every heading after the CTA renders as literal text.

  That is silent, it corrupts the published body rather than raising, and once
  CTAs are on every post a regression breaks all of them at once. Hence the
  assertions on content *after* the CTA, not just on the CTA itself.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.ContentPublishing.Ctas

  @earmark %Earmark.Options{compact_output: true, breaks: true, gfm: true}

  defp to_html(markdown), do: Earmark.as_html!(markdown, @earmark)

  defp tag_balance(html, tag) do
    {
      length(Regex.scan(~r/<#{tag}[\s>]/, html)),
      length(Regex.scan(~r/<\/#{tag}>/, html))
    }
  end

  describe "names/0 and validate/1" do
    test "every registered name renders without raising" do
      for name <- Ctas.names() do
        assert is_binary(Ctas.render(name)), "#{name} failed to render"
      end
    end

    test "an unknown shortcode is left in the body rather than silently dropped" do
      assert Ctas.expand("{{no_such_cta}}") == "{{no_such_cta}}"
    end

    test "validate reports unknown names and ignores known ones" do
      assert {:ok, []} = Ctas.validate("{{nontechnical_founder_cta}}")
      assert {:error, ["typo_cta"]} = Ctas.validate("{{typo_cta}} {{owned_code_cta}}")
    end

    test "text with no shortcode is returned untouched" do
      body = "# Title\n\nJust prose, no shortcodes here.\n"
      assert Ctas.expand(body) == body
    end
  end

  describe "attributes" do
    test "bare shortcode uses the registered defaults" do
      html = Ctas.expand("{{nontechnical_founder_cta}}")
      assert html =~ "engineering manager"
      assert html =~ "utm_campaign=nontechnical-founder"
    end

    test "attributes override defaults" do
      html =
        Ctas.expand(
          ~s({{nontechnical_founder_cta headline="Custom head." sub="Custom sub." campaign="my-post"})
          |> Kernel.<>("}")
        )

      assert html =~ "Custom head."
      assert html =~ "Custom sub."
      assert html =~ "utm_campaign=my-post"
      refute html =~ "utm_campaign=nontechnical-founder"
    end

    test "every CTA carries inline UTM tagging so placement stays measurable" do
      for name <- Ctas.names() do
        html = Ctas.render(name)
        assert html =~ "utm_source=blog", "#{name} missing utm_source"
        assert html =~ "utm_medium=inline", "#{name} missing utm_medium"
        assert html =~ "utm_campaign=", "#{name} missing utm_campaign"
      end
    end

    test "an unknown attribute cannot inject an atom or reach the template" do
      html = Ctas.expand(~s({{owned_code_cta bogus_attr="x"}}))
      refute html =~ "bogus_attr"
      refute html =~ "{{"
    end
  end

  describe "Earmark compatibility" do
    test "rendered CTAs are a single line" do
      for name <- Ctas.names() do
        refute Ctas.render(name) =~ "\n",
               "#{name} rendered multi-line; Earmark will fail to close the block"
      end
    end

    test "flattening preserves the word boundary before an inline link" do
      # Regression: collapsing newlines to "" instead of " " ran the body text
      # straight into the link, publishing "was.Point the QA agent at your app".
      html = Ctas.render("verification_gate_cta")

      refute html =~ ~r/[a-z.,][<]a\s/,
             "body text is touching the opening <a> tag with no separating space"

      # Tags become a space, not nothing: <br /> is a real visual break, so
      # stripping it to "" would flag a legitimate boundary as a defect.
      text =
        html
        |> String.replace(~r/<[^>]+>/, " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      refute text =~ ~r/[a-z]\.[A-Z]/, "sentence runs into the link text: #{text}"
    end

    test "no HTML comments survive (dev builds add HEEx debug annotations)" do
      for name <- Ctas.names() do
        refute Ctas.render(name) =~ "<!--", "#{name} leaked a debug comment"
      end
    end

    test "markdown after a CTA still parses" do
      body = """
      Intro paragraph.

      {{nontechnical_founder_cta}}

      ## A Heading After The CTA

      A trailing paragraph.
      """

      html = body |> Ctas.expand() |> to_html()

      assert html =~ "<p>Intro paragraph.</p>"
      assert html =~ "<h2>A Heading After The CTA</h2>"
      assert html =~ "<p>A trailing paragraph.</p>"
    end

    test "every CTA leaves tags balanced after the markdown pass" do
      for name <- Ctas.names() do
        html = "Before.\n\n{{#{name}}}\n\n## After\n\nTail.\n" |> Ctas.expand() |> to_html()

        for tag <- ~w(aside div p a span) do
          {open, close} = tag_balance(html, tag)

          assert open == close,
                 "#{name}: <#{tag}> unbalanced after Earmark (#{open} open, #{close} close)"
        end

        assert html =~ "<h2>After</h2>", "#{name}: markdown parsing stopped at the CTA"
      end
    end

    test "two CTAs in one document both expand and do not corrupt each other" do
      body = "{{owned_code_cta}}\n\n## Middle\n\n{{verification_gate_cta}}\n\n## End\n"
      html = body |> Ctas.expand() |> to_html()

      assert html =~ "<h2>Middle</h2>"
      assert html =~ "<h2>End</h2>"
      {open, close} = tag_balance(html, "aside")
      assert open == 2 and close == 2
    end
  end

  describe "shapes" do
    test "card shape renders a button, aside shape renders a plain link" do
      card = Ctas.render("nontechnical_founder_cta")
      assert card =~ "btn btn-primary"

      aside = Ctas.render("verification_gate_cta")
      refute aside =~ "btn btn-primary"
      assert aside =~ "<a href="
    end

    test "every CTA is wrapped in not-prose" do
      # Without this the post's prose styles override the link colour and a
      # primary button renders teal-on-teal at contrast 1.0.
      for name <- Ctas.names() do
        assert Ctas.render(name) =~ "not-prose", "#{name} is missing not-prose"
      end
    end

    test "outer element is never a div" do
      # A <div> nested inside a <div> makes Earmark drop one closing tag and
      # swallow the rest of the page.
      for name <- Ctas.names() do
        assert Ctas.render(name) =~ ~r/^<aside/, "#{name} must open with <aside>"
      end
    end
  end
end
