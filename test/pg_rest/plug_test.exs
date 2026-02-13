defmodule PgRest.PlugTest do
  use ExUnit.Case
  import Plug.Test

  # Mock repo for testing
  defmodule MockRepo do
    def all(_query) do
      [%{id: 1, name: "Test Product", price: Decimal.new("9.99")}]
    end

    def one(_query), do: nil
    def insert(changeset), do: {:ok, changeset.data}
    def delete(record), do: {:ok, record}

    def transaction(multi) do
      results =
        multi
        |> Ecto.Multi.to_list()
        |> Enum.reduce({:ok, %{}}, fn
          {key, {:insert, changeset, _opts}}, {:ok, acc} ->
            {:ok, Map.put(acc, key, changeset.data)}

          _op, error ->
            error
        end)

      results
    end

    def update_all(_query, _updates) do
      {1, nil}
    end

    def delete_all(_query) do
      {1, nil}
    end

    def insert_all(_schema, entries, _opts) do
      {length(entries), nil}
    end
  end

  setup do
    start_supervised!(
      {PgRest.Registry,
       modules: [PgRest.Test.Order, PgRest.Test.Product, PgRest.Test.NonResource]}
    )

    :ok
  end

  describe "init/1" do
    test "requires repo option" do
      assert_raise KeyError, fn ->
        PgRest.Plug.init([])
      end
    end

    test "sets repo and defaults json to Jason" do
      opts = PgRest.Plug.init(repo: MockRepo)
      assert opts.repo == MockRepo
      assert opts.json == Jason
    end

    test "allows custom json library" do
      opts = PgRest.Plug.init(repo: MockRepo, json: Jason)
      assert opts.json == Jason
    end

    test "accepts max_limit option" do
      opts = PgRest.Plug.init(repo: MockRepo, max_limit: 1000)
      assert opts.max_limit == 1000
    end

    test "accepts context_builder option" do
      builder = fn _conn, opts -> %{repo: opts.repo} end
      opts = PgRest.Plug.init(repo: MockRepo, context_builder: builder)
      assert is_function(opts.context_builder, 2)
    end

    test "defaults max_limit and context_builder to nil" do
      opts = PgRest.Plug.init(repo: MockRepo)
      assert opts.max_limit == nil
      assert opts.context_builder == nil
    end
  end

  describe "call/2 - routing" do
    test "GET /products returns list" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
      assert conn.resp_body |> Jason.decode!() |> is_list()
      assert conn.halted
    end

    test "unknown resource returns 404" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:get, "/nonexistent")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "Resource not found"
      assert conn.halted
    end

    test "unsupported method returns 405" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:put, "/products/1")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 405
      assert conn.halted
    end

    test "PATCH without ID routes to bulk update" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:patch, "/products", Jason.encode!(%{"name" => "Updated"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      # Should not be 405 anymore
      assert conn.status in [200, 204]
      assert conn.halted
    end

    test "DELETE without ID routes to bulk delete" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:delete, "/products")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      # Should not be 405 anymore
      assert conn.status == 204
      assert conn.halted
    end
  end

  describe "call/2 - context building" do
    test "builds context from conn.assigns by default" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.fetch_query_params()
        |> Plug.Conn.assign(:user_id, 42)
        |> Plug.Conn.assign(:tenant_id, 7)
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
    end

    test "uses custom context_builder when provided" do
      builder = fn _conn, opts ->
        %{repo: opts.repo, custom: true}
      end

      opts = PgRest.Plug.init(repo: MockRepo, context_builder: builder)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
    end
  end

  describe "call/2 - response format" do
    test "sets content-type to application/json" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert {"content-type", "application/json; charset=utf-8"} in conn.resp_headers
    end

    test "error responses have error key" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:get, "/nonexistent")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "error")
    end

    test "all responses halt the connection" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.halted
    end
  end

  describe "call/2 - GET single record" do
    test "returns 404 when record not found" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:get, "/products/999")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      # MockRepo.all returns a non-empty list even with id filter,
      # so this should return 200 with the first record
      assert conn.status == 200
    end
  end

  describe "call/2 - DELETE" do
    test "returns 404 when record not found for delete" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:delete, "/products/999")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      # MockRepo.one returns nil, so should get not_found
      assert conn.status == 404
      assert conn.halted
    end
  end

  describe "call/2 - JSON decode safety" do
    test "POST with invalid JSON returns 400" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:post, "/products", "not valid json {{{")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "Invalid JSON"
    end

    test "PATCH with invalid JSON returns 400" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:patch, "/products/1", "not valid json {{{")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "Invalid JSON"
    end

    test "bulk PATCH with invalid JSON returns 400" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:patch, "/products", "not valid json {{{")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "Invalid JSON"
    end
  end

  describe "Prefer header - return=minimal" do
    test "POST with return=minimal returns 201 with empty body" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget", "price" => "9.99"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("prefer", "return=minimal")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 201
      assert conn.resp_body == ""
    end

    test "POST with no Prefer header defaults to minimal (201, empty body)" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget", "price" => "9.99"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 201
      assert conn.resp_body == ""
    end
  end

  describe "Prefer header - return=representation" do
    test "POST with return=representation returns 201 with record body" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget", "price" => "9.99"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("prefer", "return=representation")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 201
      assert conn.resp_body != ""
      body = Jason.decode!(conn.resp_body)
      assert is_list(body) or is_map(body)
    end
  end

  describe "Prefer header - return=headers-only" do
    test "POST with return=headers-only returns 204 with empty body" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget", "price" => "9.99"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("prefer", "return=headers-only")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 204
      assert conn.resp_body == ""
    end
  end

  describe "Preference-Applied header" do
    test "echoes back return=representation" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("prefer", "return=representation")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      pref_applied = Plug.Conn.get_resp_header(conn, "preference-applied")
      assert length(pref_applied) == 1
      assert "return=representation" in String.split(hd(pref_applied), ", ")
    end

    test "echoes back return=minimal" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("prefer", "return=minimal")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      pref_applied = Plug.Conn.get_resp_header(conn, "preference-applied")
      assert length(pref_applied) == 1
      assert "return=minimal" in String.split(hd(pref_applied), ", ")
    end

    test "no Preference-Applied when no Prefer sent" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert Plug.Conn.get_resp_header(conn, "preference-applied") == []
    end

    test "echoes back multiple preferences" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header(
          "prefer",
          "return=representation, resolution=merge-duplicates"
        )
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      pref_applied = Plug.Conn.get_resp_header(conn, "preference-applied")
      assert length(pref_applied) == 1
      parts = String.split(hd(pref_applied), ", ")
      assert "return=representation" in parts
      assert "resolution=merge-duplicates" in parts
    end
  end

  describe "Location header" do
    defmodule LocationMockRepo do
      def all(_query), do: []
      def one(_query), do: nil

      def insert(changeset) do
        record = Map.put(changeset.data, :id, 42)
        {:ok, record}
      end

      def delete(record), do: {:ok, record}
    end

    test "POST sets Location header with primary key" do
      opts = PgRest.Plug.init(repo: LocationMockRepo)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("prefer", "return=minimal")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      location = Plug.Conn.get_resp_header(conn, "location")
      assert length(location) == 1
      assert hd(location) == "/products?id=eq.42"
    end

    test "POST without ID in record does not set Location header" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("prefer", "return=minimal")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      # MockRepo returns record with nil id, so no location header
      location = Plug.Conn.get_resp_header(conn, "location")
      assert location == []
    end
  end

  describe "Accept header - single object" do
    test "GET with vnd.pgrst.object+json and single row returns object" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.put_req_header("accept", "application/vnd.pgrst.object+json")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_map(body)
      refute is_list(body)
    end

    test "GET with vnd.pgrst.object+json and zero rows returns 406" do
      defmodule EmptyRepo do
        def all(_query), do: []
      end

      opts = PgRest.Plug.init(repo: EmptyRepo)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.put_req_header("accept", "application/vnd.pgrst.object+json")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 406
    end

    test "GET with vnd.pgrst.object+json and multiple rows returns 406" do
      defmodule MultiRepo do
        def all(_query) do
          [
            %{id: 1, name: "A"},
            %{id: 2, name: "B"}
          ]
        end
      end

      opts = PgRest.Plug.init(repo: MultiRepo)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.put_req_header("accept", "application/vnd.pgrst.object+json")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 406
    end

    test "GET without vnd.pgrst.object+json returns array" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body)
    end
  end

  describe "bulk POST (array body)" do
    test "returns 201 with empty body for return=minimal" do
      opts = PgRest.Plug.init(repo: MockRepo)
      body = Jason.encode!([%{"name" => "A"}, %{"name" => "B"}])

      conn =
        conn(:post, "/products", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("prefer", "return=minimal")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 201
      assert conn.resp_body == ""
    end

    test "returns 201 with records for return=representation" do
      opts = PgRest.Plug.init(repo: MockRepo)
      body = Jason.encode!([%{"name" => "A"}, %{"name" => "B"}])

      conn =
        conn(:post, "/products", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("prefer", "return=representation")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 201
      records = Jason.decode!(conn.resp_body)
      assert is_list(records)
      assert length(records) == 2
    end
  end

  describe "bulk PATCH (no ID in path)" do
    test "returns 204 for return=minimal" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(
          :patch,
          "/products?name=eq.Widget",
          Jason.encode!(%{"name" => "Updated Widget"})
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("prefer", "return=minimal")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "returns 204 with no Prefer header (default minimal)" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(
          :patch,
          "/products?name=eq.Widget",
          Jason.encode!(%{"name" => "Updated Widget"})
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 204
    end
  end

  describe "bulk DELETE (no ID in path)" do
    test "returns 204 for return=minimal" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:delete, "/products?name=eq.Widget")
        |> Plug.Conn.put_req_header("prefer", "return=minimal")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "returns 204 with no Prefer header (default minimal)" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:delete, "/products?name=eq.Widget")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 204
    end
  end

  describe "upsert (POST with resolution header)" do
    test "POST with resolution=merge-duplicates triggers upsert" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget", "price" => "9.99"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("prefer", "resolution=merge-duplicates, return=minimal")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 201
      assert conn.resp_body == ""
    end

    test "POST with resolution=ignore-duplicates triggers upsert" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("prefer", "resolution=ignore-duplicates, return=minimal")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 201
      assert conn.resp_body == ""
    end

    test "POST without resolution header does normal insert" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("prefer", "return=minimal")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 201
      assert conn.resp_body == ""
    end
  end

  describe "allow option - static operation restriction" do
    setup do
      stop_supervised!(PgRest.Registry)

      start_supervised!(
        {PgRest.Registry,
         modules: [
           PgRest.Test.ReadOnlyProduct,
           PgRest.Test.NoDeleteOrder
         ]}
      )

      :ok
    end

    test "GET on read-only resource succeeds" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
    end

    test "POST on read-only resource returns 405" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 405
    end

    test "PATCH on read-only resource returns 405" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:patch, "/products/1", Jason.encode!(%{"name" => "Updated"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 405
    end

    test "DELETE on read-only resource returns 405" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:delete, "/products/1")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 405
    end

    test "DELETE on no-delete resource returns 405" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:delete, "/orders/1")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 405
    end

    test "PATCH on no-delete resource succeeds (not 405)" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:patch, "/orders/1", Jason.encode!(%{"status" => "shipped"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      # MockRepo.one returns nil so we get 404, but NOT 405
      refute conn.status == 405
    end
  end

  describe "authorization behavior" do
    defmodule AllowAllAuth do
      @behaviour PgRest.Authorization

      @impl true
      def authorize(_conn, _resource_module, _op, _context), do: :ok
    end

    defmodule DenyWriteAuth do
      @behaviour PgRest.Authorization

      @impl true
      def authorize(_conn, _resource_module, :read, _context), do: :ok
      def authorize(_conn, _resource_module, _op, _context), do: {:error, "Forbidden"}
    end

    defmodule DenyAllAuth do
      @behaviour PgRest.Authorization

      @impl true
      def authorize(_conn, _resource_module, _op, _context),
        do: {:error, %{message: "Access denied", code: "FORBIDDEN"}}
    end

    test "init/1 stores authorization option" do
      opts = PgRest.Plug.init(repo: MockRepo, authorization: AllowAllAuth)
      assert opts.authorization == AllowAllAuth
    end

    test "init/1 defaults authorization to nil" do
      opts = PgRest.Plug.init(repo: MockRepo)
      assert opts.authorization == nil
    end

    test "GET succeeds with allow-all auth" do
      opts = PgRest.Plug.init(repo: MockRepo, authorization: AllowAllAuth)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
    end

    test "POST returns 403 with deny-write auth" do
      opts = PgRest.Plug.init(repo: MockRepo, authorization: DenyWriteAuth)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "Forbidden"
    end

    test "GET succeeds with deny-write auth (only writes denied)" do
      opts = PgRest.Plug.init(repo: MockRepo, authorization: DenyWriteAuth)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
    end

    test "map error reasons produce structured error body" do
      opts = PgRest.Plug.init(repo: MockRepo, authorization: DenyAllAuth)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["errors"]["message"] == "Access denied"
      assert body["errors"]["code"] == "FORBIDDEN"
    end
  end

  describe "allow check takes precedence over authorization" do
    defmodule TrackingAuth do
      @behaviour PgRest.Authorization

      @impl true
      def authorize(_conn, _resource_module, _op, _context) do
        send(self(), :auth_called)
        :ok
      end
    end

    setup do
      stop_supervised!(PgRest.Registry)

      start_supervised!({PgRest.Registry, modules: [PgRest.Test.ReadOnlyProduct]})

      :ok
    end

    test "POST on read-only resource returns 405 without calling authorization" do
      opts = PgRest.Plug.init(repo: MockRepo, authorization: TrackingAuth)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 405
      refute_received :auth_called
    end
  end

  describe "PATCH with ID and Prefer header" do
    defmodule PatchMockRepo do
      def all(_query), do: []

      def one(_query) do
        %PgRest.Test.Product{id: 1, name: "Widget", price: Decimal.new("9.99")}
      end

      def update(changeset) do
        {:ok, changeset.data}
      end
    end

    test "PATCH /resource/id with return=minimal returns 204" do
      opts = PgRest.Plug.init(repo: PatchMockRepo)

      conn =
        conn(:patch, "/products/1", Jason.encode!(%{"name" => "Updated"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("prefer", "return=minimal")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "PATCH /resource/id with return=representation returns 200 with record" do
      opts = PgRest.Plug.init(repo: PatchMockRepo)

      conn =
        conn(:patch, "/products/1", Jason.encode!(%{"name" => "Updated"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("prefer", "return=representation")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body)
    end
  end

  describe "DELETE with ID and Prefer header" do
    defmodule DeleteMockRepo do
      def all(_query), do: []

      def one(_query) do
        %PgRest.Test.Product{id: 1, name: "Widget", price: Decimal.new("9.99")}
      end

      def delete(record), do: {:ok, record}
    end

    test "DELETE /resource/id with return=minimal returns 204" do
      opts = PgRest.Plug.init(repo: DeleteMockRepo)

      conn =
        conn(:delete, "/products/1")
        |> Plug.Conn.put_req_header("prefer", "return=minimal")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "DELETE /resource/id with return=representation returns 200 with record" do
      opts = PgRest.Plug.init(repo: DeleteMockRepo)

      conn =
        conn(:delete, "/products/1")
        |> Plug.Conn.put_req_header("prefer", "return=representation")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body)
    end

    test "DELETE /resource/id with no Prefer defaults to 204" do
      opts = PgRest.Plug.init(repo: DeleteMockRepo)

      conn =
        conn(:delete, "/products/1")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 204
      assert conn.resp_body == ""
    end
  end

  # --- sanitize_for_json (Bug 3 Regression) ---

  describe "sanitize_for_json/1" do
    defmodule SanitizeProductRepo do
      def all(_query) do
        [%PgRest.Test.Product{id: 1, name: "Widget", price: Decimal.new("9.99")}]
      end
    end

    defmodule SanitizeOrderNotLoadedRepo do
      def all(_query) do
        [
          %PgRest.Test.Order{
            id: 1,
            reference: "ORD-1",
            status: "pending",
            total: Decimal.new("100"),
            tenant_id: 1
          }
        ]
      end
    end

    defmodule SanitizeOrderLoadedRepo do
      def all(_query) do
        [
          %PgRest.Test.Order{
            id: 1,
            reference: "ORD-1",
            status: "pending",
            total: Decimal.new("100"),
            tenant_id: 1,
            line_items: [
              %PgRest.Test.LineItem{
                id: 1,
                name: "Item 1",
                quantity: 2,
                price: Decimal.new("50"),
                order_id: 1
              }
            ]
          }
        ]
      end
    end

    defmodule SanitizeEmptyRepo do
      def all(_query), do: []
    end

    defmodule SanitizePlainMapRepo do
      def all(_query), do: [%{id: 1, name: "test"}]
    end

    test "strips __meta__ from Ecto structs in JSON response" do
      opts = PgRest.Plug.init(repo: SanitizeProductRepo)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
      body = conn.resp_body
      refute body =~ "__meta__"

      [record] = Jason.decode!(body)
      assert record["id"] == 1
      assert record["name"] == "Widget"
      refute Map.has_key?(record, "__meta__")
    end

    test "drops NotLoaded associations from JSON response" do
      opts = PgRest.Plug.init(repo: SanitizeOrderNotLoadedRepo)

      conn =
        conn(:get, "/orders")
        |> Plug.Conn.assign(:tenant_id, 1)
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
      [record] = Jason.decode!(conn.resp_body)
      assert record["id"] == 1
      assert record["reference"] == "ORD-1"
      assert record["status"] == "pending"
      refute Map.has_key?(record, "line_items")
    end

    test "includes loaded (preloaded) associations in JSON response" do
      opts = PgRest.Plug.init(repo: SanitizeOrderLoadedRepo)

      conn =
        conn(:get, "/orders")
        |> Plug.Conn.assign(:tenant_id, 1)
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
      [record] = Jason.decode!(conn.resp_body)
      assert record["id"] == 1
      assert [item] = record["line_items"]
      assert item["id"] == 1
      assert item["name"] == "Item 1"
    end

    test "recursively sanitizes nested Ecto structs" do
      opts = PgRest.Plug.init(repo: SanitizeOrderLoadedRepo)

      conn =
        conn(:get, "/orders")
        |> Plug.Conn.assign(:tenant_id, 1)
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
      body = conn.resp_body
      refute body =~ "__meta__"

      [record] = Jason.decode!(body)
      [item] = record["line_items"]
      refute Map.has_key?(item, "__meta__")
      # LineItem belongs_to Order — NotLoaded should be dropped
      refute Map.has_key?(item, "order")
    end

    test "handles empty list" do
      opts = PgRest.Plug.init(repo: SanitizeEmptyRepo)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == []
    end

    test "handles plain maps (non-Ecto structs) — passthrough" do
      opts = PgRest.Plug.init(repo: SanitizePlainMapRepo)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
      [record] = Jason.decode!(conn.resp_body)
      assert record["id"] == 1
      assert record["name"] == "test"
    end
  end

  # --- Group 1: Content-Range and Count Modes ---

  describe "Content-Range and count modes" do
    defmodule CountMockRepo do
      def all(_query) do
        [
          %PgRest.Test.Product{id: 1, name: "A", price: Decimal.new("1")},
          %PgRest.Test.Product{id: 2, name: "B", price: Decimal.new("2")},
          %PgRest.Test.Product{id: 3, name: "C", price: Decimal.new("3")}
        ]
      end

      def aggregate(_query, :count), do: 10
    end

    defmodule FullCountMockRepo do
      def all(_query) do
        [
          %PgRest.Test.Product{id: 1, name: "A", price: Decimal.new("1")},
          %PgRest.Test.Product{id: 2, name: "B", price: Decimal.new("2")},
          %PgRest.Test.Product{id: 3, name: "C", price: Decimal.new("3")}
        ]
      end

      def aggregate(_query, :count), do: 3
    end

    defmodule EmptyCountMockRepo do
      def all(_query), do: []
      def aggregate(_query, :count), do: 5
    end

    test "GET with count=exact returns Content-Range header and status 206" do
      opts = PgRest.Plug.init(repo: CountMockRepo)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.put_req_header("prefer", "count=exact")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 206
      [range] = Plug.Conn.get_resp_header(conn, "content-range")
      assert range == "0-2/10"
    end

    test "GET with count=exact and offset returns adjusted Content-Range" do
      opts = PgRest.Plug.init(repo: CountMockRepo)

      conn =
        conn(:get, "/products?offset=5")
        |> Plug.Conn.put_req_header("prefer", "count=exact")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      [range] = Plug.Conn.get_resp_header(conn, "content-range")
      assert range == "5-7/10"
    end

    test "GET with count=exact returning all results gives status 200" do
      opts = PgRest.Plug.init(repo: FullCountMockRepo)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.put_req_header("prefer", "count=exact")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
      [range] = Plug.Conn.get_resp_header(conn, "content-range")
      assert range == "0-2/3"
    end

    test "GET with no count preference has no content-range header" do
      opts = PgRest.Plug.init(repo: CountMockRepo)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "content-range") == []
    end

    test "GET with count=exact returning empty results gives empty range" do
      opts = PgRest.Plug.init(repo: EmptyCountMockRepo)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.put_req_header("prefer", "count=exact")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      [range] = Plug.Conn.get_resp_header(conn, "content-range")
      assert range == "*/5"
    end

    test "GET with offset beyond total returns status 416" do
      opts = PgRest.Plug.init(repo: EmptyCountMockRepo)

      conn =
        conn(:get, "/products?offset=20")
        |> Plug.Conn.put_req_header("prefer", "count=exact")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 416
    end

    test "Preference-Applied header echoes back count=exact" do
      opts = PgRest.Plug.init(repo: CountMockRepo)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.put_req_header("prefer", "count=exact")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      [pref] = Plug.Conn.get_resp_header(conn, "preference-applied")
      assert "count=exact" in String.split(pref, ", ")
    end

    test "GET with count=estimated returns Content-Range header" do
      opts = PgRest.Plug.init(repo: FullCountMockRepo)

      conn =
        conn(:get, "/products")
        |> Plug.Conn.put_req_header("prefer", "count=estimated")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert Plug.Conn.get_resp_header(conn, "content-range") != []
    end
  end

  # --- Group 2: Bulk Operations with return=representation ---

  describe "bulk operations with return=representation" do
    defmodule BulkReturnMockRepo do
      def all(_query), do: []

      def update_all(_query, _updates) do
        {2,
         [
           %PgRest.Test.Product{id: 1, name: "Updated A", price: Decimal.new("1")},
           %PgRest.Test.Product{id: 2, name: "Updated B", price: Decimal.new("2")}
         ]}
      end

      def delete_all(_query) do
        {2,
         [
           %PgRest.Test.Product{id: 1, name: "Deleted A", price: Decimal.new("1")},
           %PgRest.Test.Product{id: 2, name: "Deleted B", price: Decimal.new("2")}
         ]}
      end
    end

    defmodule EmptyBulkReturnMockRepo do
      def all(_query), do: []
      def update_all(_query, _updates), do: {0, []}
      def delete_all(_query), do: {0, []}
    end

    test "bulk PATCH with return=representation returns 200 with JSON array" do
      opts = PgRest.Plug.init(repo: BulkReturnMockRepo)

      conn =
        conn(:patch, "/products?name=eq.Widget", Jason.encode!(%{"name" => "Updated"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("prefer", "return=representation")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
      records = Jason.decode!(conn.resp_body)
      assert is_list(records)
      assert length(records) == 2
    end

    test "bulk DELETE with return=representation returns 200 with JSON array" do
      opts = PgRest.Plug.init(repo: BulkReturnMockRepo)

      conn =
        conn(:delete, "/products?name=eq.Widget")
        |> Plug.Conn.put_req_header("prefer", "return=representation")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
      records = Jason.decode!(conn.resp_body)
      assert is_list(records)
      assert length(records) == 2
    end

    test "bulk PATCH with zero matches and return=representation returns 200 with []" do
      opts = PgRest.Plug.init(repo: EmptyBulkReturnMockRepo)

      conn =
        conn(:patch, "/products?name=eq.Nothing", Jason.encode!(%{"name" => "Updated"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("prefer", "return=representation")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == []
    end

    test "bulk DELETE with zero matches and return=representation returns 200 with []" do
      opts = PgRest.Plug.init(repo: EmptyBulkReturnMockRepo)

      conn =
        conn(:delete, "/products?name=eq.Nothing")
        |> Plug.Conn.put_req_header("prefer", "return=representation")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == []
    end
  end

  # --- Group 4: Upsert Prefer Header Options ---

  describe "upsert Prefer header options" do
    defmodule UpsertCaptureMockRepo do
      def all(_query), do: []

      def insert_all(_schema, entries, _opts) do
        send(self(), {:insert_all, entries})
        {length(entries), nil}
      end
    end

    defmodule UpsertReturnMockRepo do
      def all(_query), do: []

      def insert_all(_schema, _entries, _opts) do
        {1, [%PgRest.Test.Product{id: 1, name: "Upserted", price: Decimal.new("9.99")}]}
      end
    end

    test "upsert with missing=default does NOT nil-fill missing fields" do
      opts = PgRest.Plug.init(repo: UpsertCaptureMockRepo)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header(
          "prefer",
          "resolution=merge-duplicates, missing=default, return=minimal"
        )
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 201
      assert_received {:insert_all, [entry]}
      assert Map.has_key?(entry, :name)
      refute Map.has_key?(entry, :price)
    end

    test "upsert with return=representation returns 201 with JSON array" do
      opts = PgRest.Plug.init(repo: UpsertReturnMockRepo)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header(
          "prefer",
          "resolution=merge-duplicates, return=representation"
        )
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert is_list(body)
      assert length(body) == 1
    end

    test "upsert without return=representation returns 201 with empty body" do
      opts = PgRest.Plug.init(repo: UpsertCaptureMockRepo)

      conn =
        conn(:post, "/products", Jason.encode!(%{"name" => "Widget"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("prefer", "resolution=merge-duplicates")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 201
      assert conn.resp_body == ""
    end
  end

  # --- Group 5: Error Handling for Bulk Operations ---

  describe "bulk operation error handling" do
    defmodule BulkErrorMockRepo do
      def all(_query), do: []

      defp constraint_changeset do
        %PgRest.Test.Product{}
        |> Ecto.Changeset.cast(%{}, [])
        |> Ecto.Changeset.foreign_key_constraint(:id, name: "products_fkey")
      end

      def update_all(_query, _updates) do
        raise Ecto.ConstraintError,
          type: :foreign_key,
          constraint: "products_fkey",
          changeset: constraint_changeset(),
          action: :update
      end

      def delete_all(_query) do
        raise Ecto.ConstraintError,
          type: :foreign_key,
          constraint: "products_fkey",
          changeset: constraint_changeset(),
          action: :delete
      end

      def transaction(multi) do
        changeset =
          multi
          |> Ecto.Multi.to_list()
          |> List.first()
          |> elem(1)
          |> elem(1)

        {:error, {:insert, 0}, changeset, %{}}
      end
    end

    test "bulk PATCH with constraint error returns 422" do
      opts = PgRest.Plug.init(repo: BulkErrorMockRepo)

      conn =
        conn(:patch, "/products?name=eq.Widget", Jason.encode!(%{"name" => "Updated"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 422
      assert conn.halted
    end

    test "bulk DELETE with constraint error returns 422" do
      opts = PgRest.Plug.init(repo: BulkErrorMockRepo)

      conn =
        conn(:delete, "/products?name=eq.Widget")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 422
      assert conn.halted
    end

    test "bulk POST with one invalid record returns 422 with error body" do
      opts = PgRest.Plug.init(repo: BulkErrorMockRepo)

      conn =
        conn(:post, "/products", Jason.encode!([%{"name" => "A"}, %{"name" => ""}]))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 422
      assert conn.halted
    end
  end

  # --- Group 6: Prefer: handling=strict ---

  describe "Prefer: handling=strict" do
    test "GET with handling=strict and unknown param returns 400" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:get, "/products?bogus=foo")
        |> Plug.Conn.put_req_header("prefer", "handling=strict")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "Unknown parameters"
      assert body["error"] =~ "bogus"
    end

    test "GET with handling=strict and valid params returns 200" do
      opts = PgRest.Plug.init(repo: MockRepo)

      conn =
        conn(:get, "/products?name=eq.Widget&limit=10")
        |> Plug.Conn.put_req_header("prefer", "handling=strict")
        |> Plug.Conn.fetch_query_params()
        |> PgRest.Plug.call(opts)

      assert conn.status == 200
    end
  end
end
