defmodule TSpec.Feed.SessionClusterTest do
  @moduledoc """
  Feed sessions have one owner across the cluster (ADR 0011): a request on
  another node finds the existing process through `:global` instead of
  starting a second, divergent one. Runs a real second BEAM node via
  `:peer` (needs epmd, which ships with Erlang).
  """
  use TSpec.DataCase, async: false

  import TSpec.AccountsFixtures
  import TSpec.ContentFixtures

  alias TSpec.Accounts
  alias TSpec.Feed.Session

  @moduletag :capture_log

  setup_all do
    unless Node.alive?() do
      System.cmd("epmd", ["-daemon"])

      {:ok, _} =
        Node.start(:"tspec_test_#{System.unique_integer([:positive])}@127.0.0.1", :longnames)
    end

    {:ok, peer, node} =
      :peer.start_link(%{
        name: :"tspec_peer_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
      })

    # The peer runs our compiled code but not the application: it only
    # needs to look sessions up and call them.
    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    true = Node.connect(node)
    :ok = :erpc.call(node, :global, :sync, [])

    on_exit(fn -> :peer.stop(peer) end)
    %{peer_node: node}
  end

  setup do
    on_exit(&TSpec.DataCase.stop_feed_sessions/0)
    viewer = onboarded_user_fixture()
    for _ <- 1..3, do: text_post_fixture(onboarded_user_fixture())
    %{scope: Accounts.scope_for_user(viewer)}
  end

  test "another node reaches the same session instead of starting its own",
       %{scope: scope, peer_node: peer} do
    sid = Ecto.UUID.generate()
    {:ok, pid} = Session.ensure(scope, sid)
    {:ok, %{items: first}} = Session.next_page(pid, 2)

    # From the other node: same owner, and calls run in it.
    assert {:ok, ^pid} = :erpc.call(peer, Session, :ensure, [scope, sid])
    assert :erpc.call(peer, Session, :whereis, [scope.user.id, sid]) == pid
    {:ok, %{items: second}} = :erpc.call(peer, Session, :next_page, [pid, 2])

    # One served sequence: the second page continues the first.
    served = Session.state(pid).served |> Enum.map(& &1.impression_id)
    assert served == Enum.map(first ++ second, &elem(&1, 1))
  end
end
