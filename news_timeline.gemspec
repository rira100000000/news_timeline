# frozen_string_literal: true

require_relative "lib/news_timeline/version"

Gem::Specification.new do |spec|
  spec.name = "news_timeline"
  spec.version = NewsTimeline::VERSION
  spec.authors = ["rira100000000"]
  spec.email = ["101010hayakawa@gmail.com"]

  spec.summary = "ニュース記事URLから、Gemini の検索グラウンディングで経緯を調査してタイムラインを生成する"
  spec.description = "ニュース記事のURLと「何を追いたいか」を入力すると、Gemini APIのGoogle検索" \
                     "グラウンディングを使った多段フェーズ処理でニュースの経緯を調査し、" \
                     "出典URL付きのタイムライン（JSONとMarkdownレポート）を生成します。"
  spec.homepage = "https://github.com/rira100000000/news_timeline"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ examples/ Gemfile .gitignore .rspec spec/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "ruby-gemini-api", "~> 1.3"
end
