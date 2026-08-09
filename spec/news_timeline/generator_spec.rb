# frozen_string_literal: true

require "tmpdir"

# 実APIを呼ばずに、Phase 0〜3.5のパイプライン全体の配線を検証するテスト
RSpec.describe NewsTimeline::Generator do
  let(:article_url) { "https://news.example.com/article/123" }
  let(:client) { instance_double(Gemini::Client) }

  let(:phase0_response) do
    double(
      "phase0",
      text: {
        content_appropriate: "適切", content_appropriate_reason: "歴史的経緯の調査",
        timelineable: "可能", timelineable_reason: "時系列で追跡可能",
        relevance: "高い", relevance_reason: "同一主題",
        user_intent_summary: "制度改正の経緯を知りたい", suggestions: []
      }.to_json
    )
  end

  let(:phase1_response) { double("phase1", valid?: true, text: "## ニュースの主題\n制度改正の経緯") }

  let(:phase2_response) do
    double(
      "phase2",
      valid?: true,
      text: "# 詳細調査レポート\n### 2024-06-15: 法案成立\n\n## 実際の情報源URL一覧\n実際のURL: https://gov.example.com/law",
      grounded?: true,
      grounding_chunks: [
        { "web" => { "uri" => "https://vertexaisearch.cloud.google.com/grounding-api-redirect/xyz",
                     "title" => "gov.example.com" } }
      ]
    )
  end

  let(:timeline_json) do
    {
      "title" => "制度改正のタイムライン",
      "description" => "制度改正の経緯をまとめたタイムライン",
      "blocks" => [
        { "event_year" => 2024, "event_month" => 6, "event_day" => 15,
          "title" => "法案成立", "content" => "法案が成立した。",
          "evidence_source_urls" => ["https://gov.example.com/law"] }
      ]
    }
  end

  let(:phase3_response) { double("phase3", valid?: true, text: timeline_json.to_json, json?: true, json: timeline_json) }
  let(:phase3_5_response) { double("phase3_5", valid?: true, text: timeline_json.to_json, json?: true, json: timeline_json) }

  before do
    allow(Gemini::Client).to receive(:new).and_return(client)

    # 元記事の取得
    stub_request(:get, article_url)
      .to_return(status: 200, body: "<html><body><h1>制度改正</h1><p>法案が成立した。</p></body></html>")

    # Phase 2.5: グラウンディングURLのリダイレクト解決
    stub_request(:get, "https://vertexaisearch.cloud.google.com/grounding-api-redirect/xyz")
      .to_return(status: 302, headers: { "Location" => "https://gov.example.com/law" })
    stub_request(:get, "https://gov.example.com/law").to_return(status: 200, body: "ok")

    allow(client).to receive(:generate_content).and_return(
      phase0_response, phase1_response, phase2_response, phase3_response, phase3_5_response
    )
  end

  it "全フェーズを通してタイムラインのHashを返す" do
    generator = described_class.new(api_key: "test-key", logger: Logger.new(IO::NULL))
    result = generator.generate(url: article_url, user_intent: "制度改正の経緯を知りたい")

    expect(result[:title]).to eq("制度改正のタイムライン")
    expect(result[:blocks].size).to eq(1)
    expect(result[:blocks][0]).to include(
      event_year: 2024, event_month: 6, event_day: 15,
      title: "法案成立",
      evidence_source_urls: ["https://gov.example.com/law"],
      position: 0
    )
    expect(client).to have_received(:generate_content).exactly(5).times
  end

  it "Phase 0で不適切と判定されたらValidationErrorを投げる" do
    rejection = double(
      "phase0_ng",
      text: {
        content_appropriate: "不適切", content_appropriate_reason: "商品宣伝が目的",
        timelineable: "可能", timelineable_reason: "-",
        relevance: "高い", relevance_reason: "-",
        user_intent_summary: "商品の宣伝", suggestions: ["業界全体の発展の経緯"]
      }.to_json
    )
    allow(client).to receive(:generate_content).and_return(rejection)

    generator = described_class.new(api_key: "test-key", logger: Logger.new(IO::NULL))

    expect { generator.generate(url: article_url, user_intent: "商品の宣伝") }
      .to raise_error(NewsTimeline::ValidationError) { |e|
        expect(e.error_type).to eq(:inappropriate_content)
        expect(e.suggestions).to eq(["業界全体の発展の経緯"])
      }
  end

  it "transcript_pathを指定したときだけログファイルを書き出す" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "transcript.md")
      generator = described_class.new(api_key: "test-key", logger: Logger.new(IO::NULL), transcript_path: path)
      generator.generate(url: article_url, user_intent: "制度改正の経緯を知りたい")

      expect(File.exist?(path)).to be(true)
      expect(File.read(path)).to include("# News Timeline Generation Log")
    end
  end

  it "APIキーが空ならErrorを投げる" do
    expect { described_class.new(api_key: "") }.to raise_error(NewsTimeline::Error, /APIキー/)
  end
end
