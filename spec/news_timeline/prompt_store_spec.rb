# frozen_string_literal: true

require "tmpdir"

RSpec.describe NewsTimeline::PromptStore do
  subject(:store) { described_class.new }

  let(:bundled_templates) do
    %w[phase0 phase1 phase2 phase2_wrapper phase3 phase3_wrapper phase3_5 phase3_5_wrapper news_context]
  end

  it "同梱テンプレートをすべて読み込める" do
    bundled_templates.each do |name|
      expect(store.read(name)).not_to be_empty
    end
  end

  it "プレースホルダを置換する" do
    rendered = store.render("news_context", "今日の日付" => "2026年8月9日")

    expect(rendered).to include("今日の日付: 2026年8月9日")
    expect(rendered).not_to include("{今日の日付}")
  end

  it "渡されなかったプレースホルダ以外のブレース（JSON例など）はそのまま残す" do
    rendered = store.render("phase0", "元記事の内容" => "記事", "ユーザーの意図" => "経緯を知りたい")

    expect(rendered).to include("【元記事】\n記事")
    expect(rendered).to include('"content_appropriate"')
  end

  it "存在しないテンプレートはGenerationErrorを投げる" do
    expect { store.read("no_such_template") }
      .to raise_error(NewsTimeline::GenerationError, /プロンプトテンプレートが見つかりません/)
  end

  it "prompt_dirを指定するとテンプレートを差し替えられる" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "phase1.md"), "カスタム: {元記事のURL}")
      custom_store = described_class.new(dir)

      expect(custom_store.render("phase1", "元記事のURL" => "https://example.com"))
        .to eq("カスタム: https://example.com")
    end
  end
end
