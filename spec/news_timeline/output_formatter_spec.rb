# frozen_string_literal: true

# 元実装（ano-news の format_for_form）の挙動を固定する特性テスト
RSpec.describe NewsTimeline::OutputFormatter do
  def phase3_5_result(blocks:)
    {
      "title" => "テストタイムライン",
      "description" => "テスト用の概要",
      "blocks" => blocks
    }
  end

  def block(overrides = {})
    {
      "event_year" => 2024,
      "event_month" => 6,
      "event_day" => 15,
      "title" => "出来事",
      "content" => "本文",
      "evidence_source_urls" => ["https://example.com/news/1"]
    }.merge(overrides)
  end

  it "titleとdescriptionをsymbolキーに移し替える" do
    result = described_class.format(phase3_5_result(blocks: [block]))

    expect(result[:title]).to eq("テストタイムライン")
    expect(result[:description]).to eq("テスト用の概要")
  end

  it "ブロックの属性をsymbolキーで返し、配列順にpositionを振る" do
    result = described_class.format(phase3_5_result(blocks: [block, block("title" => "2つ目")]))

    expect(result[:blocks][0]).to include(
      event_year: 2024, event_month: 6, event_day: 15,
      title: "出来事", content: "本文",
      evidence_source_urls: ["https://example.com/news/1"],
      position: 0
    )
    expect(result[:blocks][1]).to include(title: "2つ目", position: 1)
  end

  it "「タイトル - URL」形式からURLだけを抽出する" do
    blocks = [block("evidence_source_urls" => ["経緯まとめ記事 - https://example.com/matome"])]

    result = described_class.format(phase3_5_result(blocks: blocks))

    expect(result[:blocks][0][:evidence_source_urls]).to eq(["https://example.com/matome"])
  end

  it "http/httpsで始まらない値を取り除く" do
    blocks = [block("evidence_source_urls" => ["- 1", "出典: 政府広報", "https://example.com/ok"])]

    result = described_class.format(phase3_5_result(blocks: blocks))

    expect(result[:blocks][0][:evidence_source_urls]).to eq(["https://example.com/ok"])
  end

  it "vertexaisearchのリダイレクトURLを取り除く" do
    blocks = [block("evidence_source_urls" => [
                      "https://vertexaisearch.cloud.google.com/grounding-api-redirect/AbC123",
                      "https://example.com/real"
                    ])]

    result = described_class.format(phase3_5_result(blocks: blocks))

    expect(result[:blocks][0][:evidence_source_urls]).to eq(["https://example.com/real"])
  end

  it "evidence_source_urlsがnilでも空配列として扱う" do
    blocks = [block("evidence_source_urls" => nil)]

    result = described_class.format(phase3_5_result(blocks: blocks))

    expect(result[:blocks][0][:evidence_source_urls]).to eq([])
  end

  it "event_dayがnilのブロックをそのまま保持する" do
    blocks = [block("event_day" => nil)]

    result = described_class.format(phase3_5_result(blocks: blocks))

    expect(result[:blocks][0][:event_day]).to be_nil
  end
end
