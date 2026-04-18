defmodule QuadmanWeb.PageControllerTest do
  use QuadmanWeb.ConnCase

  test "GET / redirects to login when unauthenticated", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/login"
  end
end
