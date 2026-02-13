defmodule PgRest.Parser.EmbedOptionTest do
  use ExUnit.Case

  alias PgRest.Parser

  describe "parse/2 - embed ordering" do
    test "parses posts.order=created_at.desc" do
      params = %{
        "select" => "id,posts(id,title)",
        "posts.order" => "created_at.desc"
      }

      assert {:ok, result} = Parser.parse(params)
      assert %{"posts" => opts} = result.embed_options
      assert [%{field: "created_at", direction: :desc, nulls: nil}] = opts[:order]
    end

    test "parses multi-field embed order" do
      params = %{
        "select" => "id,posts(id)",
        "posts.order" => "created_at.desc,title.asc"
      }

      assert {:ok, result} = Parser.parse(params)
      assert [first, second] = result.embed_options["posts"][:order]
      assert first.field == "created_at"
      assert first.direction == :desc
      assert second.field == "title"
      assert second.direction == :asc
    end

    test "parses order with nulls handling" do
      params = %{
        "select" => "id,posts(id)",
        "posts.order" => "created_at.desc.nullslast"
      }

      assert {:ok, result} = Parser.parse(params)
      [directive] = result.embed_options["posts"][:order]
      assert directive.nulls == :last
    end
  end

  describe "parse/2 - embed limit" do
    test "parses posts.limit=5" do
      params = %{
        "select" => "id,posts(id)",
        "posts.limit" => "5"
      }

      assert {:ok, result} = Parser.parse(params)
      assert result.embed_options["posts"][:limit] == 5
    end

    test "returns error for non-numeric limit" do
      params = %{
        "select" => "id,posts(id)",
        "posts.limit" => "abc"
      }

      assert {:error, :invalid_embed_option} = Parser.parse(params)
    end

    test "returns error for negative limit" do
      params = %{
        "select" => "id,posts(id)",
        "posts.limit" => "-1"
      }

      assert {:error, :invalid_embed_limit} = Parser.parse(params)
    end
  end

  describe "parse/2 - embed offset" do
    test "parses posts.offset=10" do
      params = %{
        "select" => "id,posts(id)",
        "posts.offset" => "10"
      }

      assert {:ok, result} = Parser.parse(params)
      assert result.embed_options["posts"][:offset] == 10
    end

    test "returns error for negative offset" do
      params = %{
        "select" => "id,posts(id)",
        "posts.offset" => "-5"
      }

      assert {:error, :invalid_embed_offset} = Parser.parse(params)
    end
  end

  describe "parse/2 - combined embed options" do
    test "order + limit + offset on same embed" do
      params = %{
        "select" => "id,posts(id,title)",
        "posts.order" => "created_at.desc",
        "posts.limit" => "5",
        "posts.offset" => "0"
      }

      assert {:ok, result} = Parser.parse(params)
      posts_opts = result.embed_options["posts"]
      assert [%{field: "created_at", direction: :desc}] = posts_opts[:order]
      assert posts_opts[:limit] == 5
      assert posts_opts[:offset] == 0
    end

    test "options on different embeds independently" do
      params = %{
        "select" => "id,posts(id),comments(body)",
        "posts.order" => "created_at.desc",
        "posts.limit" => "5",
        "comments.limit" => "10"
      }

      assert {:ok, result} = Parser.parse(params)
      assert result.embed_options["posts"][:limit] == 5
      assert result.embed_options["posts"][:order] != nil
      assert result.embed_options["comments"][:limit] == 10
      refute Map.has_key?(result.embed_options["comments"] || %{}, :order)
    end
  end

  describe "parse/2 - embed option edge cases" do
    test "embed option becomes custom param when embed not in select" do
      params = %{
        "select" => "id,name",
        "posts.order" => "created_at.desc"
      }

      assert {:ok, result} = Parser.parse(params, allowed_fields: [:id, :name])
      assert result.embed_options == %{}
      assert result.custom_params["posts.order"] == "created_at.desc"
    end

    test "embed options excluded from custom_params" do
      params = %{
        "select" => "id,posts(id)",
        "posts.order" => "created_at.desc",
        "posts.limit" => "5",
        "search" => "foo"
      }

      assert {:ok, result} = Parser.parse(params, allowed_fields: [:id])
      assert result.custom_params == %{"search" => "foo"}
      refute Map.has_key?(result.custom_params, "posts.order")
      refute Map.has_key?(result.custom_params, "posts.limit")
    end

    test "embed.order not treated as embed dot-filter" do
      params = %{
        "select" => "id,posts(id)",
        "posts.order" => "created_at.desc"
      }

      assert {:ok, result} = Parser.parse(params)
      # Should be in embed_options, not embed_filters
      assert result.embed_options["posts"][:order] != nil
      refute Map.has_key?(result.embed_filters, "posts")
    end

    test "embed_options key present in result even when empty" do
      params = %{"select" => "id,posts(id)"}

      assert {:ok, result} = Parser.parse(params)
      assert result.embed_options == %{}
    end
  end
end
