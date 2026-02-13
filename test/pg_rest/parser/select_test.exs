defmodule PgRest.Parser.SelectTest do
  use ExUnit.Case

  alias PgRest.Parser.Select

  describe "parse/1 - simple fields" do
    test "parses comma-separated fields" do
      assert {:ok, fields} = Select.parse("id,name,email")

      assert fields == [
               %{type: :field, name: "id"},
               %{type: :field, name: "name"},
               %{type: :field, name: "email"}
             ]
    end

    test "parses single field" do
      assert {:ok, [%{type: :field, name: "id"}]} = Select.parse("id")
    end

    test "trims whitespace from fields" do
      assert {:ok, fields} = Select.parse(" id , name ")

      assert [%{type: :field, name: "id"}, %{type: :field, name: "name"}] = fields
    end
  end

  describe "parse/1 - basic embeds" do
    test "parses embed with fields" do
      assert {:ok, fields} = Select.parse("id,posts(id,title)")

      assert [
               %{type: :field, name: "id"},
               %{type: :embed, name: "posts", fields: ["id", "title"], inner: false}
             ] = fields
    end

    test "parses embed with wildcard" do
      assert {:ok, fields} = Select.parse("id,posts(*)")

      assert [
               %{type: :field, name: "id"},
               %{type: :embed, name: "posts", fields: ["*"], inner: false}
             ] = fields
    end

    test "parses empty embed (for anti-joins)" do
      assert {:ok, fields} = Select.parse("*,nominations()")

      assert [
               %{type: :field, name: "*"},
               %{type: :embed, name: "nominations", fields: [], inner: false}
             ] = fields
    end

    test "parses multiple embeds" do
      assert {:ok, fields} = Select.parse("id,posts(id,title),comments(body)")

      assert [
               %{type: :field, name: "id"},
               %{type: :embed, name: "posts", fields: ["id", "title"], inner: false},
               %{type: :embed, name: "comments", fields: ["body"], inner: false}
             ] = fields
    end
  end

  describe "parse/1 - !inner modifier" do
    test "parses embed with !inner" do
      assert {:ok, fields} = Select.parse("id,posts!inner(id,title)")

      assert [
               %{type: :field, name: "id"},
               %{type: :embed, name: "posts", fields: ["id", "title"], inner: true}
             ] = fields
    end

    test "embed without !inner defaults to false" do
      assert {:ok, [_, embed]} = Select.parse("id,posts(id)")
      assert embed.inner == false
    end

    test "!inner with wildcard" do
      assert {:ok, [_, embed]} = Select.parse("id,posts!inner(*)")
      assert embed.inner == true
      assert embed.fields == ["*"]
    end

    test "!inner with empty parens" do
      assert {:ok, [_, embed]} = Select.parse("id,posts!inner()")
      assert embed.inner == true
      assert embed.fields == []
    end
  end

  describe "parse/1 - aliasing" do
    test "parses aliased embed" do
      assert {:ok, fields} = Select.parse("id,billing:addresses(name,city)")

      assert [
               %{type: :field, name: "id"},
               %{
                 type: :embed,
                 name: "addresses",
                 alias: "billing",
                 fields: ["name", "city"],
                 inner: false
               }
             ] = fields
    end

    test "parses aliased embed with !inner" do
      assert {:ok, [_, embed]} = Select.parse("id,recent:posts!inner(title)")
      assert embed.alias == "recent"
      assert embed.name == "posts"
      assert embed.inner == true
    end

    test "non-aliased embed has no alias key" do
      assert {:ok, [_, embed]} = Select.parse("id,posts(title)")
      refute Map.has_key?(embed, :alias)
    end
  end

  describe "parse/1 - nested embeds" do
    test "parses two-level nesting" do
      assert {:ok, fields} = Select.parse("id,posts(id,comments(body))")

      assert [
               %{type: :field, name: "id"},
               %{
                 type: :embed,
                 name: "posts",
                 inner: false,
                 fields: [
                   "id",
                   %{type: :embed, name: "comments", fields: ["body"], inner: false}
                 ]
               }
             ] = fields
    end

    test "parses three-level nesting" do
      assert {:ok, [_, embed]} = Select.parse("id,author(name,posts(title,comments(body)))")

      assert embed.name == "author"
      assert ["name", nested_posts] = embed.fields
      assert nested_posts.name == "posts"
      assert ["title", nested_comments] = nested_posts.fields
      assert nested_comments.name == "comments"
      assert nested_comments.fields == ["body"]
    end

    test "nested embed with wildcard" do
      assert {:ok, [_, embed]} = Select.parse("id,posts(title,comments(*))")

      assert [
               "title",
               %{type: :embed, name: "comments", fields: ["*"], inner: false}
             ] = embed.fields
    end

    test "multiple nested embeds at same level" do
      assert {:ok, [_, embed]} = Select.parse("id,posts(title,comments(body),tags(name))")

      assert [
               "title",
               %{type: :embed, name: "comments", fields: ["body"]},
               %{type: :embed, name: "tags", fields: ["name"]}
             ] = embed.fields
    end
  end

  describe "parse/1 - complex combinations" do
    test "fields, embeds, aliases, and inner together" do
      assert {:ok, fields} =
               Select.parse("id,title,recent:posts!inner(id,title),tags(name)")

      assert [
               %{type: :field, name: "id"},
               %{type: :field, name: "title"},
               %{
                 type: :embed,
                 name: "posts",
                 alias: "recent",
                 inner: true,
                 fields: ["id", "title"]
               },
               %{type: :embed, name: "tags", fields: ["name"], inner: false}
             ] = fields
    end

    test "embed-only select (no root fields)" do
      assert {:ok, fields} = Select.parse("posts(id,title)")

      assert [
               %{type: :embed, name: "posts", fields: ["id", "title"], inner: false}
             ] = fields
    end
  end
end
