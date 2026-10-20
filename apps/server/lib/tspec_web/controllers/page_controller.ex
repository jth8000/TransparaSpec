defmodule TSpecWeb.PageController do
  use TSpecWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
