# frozen_string_literal: true

RSpec.describe NewsTimeline::UrlResolver do
  describe ".follow_redirect" do
    it "リダイレクトを追跡して最終URLを返す" do
      stub_request(:get, "https://redirect.example.com/r/1")
        .to_return(status: 302, headers: { "Location" => "https://news.example.com/article" })
      stub_request(:get, "https://news.example.com/article").to_return(status: 200, body: "ok")

      expect(described_class.follow_redirect("https://redirect.example.com/r/1"))
        .to eq("https://news.example.com/article")
    end

    it "相対パスのLocationを絶対URLに変換して追跡する" do
      stub_request(:get, "https://news.example.com/old")
        .to_return(status: 301, headers: { "Location" => "/new" })
      stub_request(:get, "https://news.example.com/new").to_return(status: 200, body: "ok")

      expect(described_class.follow_redirect("https://news.example.com/old"))
        .to eq("https://news.example.com/new")
    end

    it "リダイレクトでないレスポンスなら入力のURLをそのまま返す" do
      stub_request(:get, "https://news.example.com/article").to_return(status: 200, body: "ok")

      expect(described_class.follow_redirect("https://news.example.com/article"))
        .to eq("https://news.example.com/article")
    end

    it "接続エラー時は入力のURLをそのまま返す" do
      stub_request(:get, "https://down.example.com/").to_timeout

      expect(described_class.follow_redirect("https://down.example.com/"))
        .to eq("https://down.example.com/")
    end

    it "リダイレクト回数の上限に達したら追跡を打ち切る" do
      stub_request(:get, %r{https://loop.example.com/})
        .to_return(status: 302, headers: { "Location" => "https://loop.example.com/again" })

      expect(described_class.follow_redirect("https://loop.example.com/start"))
        .to eq("https://loop.example.com/again")
    end
  end
end
