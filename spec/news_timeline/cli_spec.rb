# frozen_string_literal: true

RSpec.describe NewsTimeline::CLI do
  def run_cli(argv)
    status = nil
    stderr = capture_stderr { status = described_class.start(argv) }
    [status, stderr]
  end

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  it "引数が足りないときは使い方を表示して1を返す" do
    status, stderr = run_cli(["https://example.com/news"])

    expect(status).to eq(1)
    expect(stderr).to include("引数は <URL> と \"<追いたい話題>\" の2つが必要です")
    expect(stderr).to include("Usage: news-timeline")
  end

  it "引数が多すぎるときも1を返す" do
    status, = run_cli(%w[a b c])

    expect(status).to eq(1)
  end

  it "GEMINI_API_KEY未設定なら取得先URL付きの案内を出して1を返す" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("GEMINI_API_KEY", nil).and_return(nil)

    status, stderr = run_cli(["https://example.com/news", "経緯を知りたい"])

    expect(status).to eq(1)
    expect(stderr).to include("GEMINI_API_KEY が設定されていません")
    expect(stderr).to include("https://aistudio.google.com/apikey")
  end

  it "不明なオプションはエラーメッセージを出して1を返す" do
    status, stderr = run_cli(["--unknown-option"])

    expect(status).to eq(1)
    expect(stderr).to include("invalid option")
  end
end
