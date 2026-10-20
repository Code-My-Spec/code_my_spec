defmodule CodeMySpecWeb.WorkingCopyLive.Components.CopyProblemsMarkerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodeMySpecWeb.WorkingCopyLive.Components.Copy

  defp marker(tally, size \\ :small),
    do: render_component(&Copy.problems_marker/1, tally: tally, href: "/p", size: size)

  test "an error anywhere makes it red, with the split worst-first in the tooltip" do
    html = marker([{"credo", :info, 205}, {"exunit", :error, 5}, {"credo", :error, 4}])

    assert html =~ ~s(data-worst="error")
    assert html =~ ~s(data-total="214")
    assert html =~ ">214<" or html =~ "214\n"
    assert html =~ "214 problems — exunit 5 error · credo 4 error · credo 205 info"
  end

  test "only advisory findings read grey, and normal size says what the number is" do
    html = marker([{"credo", :info, 1}], :normal)

    assert html =~ ~s(data-worst="info")
    assert html =~ "1 problem"
  end

  test "nothing at zero" do
    assert marker([]) == ""
  end

  test "counts fit in four characters" do
    assert Enum.map(
             [7, 999, 1_000, 1_234, 9_999, 12_345, 999_999, 1_200_000, 25_000_000],
             &Copy.compact/1
           ) ==
             ["7", "999", "1k", "1.2k", "9.9k", "12k", "999k", "1.2M", "25M"]
  end
end
