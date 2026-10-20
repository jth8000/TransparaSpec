defmodule TSpecWeb.ChannelCase do
  @moduledoc "Test case for channel tests (sandboxed DB, `Phoenix.ChannelTest`)."
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import TSpecWeb.ChannelCase

      @endpoint TSpecWeb.Endpoint
    end
  end

  setup tags do
    TSpec.DataCase.setup_sandbox(tags)
    :ok
  end
end
