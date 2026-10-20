defmodule TSpecWeb.ConsentController do
  use TSpecWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias TSpec.Accounts
  alias TSpecWeb.Schemas

  tags ["consent"]

  operation :show,
    summary: "The consent document new users must accept",
    responses: [ok: {"Consent document", "application/json", Schemas.ConsentDocument}]

  def show(conn, _params) do
    doc = Accounts.current_consent_document()
    json(conn, %{version: doc.version, kind: doc.kind, published_at: doc.published_at})
  end
end
